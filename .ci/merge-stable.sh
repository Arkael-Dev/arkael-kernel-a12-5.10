#!/usr/bin/env bash
# Merge an upstream ref (tag or commit) into the current branch.
# usage: [LABEL=android12-5.10-lts] .ci/merge-stable.sh <tag-or-sha>
#
# exit 0  = merge committed (or nothing to merge)
# exit 10 = conflicts left, resolve by hand (repo stays mid-merge)
# exit 1  = other error
set -uo pipefail

TAG="${1:?usage: merge-stable.sh <tag-or-sha>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="${LABEL:-$TAG}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
GITDIR="$(git rev-parse --git-dir)"

git config user.name  >/dev/null || git config user.name  "arkael-merge"
git config user.email >/dev/null || git config user.email "arkael-merge@localhost"
git config rerere.enabled true
git config rerere.autoupdate true

# per-file conflict policy: ours | theirs | union
# fill this in from real conflicts, e.g. from the .273 merge
declare -A POLICY=(
  # ["drivers/cpufreq/Makefile"]=union
  # ["drivers/cpufreq/Kconfig"]=union
)

union_merge() {
  local f="$1" b o t
  b=$(mktemp); o=$(mktemp); t=$(mktemp)
  git show ":1:$f" >"$b" 2>/dev/null || : >"$b"
  git show ":2:$f" >"$o" 2>/dev/null || return 1
  git show ":3:$f" >"$t" 2>/dev/null || return 1
  git merge-file --union -p "$o" "$b" "$t" >"$f" || true
  rm -f "$b" "$o" "$t"
  [ -s "$f" ]
}

# reuse saved rerere resolutions
mkdir -p "$GITDIR/rr-cache"
[ -d "$HERE/rr-cache" ] && cp -r "$HERE/rr-cache/." "$GITDIR/rr-cache/" 2>/dev/null

echo "merging $TAG into $BRANCH"
git merge --no-ff --no-commit "$TAG" || echo "conflicts, trying policy"

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "$TAG is already in $BRANCH"
  exit 0
fi

mapfile -t conflicted < <(git diff --name-only --diff-filter=U)
for f in "${conflicted[@]}"; do
  case "${POLICY[$f]:-}" in
    ours)   git checkout --ours   -- "$f" && git add "$f" && echo "ours:   $f" ;;
    theirs) git checkout --theirs -- "$f" && git add "$f" && echo "theirs: $f" ;;
    union)  union_merge "$f"              && git add "$f" && echo "union:  $f" ;;
  esac
done

# post-merge fixes for build breaks that don't show up as conflicts
# (put idempotent scripts in .ci/fixes/NN-name.sh)
for h in "$HERE"/fixes/*.sh; do
  [ -f "$h" ] || continue
  echo "fix: $h"
  bash "$h" || { echo "fix failed: $h"; exit 1; }
done

mapfile -t left < <(git diff --name-only --diff-filter=U)
if ((${#left[@]})); then
  echo
  echo "conflicts left (${#left[@]}):"
  printf '  %s\n' "${left[@]}"
  echo "resolve, git add, git commit. then save the resolutions:"
  echo "  mkdir -p .ci/rr-cache && cp -r .git/rr-cache/. .ci/rr-cache/"
  exit 10
fi
if git grep -n -E '^(<<<<<<<|>>>>>>>) ' -- '*.c' '*.h' '*.S' 'Makefile' '*Kconfig*' | head -5 | grep .; then
  echo "conflict markers still in tree"
  exit 10
fi

git add -u
SHA="$(git rev-parse --short=12 "$TAG^{commit}")"
VER="$(git show "$TAG:Makefile" | head -5 | awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{print v"."p"."s}')"
COUNT="$(git rev-list --count HEAD..MERGE_HEAD)"
git commit -q \
  -m "Merge $LABEL: update to Linux $VER ($SHA)" \
  -m "Merge Google $LABEL (Linux $VER, $SHA) into $BRANCH. $COUNT new upstream commits." \
  || exit 1
git log --oneline -1
