#!/usr/bin/env bash
#
# Repair a 1Panel app whose "upgrade" button fails with
#   service error: unexpected end of JSON input
#
# Why this happens
# ----------------
# 1Panel keeps one row per app version in its SQLite database (app_details) and
# rebuilds those rows from the directories under
# /opt/1panel/resource/apps/local/<key>/<version>/.  The installed app points at
# one of them through app_installs.app_detail_id.
#
# When a version directory disappears from the store (for example because an
# updater pruned old versions), 1Panel deletes the matching app_details row on
# the next sync.  app_installs.app_detail_id then points at a row that no longer
# exists; 1Panel's lookup helper uses Find() instead of First(), so it returns an
# empty struct with a nil error and the caller unmarshals an empty string --
# which Go reports as "unexpected end of JSON input".  Restarting the panel or
# re-downloading the package cannot fix that, because the reference itself is
# stale.
#
# What this script does
# ---------------------
# 1. Finds the panel database that actually holds app_installs (1Panel v1 keeps
#    it in 1Panel.db, v2 keeps it in agent.db).
# 2. Re-points app_installs.app_detail_id at the row of the installed version.
#
# Requires sqlite3 or python3 on the host.  Nothing is written unless the version
# directory and the matching app_details row both exist.

set -Eeuo pipefail

APP_KEY="zerotier-planet"
PANEL_DIR="${PANEL_DIR:-/opt/1panel}"
DB="${PANEL_DB:-}"
LIST_DBS=0
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'USAGE'
用法: sudo bash repair-1panel-app.sh [选项]

修复 1Panel 里「升级」报 "unexpected end of JSON input" 的应用记录。

选项:
  --app <key>        应用 key（默认 zerotier-planet）
  --panel-dir <dir>  1Panel 安装目录（默认 /opt/1panel）
  --db <file>        直接指定 SQLite 数据库（默认自动探测）
  --list-dbs         只列出探测到的数据库与其中的 app_installs 表，然后退出
  --dry-run          只打印将要执行的 SQL，不改数据库
  -y, --yes          不询问，直接写入
  -h, --help         显示本帮助

数据库位置：
  1Panel v1 把应用记录放在 db/1Panel.db；v2 拆成 core 与 agent 两个进程，
  应用安装记录在 db/agent.db 里。脚本会依次探测 db/agent.db、db/1Panel.db、
  db/core.db 以及 db/ 下任意带有 app_installs 表的 *.db。

前置条件：版本目录必须已经存在。先运行一次计划的更新脚本
（scripts/1panel-scheduled-update.sh），它会补回已安装版本的目录。
USAGE
}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) [ "$#" -ge 2 ] || die "--app 需要一个值"; APP_KEY="$2"; shift 2 ;;
    --panel-dir) [ "$#" -ge 2 ] || die "--panel-dir 需要一个值"; PANEL_DIR="$2"; shift 2 ;;
    --db) [ "$#" -ge 2 ] || die "--db 需要一个值"; DB="$2"; shift 2 ;;
    --list-dbs) LIST_DBS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [ "${ZTP_SKIP_ROOT_CHECK:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "需要 root 权限（读写 $PANEL_DIR 与 SQLite 数据库），请用 sudo 运行"
fi

[ -d "$PANEL_DIR" ] || die "找不到 1Panel 目录：$PANEL_DIR（用 --panel-dir 指定；Docker 部署的 1Panel 需先把数据库复制出来）"

command -v sqlite3 >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || \
  die "需要 sqlite3 或 python3 才能读写数据库（Debian/Ubuntu: apt install sqlite3；CentOS: yum install sqlite）"

# Run one SQL statement against a specific database file.
sqlite_on() {
  local file="$1" sql="$2"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$file" "$sql"
  else
    python3 - "$file" "$sql" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in tuple(row)))
con.commit()
con.close()
PY
  fi
}

has_app_installs() {
  local file="$1" hit
  [ -f "$file" ] || return 1
  hit="$(sqlite_on "$file" "SELECT name FROM sqlite_master WHERE type='table' AND name='app_installs';" 2>/dev/null || true)"
  [ "$hit" = "app_installs" ]
}

# Candidate databases, most likely first.  v2 keeps app records in agent.db.
candidates=()
[ -n "$DB" ] && candidates+=("$DB")
candidates+=(
  "$PANEL_DIR/db/agent.db"
  "$PANEL_DIR/db/1Panel.db"
  "$PANEL_DIR/db/core.db"
  "$PANEL_DIR/data/1Panel.db"
)
if [ -d "$PANEL_DIR/db" ]; then
  for f in "$PANEL_DIR"/db/*.db; do
    [ -e "$f" ] || continue
    skip=0
    for c in "${candidates[@]}"; do [ "$c" = "$f" ] && skip=1; done
    [ "$skip" -eq 0 ] && candidates+=("$f")
  done
fi

if [ "$LIST_DBS" -eq 1 ]; then
  for f in "${candidates[@]}"; do
    [ -f "$f" ] || continue
    if has_app_installs "$f"; then
      printf '  %s  <- has app_installs\n' "$f"
    else
      printf '  %s\n' "$f"
    fi
  done
  exit 0
fi

found=""
for f in "${candidates[@]}"; do
  if [ -n "$DB" ] && [ "$f" != "$DB" ]; then continue; fi
  if has_app_installs "$f"; then found="$f"; break; fi
done

if [ -z "$found" ]; then
  printf '错误：在 %s 下没有找到包含 app_installs 表的数据库。\n' "$PANEL_DIR" >&2
  printf '已尝试：\n' >&2
  for f in "${candidates[@]}"; do
    if [ -f "$f" ]; then printf '  %s\n' "$f" >&2; else printf '  %s（不存在）\n' "$f" >&2; fi
  done
  cat >&2 <<'HINT'

可以这样自查：
  sudo find /opt/1panel -maxdepth 3 -name '*.db' -ls
  # 找到候选后先确认它在哪个库里：
  sudo bash repair-1panel-app.sh --db /opt/1panel/db/agent.db --list-dbs
如果是 Docker 里的 1Panel，先把数据库复制出来再修：
  docker cp 1panel:/opt/1panel/db/agent.db /tmp/agent.db    # v2
  docker cp 1panel:/opt/1panel/db/1Panel.db /tmp/1Panel.db  # v1
  sudo bash repair-1panel-app.sh --db /tmp/agent.db -y
HINT
  exit 1
fi
DB="$found"
log "数据库：$DB"

APP_DIR="$PANEL_DIR/resource/apps/local/$APP_KEY"
APP_ROOT="$PANEL_DIR/apps/$APP_KEY"
COMPOSE="$APP_ROOT/docker-compose.yml"
[ -d "$APP_DIR" ] || die "找不到应用目录：$APP_DIR"
[ -f "$COMPOSE" ] || die "找不到应用的 compose 文件：$COMPOSE"

ref="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$COMPOSE" | head -n1)"
version="${ref##*:}"
[ -n "$version" ] || die "读不到已安装版本（$COMPOSE 里没有 image 行）"
log "已安装版本：$version"

[ -d "$APP_DIR/$version" ] || die "版本目录不存在：$APP_DIR/$version
先运行更新脚本（scripts/1panel-scheduled-update.sh），它会补回该目录"

row="$(sqlite_on "$DB" "SELECT id, app_id, version, app_detail_id FROM app_installs WHERE name = '$APP_KEY';")"
[ -n "$row" ] || die "数据库里没有名为 $APP_KEY 的已安装记录（这台机器可能不是用 1Panel 装的这个应用）"
IFS='|' read -r install_id app_id install_ver detail_id <<<"$row"
log "安装记录：id=$install_id app_id=$app_id version=$install_ver app_detail_id=$detail_id"

detail_row="$(sqlite_on "$DB" "SELECT id FROM app_details WHERE app_id = $app_id AND version = '$install_ver';")"
[ -n "$detail_row" ] || die "app_details 里没有 $install_ver 的记录。
先在面板「应用商店」点一次「更新应用列表」（或重启面板），让 1Panel 重新扫描本地应用，然后重跑本脚本。"

if [ "$detail_id" = "$detail_row" ]; then
  log "app_detail_id 已指向 $install_ver 的记录（id=$detail_row），无需修复"
  exit 0
fi

log "将把 app_installs.app_detail_id 从 ${detail_id:-空} 改为 $detail_row"
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] UPDATE app_installs SET app_detail_id = $detail_row WHERE id = $install_id;"
  exit 0
fi
if [ "$ASSUME_YES" -ne 1 ]; then
  printf '继续写入数据库？[y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
fi

sqlite_on "$DB" "UPDATE app_installs SET app_detail_id = $detail_row WHERE id = $install_id;" >/dev/null
check="$(sqlite_on "$DB" "SELECT app_detail_id FROM app_installs WHERE id = $install_id;")"
[ "$check" = "$detail_row" ] || die "写入失败（当前值：$check）"
log "修复完成：app_installs.app_detail_id = $detail_row"
log "回到面板刷新页面即可再次升级；若仍报错，重启面板进程后重试。"
