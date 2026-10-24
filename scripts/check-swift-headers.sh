#!/bin/sh
# Fails when a header Swift can see exposes the engine's insides.
#
# Swift sees the bridging header App/Engine/Bow-Bridging-Header.h and every header it imports, transitively,
# including the ones behind `#if BOW_E2E` (Debug builds see them). Those headers must be plain Objective-C:
# no CEF or C++ header, no C++ code or C++ only section, no CEF type, and no raw browser pointer. A browser
# crosses into Swift as an ID or as a Bow Objective-C object, never as a pointer. Comments are ignored, so
# docs may name the CEF handlers a header wraps.
set -eu

cd "$(dirname "$0")/.."

bridging_header=App/Engine/Bow-Bridging-Header.h
# Without the bridging header Swift sees no C family header at all (the WebKit app has none), so there is nothing
# to check; the ok line names the missing file so a wrong path never passes in silence.
if [ ! -f "$bridging_header" ]; then
  echo "swift headers: ok (no bridging header $bridging_header, nothing to check)"
  exit 0
fi

exec perl -w - "$bridging_header" <<'PERL'
use strict;

my $root = shift @ARGV;

# Every header in the app and the harness, by file name, as Xcode's header map finds them. A name two headers
# share is an error only when a visible header includes it by that name alone.
my %headers;
for my $path (split /\n/, `find App E2E -name '*.h' -type f`) {
  (my $name = $path) =~ s{.*/}{};
  push @{$headers{$name}}, $path;
}

# Reads a header with its comments blanked out, keeping line numbers. One left to right pass, so a comment
# marker inside a string or inside the other kind of comment is not mistaken for a comment. The usual
# `#ifdef __cplusplus` / `extern "C" {` linkage guard is plain C to Swift, so it is blanked too.
sub code_lines {
  my ($path) = @_;
  open my $fh, '<', $path or die "check-swift-headers: cannot read $path: $!\n";
  local $/;
  my $text = <$fh>;
  close $fh;
  my $blank = sub { (my $c = $_[0]) =~ s/[^\n]//g; $c };
  $text =~ s{("(?:\\.|[^"\\\n])*")|(//[^\n]*|/\*.*?\*/)}{ defined $1 ? $1 : $blank->($2) }gse;
  $text =~ s{^[ \t]*#[ \t]*if(?:def[ \t]+__cplusplus|[ \t]+defined\(__cplusplus\))[ \t]*\n[ \t]*(?:extern[ \t]*"C"[ \t]*\{|\})[ \t]*\n[ \t]*#[ \t]*endif[^\n]*}{ $blank->($&) }gme;
  return split /\n/, $text, -1;
}

# The headers an include can name: the one next to the including header, else every header in App/ or E2E/
# with that file name.
sub resolve {
  my ($from, $target) = @_;
  (my $dir = $from) =~ s{/[^/]*$}{};
  my $beside = "$dir/$target";
  1 while $beside =~ s{(^|/)[^/.][^/]*/\.\./}{$1};
  return ($beside) if -f $beside;
  (my $name = $target) =~ s{.*/}{};
  return @{$headers{$name} || []};
}

my @violations;
my (@visible, %seen);
my @queue = ($root);
while (my $path = shift @queue) {
  next if $seen{$path}++;
  push @visible, $path;
  my $n = 0;
  for my $line (code_lines($path)) {
    $n++;
    next unless $line =~ /^\s*#\s*(?:import|include)\s*([<"])([^>"]+)[>"]/;
    my ($quote, $target) = ($1, $2);
    if ($target =~ m{(?:^|/)cef_}i || $target =~ m{^include/}) {
      push @violations, "$path:$n: includes a CEF header: $line";
      next;
    }
    if ($target !~ /\.h$/) {
      push @violations, "$path:$n: includes a C++ header: $line";
      next;
    }
    my @found = resolve($path, $target);
    # A framework or system header in angle brackets that is not one of ours is not followed.
    next if !@found && $quote eq '<';
    if (!@found) {
      push @violations, "$path:$n: includes a header outside App/ and E2E/: $line";
    } elsif (@found > 1) {
      push @violations, "$path:$n: includes a file name several headers share (@found): $line";
    } else {
      push @queue, $found[0];
    }
  }
}

# Objective-C classes declared in the visible headers; a pointer to one is an object, not a raw pointer.
my %objc_classes;
for my $path (@visible) {
  for my $line (code_lines($path)) {
    $objc_classes{$1} = 1 while $line =~ /@(?:interface|class)\s+(\w+)/g;
  }
}

my @rules = (
  [qr/__cplusplus/, 'has a C++ only section'],
  [qr/extern\s*"C/, 'uses C++ linkage'],
  [qr/::/, 'uses a C++ scope'],
  [qr/(?<![@\w])(?:namespace|template|typename|class|nullptr|constexpr|operator)\b/, 'uses C++ syntax'],
  [qr/\b(?:Cef[A-Z]\w*|cef_\w+|CEF_\w+)/, 'uses a CEF type'],
  [qr/\bvoid\s*\*/, 'exposes a raw pointer'],
  [qr/\bu?intptr_t\b/, 'exposes a pointer as an integer'],
);

for my $path (@visible) {
  my $n = 0;
  for my $line (code_lines($path)) {
    $n++;
    next if $line =~ /^\s*#\s*(?:import|include)\b/;  # Checked above.
    # A property's attribute list may say `class`, which is Objective-C, not C++.
    (my $code = $line) =~ s/\@property\s*\([^)]*\)/\@property/g;
    for my $rule (@rules) {
      push @violations, "$path:$n: $rule->[1]: $line" if $code =~ $rule->[0];
    }
    while ($code =~ /\b(\w*[Bb]rowser\w*)\s*\*/g) {
      push @violations, "$path:$n: exposes a raw browser pointer: $line" unless $objc_classes{$1};
    }
    push @violations, "$path:$n: exposes a raw browser handle: $line"
      if $code =~ /\b\w*[Bb]rowser\w*(?:Ref|Ptr|Handle|_t)\b/;
  }
}

if (@violations) {
  print STDERR "Swift visible headers expose CEF or C++ (keep them in Objective-C++ files and +Internal headers):\n";
  print STDERR "$_\n" for @violations;
  exit 1;
}
printf "swift headers: ok (%d headers)\n", scalar @visible;
PERL
