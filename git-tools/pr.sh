#!/usr/bin/env bash
set -euo pipefail

branch="$(git rev-parse --abbrev-ref HEAD)"

if [ "$branch" = "main" ]; then
  echo "❌ main 브랜치에서는 PR 생성 불가"
  exit 1
fi

echo "🚀 push → $branch"
git push -u origin "$branch"

if gh pr view "$branch" >/dev/null 2>&1; then
  echo "ℹ️ PR already exists"
else
  title="$(echo "$branch" | sed 's|/|: |')"
  echo "📝 create PR → $title"
  gh pr create \
    --base main \
    --head "$branch" \
    --title "$title" \
    --body "auto-generated PR"
fi

if [ "${1:-}" = "--merge" ]; then
  echo "🔀 squash merge"
  gh pr merge --squash --delete-branch
fi

echo "✅ done"
