#!/bin/sh
# Fails when code outside BowWebKit/ imports WebKit, or when BowWebKit names a private WebKit API outside
# WebKitSPI.swift.
#
#   scripts/check-webkit-imports.sh [root]    (default: the repository)
#
# BowWebKit/ is the only code that may import WebKit: the app, the e2e harness and BowCore reach the engine through
# BowCore's engine protocols, so swapping or upgrading the engine touches one package. Refused outside BowWebKit/:
# a Swift `import WebKit` in any form (`@preconcurrency import WebKit`, `public import WebKit`,
# `import class WebKit.WKWebView`, `import WebKit.Sub`), and in Objective-C and C files `@import WebKit;`,
# `#import <WebKit/...>` and `#include <WebKit/...>`. Comments are ignored, and so are Swift strings.
# Inside BowWebKit/, every private name lives in Sources/BowWebKit/WebKitSPI.swift, which checks each one before use;
# any other BowWebKit file that builds a selector from a string (`Selector((`, `NSSelectorFromString`), declares a
# private Objective-C method (`@objc(_`), looks up a class or symbol by name (`NSClassFromString`, `dlsym`) or reads
# a private key (`forKey: "_`) is refused. Comments are ignored.
# The files are those git lists in the root (tracked and untracked, not ignored), or every file when the root is no
# git checkout (the self test's fixture trees), leaving out .git, build, .build and Vendor.
set -eu

root=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$root"

if git rev-parse --is-inside-work-tree > /dev/null 2>&1 && [ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ]; then
  files=$(git ls-files -co --exclude-standard)
else
  files=$(find . \( -name .git -o -name build -o -name .build -o -name Vendor \) -prune -o -type f -print | sed 's|^\./||')
fi

printf '%s\n' "$files" | exec perl -w -e '
use strict;

my $spi = "BowWebKit/Sources/BowWebKit/WebKitSPI.swift";
my (@imports, @private);
my $files = 0;
while (my $path = <STDIN>) {
  chomp $path;
  next unless $path =~ /\.(swift|h|hpp|m|mm|c|cc|cpp)$/;
  my $swift = $1 eq "swift";
  next unless -f $path;
  open my $fh, "<", $path or die "check-webkit-imports: cannot read $path: $!\n";
  my $text = do { local $/; <$fh> };
  close $fh;
  $files++;
  # Blank comments (keeping strings), keeping line numbers.
  my $lines = sub { (my $c = $_[0]) =~ s/[^\n]//g; $c };
  (my $code = $text) =~ s{("""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\\n])*")|(//[^\n]*|/\*.*?\*/)}{ defined $1 ? $1 : $lines->($2) }gse;
  # The same with every string blanked too.
  (my $bare = $code) =~ s{("""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\\n])*")}{ "\"\"" . $lines->($1) }gse;
  my @code = split /\n/, $code, -1;
  my @bare = split /\n/, $bare, -1;
  if ($path =~ m{^BowWebKit/}) {
    next if $path eq $spi;
    for my $n (0 .. $#code) {
      my $line = $code[$n];
      if ($line =~ /(Selector\(\(|NSSelectorFromString|\@objc\(_|NSClassFromString|\bdlsym\b|forKey(?:Path)?:\s*"_)/) {
        (my $shown = $line) =~ s/^\s+//;
        push @private, "$path:" . ($n + 1) . ": $shown";
      }
    }
    next;
  }
  for my $n (0 .. $#bare) {
    my $hit = 0;
    if ($swift) {
      $hit = $bare[$n] =~ /^\s*(?:\@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?WebKit\b/;
    } else {
      $hit = $bare[$n] =~ /^\s*\@import\s+WebKit\b/ || $code[$n] =~ /^\s*#\s*(?:import|include)\s*[<"]WebKit\//;
    }
    next unless $hit;
    (my $shown = $code[$n]) =~ s/^\s+//;
    push @imports, "$path:" . ($n + 1) . ": $shown";
  }
}

my $failed = 0;
if (@imports) {
  print STDERR "Only BowWebKit/ may import WebKit; the app, the e2e harness and BowCore reach the engine through BowCore'"'"'s engine protocols:\n";
  print STDERR "$_\n" for @imports;
  $failed = 1;
}
if (@private) {
  print STDERR "Private WebKit names belong in $spi, which checks each one before use:\n";
  print STDERR "$_\n" for @private;
  $failed = 1;
}
exit 1 if $failed;
printf "webkit imports: ok (%d files)\n", $files;
'
