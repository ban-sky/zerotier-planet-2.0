#!/usr/bin/env bash
#
# Mirror the 1Panel app package of this repository into a separate app-store
# repository (ban-sky/appstore by default), so the same directory can be
# subscribed to from several 1Panel panels.
#
# The copy is additive: versions that already exist in the store are kept, and
# the ones from this package are added or refreshed. Nothing is ever removed,
# which is what keeps the panel's app_details rows alive (see the "unexpected
# end of JSON input" note in README.md).
#
# Usage:
#   APPSTORE_TOKEN=... scripts/sync-1panel-appstore.sh
#   scripts/sync-1panel-appstore.sh --store-dir /path/to/appstore --no-push
#
set -Eeuo pipefail

APP_KEY="${APP_KEY:-zerotier-planet}"
SOURCE_DIR="${SOURCE_DIR:-1panel/apps/$APP_KEY}"
STORE_REPO="${STORE_REPO:-ban-sky/appstore}"
STORE_BRANCH="${STORE_BRANCH:-main}"
STORE_DIR="${STORE_DIR:-}"
TOKEN="${APPSTORE_TOKEN:-}"
MESSAGE=""
DRY_RUN=0
KEEP_DIR=0

log() { printf '%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: sync-1panel-appstore.sh [选项]

把本仓库的 1Panel 应用包同步到独立的 AppStore 仓库。

选项:
  --store-dir <dir>   已克隆好的 AppStore 仓库路径（给了就不再自己 clone）
  --repo <owner/name> AppStore 仓库，默认 ban-sky/appstore
  --branch <name>     分支，默认 main
  --message <text>    提交信息，默认带当前版本号
  --no-push           只提交，不推送
  --keep              不删除临时克隆
  --dry-run           只打印将要做的动作
  -h, --help          显示本帮助

环境变量:
  APPSTORE_TOKEN      推送用的 token（需要对 AppStore 仓库有写权限）
  APP_KEY             应用目录名，默认 zerotier-planet
  SOURCE_DIR          源目录，默认 1panel/apps/<APP_KEY>
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --store-dir) [ $# -ge 2 ] || die "--store-dir 缺少参数"; STORE_DIR="$2"; KEEP_DIR=1; shift 2 ;;
    --repo) [ $# -ge 2 ] || die "--repo 缺少参数"; STORE_REPO="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || die "--branch 缺少参数"; STORE_BRANCH="$2"; shift 2 ;;
    --message) [ $# -ge 2 ] || die "--message 缺少参数"; MESSAGE="$2"; shift 2 ;;
    --no-push) KEEP_DIR=1; NO_PUSH=1; shift ;;
    --keep) KEEP_DIR=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done
NO_PUSH="${NO_PUSH:-0}"

[ -d "$SOURCE_DIR" ] || die "找不到应用包目录：$SOURCE_DIR"
[ -f "$SOURCE_DIR/data.yml" ] || die "$SOURCE_DIR 缺少 data.yml"

version="$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)"
[ -n "$version" ] || die "$SOURCE_DIR 下没有版本目录"
MESSAGE="${MESSAGE:-Sync $APP_KEY $version from the upstream repository}"

created=""
if [ -n "$STORE_DIR" ]; then
  [ -d "$STORE_DIR/.git" ] || die "$STORE_DIR 不是 git 仓库"
else
  [ -n "$TOKEN" ] || die "需要 APPSTORE_TOKEN（或给 --store-dir 指向已克隆的仓库）"
  created="$(mktemp -d)"
  STORE_DIR="$created/appstore"
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] git clone --depth 1 --branch $STORE_BRANCH https://github.com/$STORE_REPO.git"
  else
    git clone --depth 1 --branch "$STORE_BRANCH" \
      "https://x-access-token:${TOKEN}@github.com/${STORE_REPO}.git" "$STORE_DIR" 2>/dev/null \
      || die "无法克隆 $STORE_REPO（token 无效或没有权限？）"
  fi
fi

cleanup() {
  if [ -n "$created" ] && [ "$KEEP_DIR" = 0 ]; then
    node -e 'require("fs").rmSync(process.argv[1], {recursive: true, force: true})' "$created" 2>/dev/null || true
  fi
}
trap cleanup EXIT

target="$STORE_DIR/apps/$APP_KEY"
log "同步 $SOURCE_DIR -> $target（版本 $version）"
if [ "$DRY_RUN" = 0 ]; then
  mkdir -p "$target"
  cp -a "$SOURCE_DIR"/. "$target"/
fi

# Keep the store's README table in sync when it declares a managed block.
readme="$STORE_DIR/README.md"
if [ -f "$readme" ] && grep -q 'zerotier-planet:begin' "$readme" 2>/dev/null; then
  if [ "$DRY_RUN" = 0 ]; then
    node - "$readme" "$version" <<'NODE'
const fs = require('fs');
const [file, version] = process.argv.slice(2);
const begin = '<!-- zerotier-planet:begin -->';
const end = '<!-- zerotier-planet:end -->';
let text = fs.readFileSync(file, 'utf8');
const start = text.indexOf(begin);
const stop = text.indexOf(end);
if (start < 0 || stop < start) process.exit(0);
const row = `| [zerotier-planet](apps/zerotier-planet) | \`${version}\` | 自托管 ZeroTier planet + 控制器 |`;
text = text.slice(0, start + begin.length) + '\n' + row + '\n' + text.slice(stop);
fs.writeFileSync(file, text);
NODE
  fi
else
  log "（$STORE_REPO 的 README.md 没有 zerotier-planet 标记块，跳过表格更新）"
fi

if [ ! -d "$STORE_DIR/.git" ]; then
  log "[dry-run] 跳过 git 提交"
  exit 0
fi

cd "$STORE_DIR"
git add -A
if git diff --cached --quiet; then
  log "AppStore 已经是最新，无需提交"
  exit 0
fi
if [ "$DRY_RUN" = 1 ]; then
  log "[dry-run] 将提交：$MESSAGE"
  exit 0
fi
git -c user.name="ban-sky" -c user.email="ban-sky@users.noreply.github.com" commit -q -m "$MESSAGE"
log "已提交：$MESSAGE"
if [ "$NO_PUSH" = 1 ]; then
  log "（--no-push，未推送）"
  exit 0
fi
git -c credential.helper= push origin "HEAD:$STORE_BRANCH" 2>&1 | tail -2
log "已推送到 $STORE_REPO ($STORE_BRANCH)"
