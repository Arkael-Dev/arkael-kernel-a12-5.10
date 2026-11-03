#!/usr/bin/env bash
# SUBLEVEL always follows the upstream (Google) branch being merged, not a manual bump.
set -eu
[ "${KEEP_SUBLEVEL:-}" = 1 ] && { echo "keeping branch SUBLEVEL"; exit 0; }
sub=$(git show MERGE_HEAD:Makefile | head -5 | awk '/^SUBLEVEL =/{print $3; exit}')
[ -n "$sub" ] || exit 1
sed -i "0,/^SUBLEVEL = .*/s//SUBLEVEL = $sub/" Makefile
git add Makefile
echo "SUBLEVEL = $sub (from MERGE_HEAD)"
