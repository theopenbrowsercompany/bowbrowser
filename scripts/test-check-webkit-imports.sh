#!/bin/bash
# Tests scripts/check-webkit-imports.sh on fixture trees: every form of a WebKit import fails under App/UI, E2E and
# BowCore (Swift and Objective-C), the same text in a comment, a string or under BowWebKit/ passes, other imports
# pass, a private name in BowWebKit outside WebKitSPI.swift fails and inside it passes, the failure names the file
# and line, and the real tree passes. Takes under a second and launches nothing.
set -u
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failed=1; fi
}
# scan <path in the tree> <file text>: the guard's exit status on a tree holding one file with this text.
scan() {
  rm -rf "$tmp/t"
  mkdir -p "$tmp/t/$(dirname "$1")"
  printf '%s\n' "$2" > "$tmp/t/$1"
  ./scripts/check-webkit-imports.sh "$tmp/t" > "$tmp/out" 2>&1
  echo $?
}

for dir in App/UI E2E/Harness BowCore/Sources/BowCore; do
  check "$dir: import WebKit fails" 1 "$(scan "$dir/A.swift" 'import WebKit')"
  check "$dir: @preconcurrency import WebKit fails" 1 "$(scan "$dir/A.swift" '@preconcurrency import WebKit')"
  check "$dir: import class WebKit.WKWebView fails" 1 "$(scan "$dir/A.swift" 'import class WebKit.WKWebView')"
  check "$dir: @import WebKit; fails" 1 "$(scan "$dir/A.m" '@import WebKit;')"
  check "$dir: #import <WebKit/WebKit.h> fails" 1 "$(scan "$dir/A.mm" '#import <WebKit/WebKit.h>')"
done
check "the message names the file, the line and why" "yes" \
  "$(scan App/UI/B.swift $'import AppKit\nimport WebKit' > /dev/null
    grep -q 'App/UI/B.swift:2: import WebKit' "$tmp/out" && grep -q 'Only BowWebKit/ may import WebKit' "$tmp/out" && echo yes)"
check "public import WebKit fails" 1 "$(scan App/UI/A.swift 'public import WebKit')"
check "an indented import after an attribute with arguments fails" 1 \
  "$(scan App/UI/A.swift '  @_spi(Private) @preconcurrency import WebKit')"
check "import WebKit.Sub fails" 1 "$(scan App/UI/A.swift 'import WebKit.WKFoundation')"
check "#include <WebKit/...> in a header fails" 1 "$(scan App/Engine/A.h '#include <WebKit/WKWebView.h>')"
check "an import in a file of a new top folder fails" 1 "$(scan Tools/A.swift 'import WebKit')"
check "a line comment passes" 0 "$(scan App/UI/A.swift '// import WebKit')"
check "a block comment passes" 0 "$(scan App/UI/A.swift $'/*\nimport WebKit\n@import WebKit;\n*/')"
check "an Objective-C comment passes" 0 "$(scan App/UI/A.mm '// #import <WebKit/WebKit.h>')"
check "a string passes" 0 "$(scan App/UI/A.swift 'let text = "import WebKit"')"
check "a multiline string passes" 0 "$(scan App/UI/A.swift $'let text = """\nimport WebKit\n"""')"
check "an Objective-C string passes" 0 "$(scan App/UI/A.m 'NSString *s = @"@import WebKit;";')"
check "import WebKit under BowWebKit/ passes" 0 "$(scan BowWebKit/Sources/BowWebKit/A.swift 'import WebKit')"
check "@preconcurrency import WebKit under BowWebKit/ tests passes" 0 \
  "$(scan BowWebKit/Tests/BowWebKitTests/A.swift '@preconcurrency import WebKit')"
check "another import passes" 0 "$(scan App/UI/A.swift $'import AppKit\nimport BowCore\nimport WebKitLegacyShim')"
check "canImport(WebKit) passes" 0 "$(scan App/UI/A.swift '#if canImport(WebKit)')"
check "a file of another kind passes" 0 "$(scan App/UI/notes.txt 'import WebKit')"

spi=BowWebKit/Sources/BowWebKit/WebKitSPI.swift
check "a private selector in WebKitSPI.swift passes" 0 "$(scan $spi 'static let a = Selector(("_hideFindUI"))')"
check "a private callback in WebKitSPI.swift passes" 0 "$(scan $spi '@objc(_webView:didCountMatches:forString:)')"
check "a private selector elsewhere in BowWebKit fails" 1 \
  "$(scan BowWebKit/Sources/BowWebKit/WebKitTab.swift 'let a = Selector(("_hideFindUI"))')"
check "the message names the file, the line and WebKitSPI.swift" "yes" \
  "$(grep -q 'WebKitTab.swift:1: let a' "$tmp/out" && grep -q 'belong in BowWebKit/Sources/BowWebKit/WebKitSPI.swift' "$tmp/out" && echo yes)"
check "a private callback elsewhere fails" 1 \
  "$(scan BowWebKit/Sources/BowWebKit/WebKitTab.swift '@objc(_webView:mouseDidMoveOverElement:withFlags:userInfo:)')"
check "NSSelectorFromString elsewhere fails" 1 \
  "$(scan BowWebKit/Tests/BowWebKitTests/A.swift 'let s = NSSelectorFromString("_tryClose")')"
check "NSClassFromString elsewhere fails" 1 "$(scan BowWebKit/Sources/BowWebKit/A.swift 'NSClassFromString("_WKInspector")')"
check "dlsym elsewhere fails" 1 "$(scan BowWebKit/Sources/BowWebKit/A.swift 'let f = dlsym(handle, "WKThing")')"
check "a private key elsewhere fails" 1 "$(scan BowWebKit/Sources/BowWebKit/A.swift 'x.value(forKey: "_private")')"
check "a public @objc name elsewhere passes" 0 "$(scan BowWebKit/Sources/BowWebKit/A.swift '@objc(webView:didFinish:)')"
check "a private name in a comment elsewhere passes" 0 \
  "$(scan BowWebKit/Sources/BowWebKit/A.swift '// WebKitSPI wraps Selector(("_hideFindUI"))')"
check "a private name in an App file is not this guard's business" 0 \
  "$(scan App/UI/A.swift 'let s = NSSelectorFromString("_x")')"

check "an empty tree passes" 0 "$(rm -rf "$tmp/t"; mkdir -p "$tmp/t"; ./scripts/check-webkit-imports.sh "$tmp/t" > /dev/null 2>&1; echo $?)"
check "the real tree passes" 0 "$(./scripts/check-webkit-imports.sh > /dev/null 2>&1; echo $?)"

if [ "$failed" = 0 ]; then echo "webkit imports self test: ok"; else
  echo "webkit imports self test: FAIL"
  exit 1
fi
