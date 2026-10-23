#!/bin/bash
# Tests scripts/check-cef-refcount.sh on fake engine folders: declarations of Release, AddRef and HasOneRef fail
# (in a header, an Objective-C++ file, with virtual, with a pointer return type, a definition), calls, comments and
# other names pass. Takes under a second and launches nothing.
set -u
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failed=1; fi
}
# scan <file text>: the guard's exit status on a folder holding one file with this text.
scan() {
  rm -rf "$tmp/f"
  mkdir -p "$tmp/f"
  printf '%s\n' "$1" > "$tmp/f/Fake.mm"
  ./scripts/check-cef-refcount.sh "$tmp/f" > "$tmp/out" 2>&1
  echo $?
}

check "a Release declaration fails" 1 "$(scan 'void Release() override;')"
check "the message names the file and why" "yes" \
  "$(grep -q 'Fake.mm:1: declares Release' "$tmp/out" && grep -q 'every CefRefPtr copy' "$tmp/out" && echo yes)"
check "an AddRef declaration fails" 1 "$(scan '  virtual void AddRef() const = 0;')"
check "a HasOneRef declaration fails" 1 "$(scan 'bool HasOneRef() const { return true; }')"
check "a Release returning a pointer fails" 1 "$(scan 'Page* Release(int id);')"
check "a definition of a method fails" 1 "$(scan 'void BowTabClient::Release() {')"
check "a declaration inside a one line class fails" 1 "$(scan 'class X { public: void Release() override; };')"
check "a call through a pointer passes" 0 "$(scan 'ref->Release();')"
check "a call on an object passes" 0 "$(scan 'ref.Release();')"
check "a bare call passes" 0 "$(scan '  Release();')"
check "a returned call passes" 0 "$(scan '  return Release();')"
check "an else call passes" 0 "$(scan '  else Release();')"
check "a comment passes" 0 "$(scan '// void Release() would clash with CEF')"
check "a block comment passes" 0 "$(scan '/* void AddRef(); */')"
check "IMPLEMENT_REFCOUNTING passes" 0 "$(scan '  IMPLEMENT_REFCOUNTING(BowTabClient);')"
check "another name passes" 0 "$(scan 'void ReleasePage(int id);')"
check "a folder that is not there passes" 0 "$(./scripts/check-cef-refcount.sh "$tmp/none" > /dev/null 2>&1; echo $?)"
check "the real tree passes" 0 "$(./scripts/check-cef-refcount.sh > /dev/null 2>&1; echo $?)"

if [ "$failed" = 0 ]; then echo "cef refcount self test: ok"; else
  echo "cef refcount self test: FAIL"
  exit 1
fi
