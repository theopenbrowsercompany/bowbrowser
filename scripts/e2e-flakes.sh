#!/bin/bash
# Counts e2e outcomes per test across the results.json files scripts/e2e.sh writes, so a flaky test shows as a rate
# rather than a single run.
#
#   scripts/e2e-flakes.sh [run root or run folder ...]
#
# Reads <root>/*/results.json under each argument (default build/e2e, or BOW_E2E_ROOT), and a run folder given
# directly. Each run counts once per test (from its first attempt's RESULT lines, plus the test its TIMEOUT summary
# names) and once per run-wide check (chromium.errors, e2e.isolation):
#   PASS     passed on the first attempt
#   FLAKY    failed or timed out, then passed on the retry
#   FAIL     failed, and failed again on the retry or had none (E2E_RETRY=0, inside E2E_REPEAT)
#   TIMEOUT  timed out, and had no passing retry
# Tests a stuck run never started (NOT RUN) and interrupted runs are not counted.
# Prints one line per test: runs, passes, FLAKY, FAIL, TIMEOUT and the newest run folder with a failure, most
# failures first, then the newest failure first (by when its results.json was written), then by name. Exits 1 when no results.json was found.
# It reads JSON with perl's core JSON::PP, as the wrapper's own test does.
set -u

repo=$(cd "$(dirname "$0")/.." && pwd -P)
[ $# -gt 0 ] || set -- "${BOW_E2E_ROOT:-$repo/build/e2e}"

files=()
for arg in "$@"; do
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
  echo "e2e-flakes: no results.json under $*" >&2
  exit 1
fi

perl -MJSON::PP -MTime::HiRes -e '
  my (%row, $runs);
  for my $file (@ARGV) {
    open(my $fh, "<", $file) or next;
    my $doc = eval { local $/; decode_json(<$fh>) };
    next unless ref $doc eq "HASH" && ref $doc->{attempts} eq "ARRAY" && @{$doc->{attempts}};
    $runs++;
    my ($first, $retry) = @{$doc->{attempts}};
    my $folder = $doc->{run} // $file;
    $folder =~ s{.*/}{};
    # name => status in an attempt, for its tests and its run-wide checks.
    my $outcomes = sub {
      my $a = shift or return {};
      my %s;
      for (@{$a->{tests} || []}) { $s{$_->{name}} = $_->{status} }
      for (@{$a->{checks} || []}) {
        $s{$_->{name}} = $_->{status} if $_->{name} eq "chromium.errors" || $_->{name} eq "e2e.isolation";
      }
      \%s;
    };
    my ($one, $two) = ($outcomes->($first), $outcomes->($retry));
    # The test a stuck main thread stopped in has no RESULT line: `E2E: TIMEOUT <test>: <step>` names it
    # (`E2E: TIMEOUT between tests (...)` names none).
    if (($first->{summary} // "") =~ /^E2E: TIMEOUT ([^ :]+):/ && !exists $one->{$1}) { $one->{$1} = "timeout" }
    # When the run was written, to tell the newest failure (run folders made in the same second sort by pid).
    my $time = (Time::HiRes::stat($file))[9] // 0;
    for my $name (keys %$one) {
      my $s = $one->{$name};
      next if $s eq "not run";
      my $r = $row{$name} ||= { runs => 0, pass => 0, flaky => 0, fail => 0, timeout => 0, last => "", time => 0 };
      $r->{runs}++;
      my $kind = $s eq "pass" ? "pass" : (($two->{$name} // "") eq "pass") ? "flaky" : $s eq "timeout" ? "timeout" : "fail";
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
' "${files[@]}"
