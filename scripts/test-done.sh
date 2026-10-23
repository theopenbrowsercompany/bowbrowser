#!/bin/bash
# Tests scripts/done.sh in a throwaway git repository with a fake make: the refusal on a branch behind origin/main
# (and with no origin/main), the report block of a passing run, a failing verify (which skips the e2e) and a failing
# e2e. Takes about a second and runs no build or app.
set -u
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failed=1; fi
}
has() { # has <description> <text> <needle>
  case $2 in *"$3"*) echo "ok   $1" ;; *)
    echo "FAIL $1: no '$3' in:"
    echo "$2"
    failed=1
    ;;
  esac
}

repo=$tmp/repo
mkdir -p "$repo/scripts" "$repo/Vendor/cef" "$tmp/bin"
cp scripts/done.sh "$repo/scripts/"
# A fake make: verify and e2e print the lines the real ones end with, e2e makes the run folder and final.png.
cat > "$tmp/bin/make" << 'EOF'
#!/bin/bash
case "$*" in
  *verify*)
    echo "verify: lint ok 1s"
    if [ "${FAKE_VERIFY:-0}" = 0 ]; then echo "verify: PASS 4 parts in 1s"; else
      echo "verify: FAIL lint (1s)"
      exit 2
    fi
    ;;
  *e2e*)
    echo "ran: $*" >> "$FAKE_LOG"
    mkdir -p build/e2e/20260101-1
    ln -sfn 20260101-1 build/e2e/latest
    echo png > build/e2e/20260101-1/final.png
    if [ "${FAKE_E2E:-0}" = 0 ]; then echo "E2E: PASS 3/3"; else
      echo "E2E: FAIL 2/3"
      echo "make: *** [e2e] Error 1"
      exit 2
    fi
    ;;
esac
EOF
chmod +x "$tmp/bin/make"
g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
git init -q "$repo"
printf "build/\n" > "$repo/.gitignore"
echo a > "$repo/a"
g add -A
g commit -qm one
g update-ref refs/remotes/origin/main HEAD
echo b > "$repo/b"
g add b
g commit -qm two

run() { # run <fake verify> <fake e2e>: the script's output and exit code
  : > "$tmp/log"
  (cd "$repo" && FAKE_VERIFY=$1 FAKE_E2E=$2 FAKE_LOG=$tmp/log PATH="$tmp/bin:$PATH" ./scripts/done.sh 2>&1)
  echo "exit=$?"
}

out=$(run 0 0)
has "a branch holding origin/main passes" "$out" "done: PASS"
has "the block says verify's result line" "$out" "make verify: ok: verify: PASS 4 parts in 1s"
has "the block says the e2e result" "$out" "make e2e: ok"
has "the block says the e2e summary line" "$out" "e2e summary: E2E: PASS 3/3"
has "the block says the run folder" "$out" "e2e run folder: build/e2e/20260101-1"
has "the block says where final.png is" "$out" "/build/e2e/latest/final.png"
has "the block has the tree hash" "$out" "tree: $(git -C "$repo" rev-parse 'HEAD^{tree}')"
has "the block has the diff stat" "$out" "b | 1 +"
has "the block names a clean worktree" "$out" "worktree: clean"
has "a passing run exits 0" "$out" "exit=0"
has "the full e2e ran" "$(cat "$tmp/log")" "E2E=all"

out=$(run 1 0)
has "a failing verify fails the run" "$out" "done: FAIL"
has "a failing verify is in the block" "$out" "make verify: FAIL (exit 2): verify: FAIL lint (1s)"
has "a failing verify skips the e2e" "$out" "make e2e: skip (verify failed)"
has "a failing run exits 1" "$out" "exit=1"

out=$(run 0 1)
has "a failing e2e is in the block" "$out" "make e2e: FAIL (exit 2)"
has "a failing e2e keeps its summary line, not make's" "$out" "e2e summary: E2E: FAIL 2/3"
has "a failing e2e exits 1" "$out" "exit=1"

rmdir "$repo/Vendor/cef"
rmdir "$repo/Vendor"
out=$(run 0 0)
has "a missing Vendor/cef runs make bootstrap" "$out" "== done: bootstrap"
mkdir -p "$repo/Vendor/cef"

# Behind origin/main: origin/main has a commit the branch lacks.
head_two=$(g rev-parse HEAD)
g checkout -q -b upstream HEAD~1
echo c > "$repo/c"
g add c
g commit -qm upstream
g update-ref refs/remotes/origin/main HEAD
g checkout -q "$head_two"
out=$(run 0 0)
has "a branch behind origin/main is refused" "$out" "Rebase onto origin/main first."
has "a refusal exits 2" "$out" "exit=2"
check "a refusal runs nothing" "" "$(cat "$tmp/log")"

g update-ref -d refs/remotes/origin/main
out=$(run 0 0)
has "no origin/main is refused" "$out" "Rebase onto origin/main first."

if [ "$failed" = 0 ]; then echo "done self test: ok"; else
  echo "done self test: FAIL"
  exit 1
fi
