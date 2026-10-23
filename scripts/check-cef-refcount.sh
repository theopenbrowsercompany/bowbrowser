#!/bin/sh
# Fails when engine code declares a method named Release, AddRef or HasOneRef.
#
#   scripts/check-cef-refcount.sh [folder ...]    (default: App/Engine and E2E/Engine)
#
# CEF's reference counting (CefRefPtr, CefBase) calls Release, AddRef and HasOneRef on every copy of a CefRefPtr,
# so a bridge class with its own method of that name (say, a "release the page" method) is called by CEF as part
# of the count and frees or keeps objects at the wrong time. Name such a method Dispose, Close or Discard. Calls
# (`ref->Release()`) are fine; only a declaration or definition is refused. IMPLEMENT_REFCOUNTING declares them
# for a class, and is the only place they belong. Comments are ignored.
set -eu

cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then set -- App/Engine E2E/Engine; fi

exec perl -w - "$@" <<'PERL'
use strict;

my @violations;
my $files = 0;
for my $dir (@ARGV) {
  next unless -d $dir;
  for my $path (split /\n/, `find '$dir' -type f \\( -name '*.h' -o -name '*.hpp' -o -name '*.m' -o -name '*.mm' -o -name '*.cc' -o -name '*.cpp' \\) | sort`) {
    open my $fh, '<', $path or die "check-cef-refcount: cannot read $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    $files++;
    # Blank comments (and keep strings), keeping line numbers.
    my $blank = sub { (my $c = $_[0]) =~ s/[^\n]//g; $c };
    $text =~ s{("(?:\\.|[^"\\\n])*")|(//[^\n]*|/\*.*?\*/)}{ defined $1 ? $1 : $blank->($2) }gse;
    my $n = 0;
    for my $line (split /\n/, $text, -1) {
      $n++;
      # A declaration or definition: a return type (or virtual, static, inline) before the name, not a call, which
      # follows `.`, `->`, `::` of an object, `(`, `=`, return or else.
      next unless $line =~ /(?:^|[{};:])\s*(?:(?:virtual|static|inline|constexpr)\s+)*(?!return\b|else\b|delete\b|throw\b|co_return\b)[\w:<>]+(?:\s*[*&]+\s*|\s+)(?:\w+::)?(Release|AddRef|HasOneRef)\s*\(/;
      my $name = $1;
      (my $shown = $line) =~ s/^\s+//;
      push @violations, "$path:$n: declares $name: $shown";
    }
  }
}

if (@violations) {
  print STDERR "Engine code declares a method CEF's reference counting calls (it calls Release, AddRef and HasOneRef on every CefRefPtr copy); rename it, for example Dispose or Close:\n";
  print STDERR "$_\n" for @violations;
  exit 1;
}
printf "cef refcount: ok (%d files)\n", $files;
PERL
