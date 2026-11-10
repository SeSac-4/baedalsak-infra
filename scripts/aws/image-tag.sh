#!/usr/bin/env bash
# =============================================================================
# 앱 이미지 태그 (helm/values/aws-image.yaml) 읽기·커밋·되돌리기 — Argo CD 가 이 파일의 변경을 감지해 배포
#   사용: image-tag.sh get              → 원격 develop 의 태그 출력
#         image-tag.sh set <태그>       → 태그를 바꿔 커밋·push (같으면 그대로)
#         image-tag.sh revert <태그>    → 그 태그를 올린 커밋을 git revert·push 하고 되돌아간 태그 출력
#                                         (develop 의 현재 태그가 <태그> 가 아니면 되돌리지 않고 아무것도 출력하지 않음)
#   워크플로의 체크아웃은 태그 커밋보다 이전일 수 있어 원격 develop 을 임시 worktree 로 받아서 작업
#   push 권한: 호출한 워크플로의 GITHUB_TOKEN contents: write (images.yml · aws-up.yml)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="${IMAGE_TAG_FILE:-helm/values/aws-image.yaml}" # AI 는 helm/values/aws-image-ai.yaml (images-ai.yml)
BRANCH="${GITOPS_REVISION:-develop}"
WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gitops-image-tag-$$"
MSG_PREFIX="chore(deploy): 이미지 태그"

read_tag() { sed -n -E 's/^[[:space:]]*tag:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/p' | head -1; }

fetch() { git -C "$ROOT" fetch -q --depth=50 origin "$BRANCH"; }

checkout() {
  fetch
  git -C "$ROOT" worktree add -q --detach "$WORK" FETCH_HEAD
  trap 'git -C "$ROOT" worktree remove --force "$WORK" 2>/dev/null || true' EXIT
}

git_w() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    git -C "$WORK" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" "$@"
  else
    git -C "$WORK" "$@"
  fi
}

# 동시에 다른 커밋이 들어오면 rebase 후 다시 push (최대 3번)
push() {
  for _ in 1 2 3; do
    git_w push -q origin "HEAD:refs/heads/$BRANCH" && return 0
    echo "push 충돌 — rebase 후 다시 시도" >&2
    git_w pull -q --rebase --depth=50 origin "$BRANCH"
  done
  echo "push 실패" >&2
  return 1
}

case "${1:-}" in
  get)
    fetch
    git -C "$ROOT" show "FETCH_HEAD:$FILE" | read_tag ;;

  set)
    TAG="${2:?태그가 필요합니다}"
    [[ "$TAG" =~ ^[0-9a-f]{7,40}$ ]] || { echo "태그 형식이 아닙니다 (커밋 SHA): $TAG" >&2; exit 1; }
    checkout
    CUR="$(read_tag < "$WORK/$FILE")"
    if [ "$CUR" = "$TAG" ]; then echo "이미 $TAG — 커밋 없음" >&2; exit 0; fi
    sed -i -E "s/^([[:space:]]*tag:[[:space:]]*).*/\1\"$TAG\"/" "$WORK/$FILE"
    git_w add "$FILE"
    git_w commit -q -m "$MSG_PREFIX $TAG"
    push
    echo "태그 커밋: $CUR → $TAG ($BRANCH)" >&2 ;;

  revert)
    TAG="${2:?되돌릴 태그가 필요합니다}"
    checkout
    CUR="$(read_tag < "$WORK/$FILE")"
    if [ "$CUR" != "$TAG" ]; then echo "$BRANCH 의 태그가 $CUR — $TAG 가 아니라 되돌리지 않음" >&2; exit 0; fi
    C="$(git -C "$WORK" log -1 --format=%H --fixed-strings --grep="$MSG_PREFIX $TAG" -- "$FILE")"
    if [ -z "$C" ]; then echo "$TAG 를 올린 커밋을 찾지 못해 되돌리지 않음" >&2; exit 0; fi
    git_w revert --no-edit "$C" >/dev/null
    push
    PREV="$(read_tag < "$WORK/$FILE")"
    echo "태그 되돌림: $TAG → $PREV ($BRANCH, revert $C)" >&2
    echo "$PREV" ;;

  *) sed -n '3,7p' "$0"; exit 1 ;;
esac
