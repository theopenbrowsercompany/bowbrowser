#!/bin/bash
# Tests scripts/e2e-flakes.sh in ledger mode on a canned ledger and a canned list of origin/main's trees (--main-trees),
# so it touches neither the real ledger nor git: a failure on a tree of origin/main is marked ON MAIN (also when the
# ledger's tree carries a -<hash> suffix), and a FILE test lists its failures and each branch's share of the test's runs
# in the failure window (the e2e.isolation case of retro 3: the failures ran on main's tree, and the suspected branch
# ran 14 of the 20 runs). Takes a second.
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

main_tree=0447a8a7aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other_main=1111111111111111111111111111111111111111
branch_tree=feedfacebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '%s\n%s\n' "$main_tree" "$other_main" > "$tmp/main-trees"

start=$(($(date +%s) - 3 * 3600))
i=0
ledger=$tmp/ledger.tsv
printf 'date\ttest\toutcome\tbranch\ttree\tload\tshard\trun\n' > "$ledger"
line() { # line <test> <outcome> <branch> <tree>: the next minute of the canned history
  i=$((i + 1))
  printf '%s\t%s\t%s\t%s\t%s\t1.00\t-\tr%d\n' "$(date -u -r $((start + i * 60)) +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$i" >> "$ledger"
}
# e2e.isolation: 20 runs in the window from its first to its last failure. The first failure ran on main's tree, the
# last on main's tree with an untracked file suffix; the suspect branch ran 14 of the 20 runs and failed once on its own tree.
line e2e.isolation FAIL other "$main_tree"
line e2e.isolation FAIL suspect "$branch_tree"
for _ in $(seq 13); do line e2e.isolation PASS suspect "$branch_tree"; done
line e2e.isolation PASS other "$main_tree"
for _ in $(seq 3); do line e2e.isolation PASS other "$other_main"; done
line e2e.isolation FLAKY other "$main_tree-0a1b2c3d"
# t.plain: one FLAKY only, so it is not filed and prints no detail.
line t.plain FLAKY suspect "$branch_tree"
line t.plain PASS suspect "$branch_tree"
# t.mine: two events that never ran on main's trees.
line t.mine FLAKY suspect "$branch_tree"
line t.mine FLAKY suspect "$branch_tree"
# t.unknown: failures with no tree stamp are never on main.
line t.unknown FLAKY suspect unknown
line t.unknown FLAKY suspect unknown

out=$(./scripts/e2e-flakes.sh --ledger "$ledger" --main-trees "$tmp/main-trees")
row() { echo "$out" | awk -v t="$1" '$1 == t { print $2, $7, $8, $9 }'; }
check "e2e.isolation: 20 runs, 3 events, FILE, 2 failures on main" "20 3 FILE 2" "$(row e2e.isolation)"
check "a test with one event is not filed and has no failures on main" "2 1 - 0" "$(row t.plain)"
check "failures on the branch's own tree are not on main" "2 2 FILE 0" "$(row t.mine)"
check "a tree with no stamp is never on main" "2 2 FILE 0" "$(row t.unknown)"
has "the first failure is marked ON MAIN" "$out" "  FAIL $(date -u -r $((start + 60)) +%Y-%m-%dT%H:%M:%SZ) other tree 0447a8a7 ON MAIN"
has "a failure on a suffixed main tree is marked ON MAIN" "$out" "other tree 0447a8a7 ON MAIN"$'\n'"  window"
has "the branch's own failure is not marked" "$out" "  FAIL $(date -u -r $((start + 120)) +%Y-%m-%dT%H:%M:%SZ) suspect tree feedface"$'\n'
has "the failure window lists each branch's share of the runs" "$out" "suspect 14/20 runs, other 6/20 runs"
check "only filed tests print a window: 3 windows" "3" "$(echo "$out" | grep -c '^  window ')"

# Without --main-trees it reads git log of origin/main; a missing ref marks nothing and does not fail.
out=$(BOW_E2E_LEDGER="$ledger" ./scripts/e2e-flakes.sh --ledger "$ledger")
has "no --main-trees: still prints the table" "$out" "ON MAIN"
check "an unreadable --main-trees file exits 1" "1" "$(./scripts/e2e-flakes.sh --ledger "$ledger" --main-trees "$tmp/none" > /dev/null 2>&1; echo $?)"
check "--main-trees with --local exits 64" "64" "$(./scripts/e2e-flakes.sh --main-trees "$tmp/main-trees" --local > /dev/null 2>&1; echo $?)"

if [ "$failed" = 0 ]; then echo "e2e-flakes self test: ok"; else
  echo "e2e-flakes self test: FAIL"
  exit 1
fi
