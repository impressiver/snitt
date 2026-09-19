#!/usr/bin/env bash
#
# Publishes docs/wiki/ to the GitHub wiki.
#
# Usage:  Scripts/publish-wiki.sh [--dry-run]
#
# WHY THE SOURCE IS NOT THE WIKI
#
# A GitHub wiki is a separate git repository with no pull requests and no
# review: anyone with push access rewrites a page and nobody sees a diff. Snitt
# documents things whose wrongness is expensive — which permissions it asks
# for, what a recording contains, what leaves the machine — so the copy people
# read is generated from one that went through review.
#
# docs/wiki/ is the master. This script makes the wiki match it. Editing a page
# in the wiki UI works and will be overwritten by the next run, which is the
# intended trade rather than an accident.
set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE_DIR="docs/wiki"
WIKI_REMOTE="git@github.com:impressiver/snitt.wiki.git"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -d "$SOURCE_DIR" ] || { echo "error: $SOURCE_DIR does not exist" >&2; exit 1; }

# The wiki repository does not exist until the wiki has been ENABLED and given
# a first page. On a private repository under a free plan the setting is not
# available at all, which is why this fails cleanly and says so rather than
# leaving a half-pushed wiki: Snitt was private for its whole pre-1.0 life.
if ! git ls-remote "$WIKI_REMOTE" >/dev/null 2>&1; then
  echo "error: $WIKI_REMOTE is not reachable." >&2
  echo "       The wiki repository does not exist until the wiki is enabled" >&2
  echo "       AND has one page. Enable it in Settings ▸ General ▸ Features," >&2
  echo "       create any page in the browser, then re-run this." >&2
  exit 1
fi

WORK="$(mktemp -d -t snitt-wiki)"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet --depth 1 "$WIKI_REMOTE" "$WORK/wiki"

# Deleted from the source means deleted from the wiki. Without this a page that
# was removed in review stays published for ever, which is the failure mode that
# makes generated documentation less trustworthy than handwritten.
find "$WORK/wiki" -maxdepth 1 -name '*.md' -delete

# README.md explains the arrangement to somebody reading the repo. It is not a
# page.
for page in "$SOURCE_DIR"/*.md; do
  [ "$(basename "$page")" = "README.md" ] && continue
  cp "$page" "$WORK/wiki/"
done

cd "$WORK/wiki"
if git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ]; then
  echo "==> wiki is already up to date"
  exit 0
fi

git add -A
git -c user.name="$(git -C "$OLDPWD" config user.name)" \
    -c user.email="$(git -C "$OLDPWD" config user.email)" \
    commit --quiet -m "docs: publish from docs/wiki@$(git -C "$OLDPWD" rev-parse --short HEAD)"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> [dry-run] would push:"
  git --no-pager show --stat --oneline HEAD
  exit 0
fi

git push --quiet origin HEAD
echo "==> published to https://github.com/impressiver/snitt/wiki"
