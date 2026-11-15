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
# 1. Restores the missing version directory (fetches it from the GitHub tag).
# 2. Re-points app_installs.app_detail_id at the row of the installed version.
#
# Requires sqlite3 or python3 on the host.  Nothing is written unless both the
# version directory and the matching app_details row exist.

set -Eeuo pipefail

APP_KEY="zerotier-planet"
PANEL_DIR="${PANEL_DIR:-/opt/1panel}"
DB="${PANEL_DB:-}"
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<'USAGE'
用法: sudo bash repair-1panel-app.sh [选项]

修复 1Panel 里「升级」报 "unexpected end of JSON input" 的应用记录。

选项:
  --app <key>        应用 key（默认 zerotier-planet）
  --panel-dir <dir>  1Panel 安装目录（默认 /opt/1panel）
  --db <file>        直接指定 SQLite 数据库（默认 <panel-dir>/db/1Panel.db）
  --dry-run          只打印将要执行的 SQL，不改数据库
  -y, --yes          不询问，直接写入
  -h, --help         显示本帮助

前置条件：版本目录必须已经存在。先运行一次计划的更新脚本
（scripts/1panel-scheduled-update.sh），它会补回已安装版本的目录。
USAGE
}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '%s WARN %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) [ "$#" -ge 2 ] || die "--app 需要一个值"; APP_KEY="$2"; shift 2 ;;
    --panel-dir) [ "$#" -ge 2 ] || die "--panel-dir 需要一个值"; PANEL_DIR="$2"; shift 2 ;;
    --db) [ "$#" -ge 2 ] || die "--db 需要一个值"; DB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [ "${ZTP_SKIP_ROOT_CHECK:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "需要 root 权限（读写 $PANEL_DIR 与 SQLite 数据库），请用 sudo 运行"
fi

[ -n "$DB" ] || DB="$PANEL_DIR/db/1Panel.db"
[ -f "$DB" ] || die "找不到数据库：$DB（用 --db 指定）"

APP_DIR="$PANEL_DIR/resource/apps/local/$APP_KEY"
APP_ROOT="$PANEL_DIR/apps/$APP_KEY"
COMPOSE="$APP_ROOT/docker-compose.yml"
[ -d "$APP_DIR" ] || die "找不到应用目录：$APP_DIR"

version=""
if [ -f "$COMPOSE" ]; then
  ref="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$COMPOSE" | head -n1)"
  version="${ref##*:}"
fi
[ -n "$version" ] || die "读不到已安装版本（$COMPOSE 里没有 image 行），可用面板确认后重试"
log "已安装版本：$version"

[ -d "$APP_DIR/$version" ] || die "版本目录不存在：$APP_DIR/$version
先运行更新脚本（scripts/1panel-scheduled-update.sh），它会补回该目录"

# Pick a SQLite client.
sqlite_exec() {
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$DB" "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.row_factory = sqlite3.Row
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in tuple(row)))
con.commit()
con.close()
PY
  else
    die "需要 sqlite3 或 python3 才能修改数据库；也可手动执行下面的 SQL：
    UPDATE app_installs SET app_detail_id = (
      SELECT d.id FROM app_details d
      WHERE d.app_id = app_installs.app_id AND d.version = '$version'
    ) WHERE name = '$APP_KEY';"
  fi
}

row="$(sqlite_exec "SELECT id, app_id, version, app_detail_id FROM app_installs WHERE name = '$APP_KEY';")"
[ -n "$row" ] || die "数据库里没有名为 $APP_KEY 的已安装记录"
IFS='|' read -r install_id app_id install_ver detail_id <<<"$row"
log "安装记录：id=$install_id app_id=$app_id version=$install_ver app_detail_id=$detail_id"

detail_row="$(sqlite_exec "SELECT id FROM app_details WHERE app_id = $app_id AND version = '$install_ver';")"
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

sqlite_exec "UPDATE app_installs SET app_detail_id = $detail_row WHERE id = $install_id;" >/dev/null
check="$(sqlite_exec "SELECT app_detail_id FROM app_installs WHERE id = $install_id;")"
[ "$check" = "$detail_row" ] || die "写入失败（当前值：$check）"
log "修复完成：app_installs.app_detail_id = $detail_row"
log "回到面板刷新页面即可再次升级；若仍报错，重启面板进程（systemctl restart 1panel）后重试。"
