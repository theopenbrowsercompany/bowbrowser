#!/bin/bash
# Counts e2e outcomes per test, so a flaky test shows as a rate rather than a single run.
#
#   scripts/e2e-flakes.sh [--days N] [--ledger FILE]      the shared ledger (default)
#   scripts/e2e-flakes.sh --local [run root or run folder ...]   the results.json files of this checkout
#   scripts/e2e-flakes.sh <run root or run folder ...>    the same, naming them
#   scripts/e2e-flakes.sh --emit <results.json>           what scripts/e2e.sh appends to the ledger (below)
#
# The ledger is ~/Library/Caches/bowbrowser/e2e-ledger.tsv (BOW_E2E_LEDGER overrides it, so self tests never touch the
# real one). scripts/e2e.sh appends to it one line per test and run-wide check per run, from every worktree, so the
# history outlives a landed worktree. Tab separated, with a header line:
#   date (UTC, ISO 8601)  test  outcome  branch  tree  load  shard  run
# outcome is PASS (passed on the first attempt), FLAKY (failed or timed out, then passed on the retry),
# QUARANTINED-FLAKY (FLAKY, and on the quarantine list), FAIL (failed, and failed again on the retry or had none) or
# TIMEOUT (timed out, no passing retry). tree is the commit's tree hash, with -<8 hex digits of the diff> when tracked
# files were modified, so a fail fixed in the working tree is never a flake. shard is the shard number, or - for an
# unsharded run. run is the run folder's name.
#
# Ledger mode prints, over the last N days (default 7, --days), one line per test: runs, passes, FLAKY (both kinds),
# FAIL and TIMEOUT counts, EVENTS and FILING, and when it last failed. An event is a FLAKY outcome, or a FAIL or TIMEOUT
# on a tree that the same test later passed (an earlier line of the same test and tree that is not a PASS, with a PASS
# line at or after its date; tree "unknown", a build with no stamp, never matches). FILING says FILE when a test has 2 or more events in the window: the lead files a flake
# item for it (E2E/README.md, Flake history). Most events first, then most failures, then newest failure, then name.
# Exits 1 when the ledger has no line in the window.
#
# Local mode reads <root>/*/results.json under each argument (default build/e2e, or BOW_E2E_ROOT), and a run folder
# given directly. Each run counts once per test (from its first attempt's RESULT lines, plus the test its TIMEOUT
# summary names; a failed check named after a test, such as the quit check that fails after its RESULT line, fails the
# test, and so does a crash after a RESULT line with quit=pending) and once per run-wide check (chromium.errors,
# e2e.isolation):
#   PASS     passed on the first attempt
#   FLAKY    failed or timed out, then passed on the retry
#   FAIL     failed, and failed again on the retry or had none (E2E_RETRY=0, inside E2E_REPEAT)
#   TIMEOUT  timed out, and had no passing retry
# Tests a stuck run never started (NOT RUN), runs that could not start and interrupted runs are not counted.
# Prints one line per test: runs, passes, FLAKY, FAIL, TIMEOUT and the newest run folder with a failure, most
# failures first, then the newest failure first (by when its results.json was written), then by name. Exits 1 when no results.json was found.
# It reads JSON with perl's core JSON::PP, as the wrapper's own test does.
set -u

repo=$(cd "$(dirname "$0")/.." && pwd -P)
ledger=${BOW_E2E_LEDGER:-$HOME/Library/Caches/bowbrowser/e2e-ledger.tsv}
days=7
mode=ledger
paths=()
while [ $# -gt 0 ]; do
  case $1 in
    --days)
      shift
      [[ ${1:-} =~ ^0*[1-9][0-9]*$ ]] || { echo "e2e-flakes: --days wants a whole number of 1 or more" >&2; exit 64; }
      days=$((10#$1)); ledger_opts=1 ;;
    --ledger) shift; ledger=${1:?e2e-flakes: --ledger wants a file}; ledger_opts=1 ;;
    --local) mode=local ;;
    --emit) mode=emit ;;
    -*) echo "e2e-flakes: unknown option $1" >&2; exit 64 ;;
    *) paths+=("$1"); [ "$mode" = emit ] || mode=local ;;
  esac
  shift
done
if [ "$mode" != ledger ] && [ "${ledger_opts:-0}" = 1 ]; then
  echo "e2e-flakes: --days and --ledger read the ledger; they do not combine with --local, --emit or paths" >&2
  exit 64
fi

# The perl below holds three modes: local, emit and ledger. run_outcomes turns one results.json into name => kind
# (pass, flaky, timeout or fail), for the local count and for the ledger lines e2e.sh writes.
prog='
  my $mode = shift @ARGV;
  my ($days, $ledger) = ($ENV{FLAKES_DAYS}, $ENV{FLAKES_LEDGER});
  sub run_outcomes {
    my $doc = shift;
    # A run that could not start (status error) or was interrupted ran nothing to count.
    return unless ref $doc eq "HASH" && ref $doc->{attempts} eq "ARRAY" && @{$doc->{attempts}} && ($doc->{status} // "") ne "error";
    my ($first, $retry) = @{$doc->{attempts}};
    # name => status in an attempt, for its tests and its run-wide checks.
    my $outcomes = sub {
      my $a = shift or return {};
      my (%s, %pending);
      for (@{$a->{tests} || []}) {
        $s{$_->{name}} = $_->{status};
        $pending{$_->{name}} = 1 if ($_->{detail} // "") =~ /(^| )quit=pending( |$)/;
      }
      my @tests = keys %s;
      for (@{$a->{checks} || []}) {
        my $c = $_->{name};
        if ($c eq "chromium.errors" || $c eq "e2e.isolation") { $s{$c} = $_->{status}; next }
        next unless $_->{status} eq "fail";
        # A failed check belongs to the test it is named after (the test, or the longest test name it continues
        # with a dot); the quit check fails after its RESULT line, so the RESULT line alone can say pass.
        my ($owner) = sort { length $b <=> length $a } grep { $c eq $_ || index($c, "$_.") == 0 } @tests;
        $s{$owner} = "fail" if defined $owner && $s{$owner} eq "pass";
      }
      # A crash after `quit=pending` (Chromium teardown watchdog included) means the quit did not finish.
      if (($a->{status} // "") eq "crash") { $s{$_} eq "pass" and $s{$_} = "fail" for keys %pending }
      \%s;
    };
    my ($one, $two) = ($outcomes->($first), $outcomes->($retry));
    # The test a stuck main thread stopped in has no RESULT line: `E2E: TIMEOUT <test>: <step>` names it
    # (`E2E: TIMEOUT between tests (...)` names none).
    if (($first->{summary} // "") =~ /^E2E: TIMEOUT ([^ :]+):/ && !exists $one->{$1}) { $one->{$1} = "timeout" }
    my %kind;
    for my $name (keys %$one) {
      my $s = $one->{$name};
      next if $s eq "not run";
      $kind{$name} = $s eq "pass" ? "pass" : (($two->{$name} // "") eq "pass") ? "flaky" : $s eq "timeout" ? "timeout" : "fail";
    }
    return \%kind;
  }
  sub read_json {
    open(my $fh, "<", $_[0]) or return;
    eval { local $/; decode_json(<$fh>) };
  }

  if ($mode eq "emit") {
    my $doc = read_json($ARGV[0]);
    my $kind = run_outcomes($doc) or exit 0;
    my %quarantined = map { $_->{name} => 1 } @{ref $doc->{quarantined} eq "ARRAY" ? $doc->{quarantined} : []};
    for my $name (sort keys %$kind) {
      my $k = $kind->{$name};
      my $outcome = $k eq "flaky" && $quarantined{$name} ? "QUARANTINED-FLAKY" : uc $k;
      print "$name\t$outcome\n";
    }
    exit 0;
  }

  if ($mode eq "local") {
    my (%row, $runs);
    for my $file (@ARGV) {
      my $doc = read_json($file);
      my $kinds = run_outcomes($doc) or next;
      $runs++;
      my $folder = $doc->{run} // $file;
      $folder =~ s{.*/}{};
      # When the run was written, to tell the newest failure (run folders made in the same second sort by pid).
      my $time = (Time::HiRes::stat($file))[9] // 0;
      for my $name (keys %$kinds) {
        my $kind = $kinds->{$name};
        my $r = $row{$name} ||= { runs => 0, pass => 0, flaky => 0, fail => 0, timeout => 0, last => "", time => 0 };
        $r->{runs}++;
        $r->{$kind}++;
        ($r->{last}, $r->{time}) = ($folder, $time) if $kind ne "pass" && $time >= $r->{time};
      }
    }
    my $bad = sub { $row{$_[0]}{flaky} + $row{$_[0]}{fail} + $row{$_[0]}{timeout} };
    printf "%-40s %5s %6s %6s %5s %8s  %s\n", "TEST", "RUNS", "PASSES", "FLAKY", "FAIL", "TIMEOUT", "LAST FAILED";
    for my $name (sort { $bad->($b) <=> $bad->($a) || $row{$b}{time} <=> $row{$a}{time} || $a cmp $b } keys %row) {
      my $r = $row{$name};
      printf "%-40s %5d %6d %6d %5d %8d  %s\n", $name, @$r{qw(runs pass flaky fail timeout)}, $r->{last} || "-";
    }
    printf "e2e-flakes: %d runs\n", $runs // 0;
    exit 0;
  }

  # ledger: the lines of the window, per test.
  my @t = gmtime(time - $days * 86400);
  my $cutoff = sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ", $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0];
  open(my $fh, "<", $ledger) or exit 2;
  my (%lines, %runs, %branches, $total);
  while (my $l = <$fh>) {
    chomp $l;
    my ($date, $test, $outcome, $branch, $tree, $load, $shard, $run) = split /\t/, $l;
    next unless defined $run && $date =~ /^\d{4}-\d\d-\d\dT/ && $date ge $cutoff;
    next unless $outcome =~ /^(PASS|FLAKY|QUARANTINED-FLAKY|FAIL|TIMEOUT)\z/;
    push @{$lines{$test}}, { date => $date, outcome => $outcome, tree => $tree };
    $runs{"$date $branch $run"} = 1;
    $branches{$branch} = 1;
    $total++;
  }
  exit 3 unless $total;
  my %row;
  for my $test (keys %lines) {
    my $r = $row{$test} = { runs => 0, pass => 0, flaky => 0, fail => 0, timeout => 0, events => 0, last => "" };
    my @all = @{$lines{$test}};
    for my $e (@all) {
      $r->{runs}++;
      my $o = $e->{outcome};
      if ($o eq "PASS") { $r->{pass}++; next }
      if ($o eq "FAIL") { $r->{fail}++ } elsif ($o eq "TIMEOUT") { $r->{timeout}++ } else { $r->{flaky}++ }
      $r->{last} = $e->{date} if $e->{date} gt $r->{last};
      # A FLAKY outcome passed on the retry of its own tree; a FAIL or TIMEOUT is an event when the same tree passed later.
      my $event = $o !~ /^(FAIL|TIMEOUT)\z/ || grep { $_->{outcome} eq "PASS" && $e->{tree} ne "unknown" && $_->{tree} eq $e->{tree} && $_->{date} ge $e->{date} } @all;
      $r->{events}++ if $event;
    }
  }
  my $bad = sub { $row{$_[0]}{flaky} + $row{$_[0]}{fail} + $row{$_[0]}{timeout} };
  printf "%-40s %5s %6s %6s %5s %8s %6s %-7s  %s\n", "TEST", "RUNS", "PASSES", "FLAKY", "FAIL", "TIMEOUT", "EVENTS", "FILING", "LAST FAILED";
  my $file = 0;
  for my $name (sort { $row{$b}{events} <=> $row{$a}{events} || $bad->($b) <=> $bad->($a) || $row{$b}{last} cmp $row{$a}{last} || $a cmp $b } keys %row) {
    my $r = $row{$name};
    my $filing = $r->{events} >= 2 ? "FILE" : "-";
    $file++ if $filing eq "FILE";
    printf "%-40s %5d %6d %6d %5d %8d %6d %-7s  %s\n", $name, @$r{qw(runs pass flaky fail timeout events)}, $filing, $r->{last} || "-";
  }
  printf "e2e-flakes: %d runs on %d branches in the last %d days; %d to file\n", scalar keys %runs, scalar keys %branches, $days, $file;
'

case $mode in
  emit)
    [ "${#paths[@]}" = 1 ] || { echo "e2e-flakes: --emit wants one results.json" >&2; exit 64; }
    exec perl -MJSON::PP -e "$prog" emit "${paths[0]}" ;;
  ledger)
    if [ ! -f "$ledger" ]; then
      echo "e2e-flakes: no ledger at $ledger (scripts/e2e.sh writes it); --local reads this checkout's build/e2e" >&2
      exit 1
    fi
    FLAKES_DAYS=$days FLAKES_LEDGER=$ledger perl -MJSON::PP -e "$prog" ledger
    code=$?
    case $code in
      2) echo "e2e-flakes: cannot read $ledger" >&2; exit 1 ;;
      3) echo "e2e-flakes: no ledger line in the last $days days at $ledger" >&2; exit 1 ;;
    esac
    exit "$code" ;;
esac

[ ${#paths[@]} -gt 0 ] || paths=("${BOW_E2E_ROOT:-$repo/build/e2e}")
files=()
for arg in "${paths[@]}"; do
  if [ -f "$arg/results.json" ]; then
    files+=("$arg/results.json")
  elif [ -d "$arg" ]; then
    # find does not follow the latest symlink, so the newest run is not counted twice.
    while IFS= read -r f; do files+=("$f"); done < <(find "$arg" -mindepth 2 -maxdepth 2 -name results.json -type f | sort)
  else
    echo "e2e-flakes: no run root or run folder at $arg" >&2
  fi
done
if [ "${#files[@]}" = 0 ]; then
  echo "e2e-flakes: no results.json under ${paths[*]}" >&2
  exit 1
fi
exec perl -MJSON::PP -MTime::HiRes -e "$prog" local "${files[@]}"
