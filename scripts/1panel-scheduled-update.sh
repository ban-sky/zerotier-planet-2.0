#!/usr/bin/env bash
#
# Keep the 1Panel app store package (and the running app) up to date.
#
# This is the scripted equivalent of how https://github.com/okxlin/appstore ships
# its own local app store: a 1Panel "Cron job" (计划任务, type *Shell script*)
# drops the app definition into /opt/1panel/resource/apps/local/, and the panel
# then lists the new version.
#
# Sources, in the order the default (`auto`) tries them:
#
#   release  1panel-app-<tag>.tar.gz from the newest GitHub Release, verified
#            against SHA256SUMS. Falls back to the GitHub mirrors below.
#   cdn      the same files assembled from jsDelivr (cdn.jsdelivr.net and its
#            sibling hosts), which stays reachable on mainland-China servers
#            where github.com / api.github.com are blocked.
#   branch   the repository tarball of --branch, copying
#            1panel/apps/zerotier-planet out of it (the okxlin/appstore
#            "localApps branch" pattern).
#   dir      a local directory (--from-dir), no network at all.
#
# After the package is in place the script (unless --no-restart) re-points the
# installed app's compose file at the new image tag and runs
# `docker compose pull && docker compose up -d`.
#
# Try it first with --dry-run, then add the cron entry:
#
#   /opt/zerotier-planet-2.0/scripts/1panel-scheduled-update.sh --quiet
#
# Exit codes: 0 = success / already current, 1 = error, 2 = usage error.
#
set -Eeuo pipefail

APP_KEY=zerotier-planet
REPO="ban-sky/zerotier-planet-2.0"
IMAGE="${IMAGE:-docker.io/lonelyx/zerotier-planet}"
DEFAULT_PANEL_DIR=/opt/1panel
DEFAULT_BRANCH=main

# Repository mirrors that serve plain files. Each entry is "<kind> <base>",
# because the two families use different URL shapes:
#   jsdelivr  <base>/<owner>/<repo>@<ref>/<path>   (e.g. cdn.jsdelivr.net/gh)
#   raw       <base>/<owner>/<repo>/<ref>/<path>   (e.g. raw.gitmirror.com)
# jsDelivr has several PoPs that stay reachable from mainland China; the raw
# mirrors cover the case where the jsDelivr domain itself is unavailable.
CDN_MIRRORS=(
  "jsdelivr https://cdn.jsdelivr.net/gh"
  "jsdelivr https://fastly.jsdelivr.net/gh"
  "jsdelivr https://gcore.jsdelivr.net/gh"
  "jsdelivr https://testingcf.jsdelivr.net/gh"
  "raw https://rawcdn.githack.com"
)

# ghproxy-style front ends for github.com. They are only used once the direct
# request has failed, so a working network never pays for them.
DEFAULT_MIRRORS=(
  "https://ghfast.top/"
  "https://gh-proxy.com/"
  "https://ghproxy.net/"
)

panel_dir="${PANEL_DIR:-$DEFAULT_PANEL_DIR}"
source_mode=auto
branch="$DEFAULT_BRANCH"
tag=""
from_dir=""
mirrors=()
dry_run=0
quiet=0
restart=1
keep_downloads=0
keep_versions=5
use_db=1
db=""

log() { [ "$quiet" -eq 1 ] || printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
warn() { printf '%s WARN %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf '%s ERROR %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: 1panel-scheduled-update.sh [options]

Update the 1Panel local app store package of ZeroTier Planet (and optionally the
running container) to the newest available version.

Options:
  --source <auto|release|cdn|branch|dir>
                     Where to take the package from (default: auto).
                       auto     try release, then fall back to cdn
                       release  newest GitHub Release asset
                                1panel-app-<tag>.tar.gz, verified against
                                SHA256SUMS
                       cdn      assemble the same files from jsDelivr; use this
                                on mainland-China servers where github.com is
                                unreachable
                       branch   repository tarball of --branch, copying
                                1panel/apps/zerotier-planet out of it
                                (the okxlin/appstore localApps pattern)
                       dir      install from --from-dir, no network at all
  --from-dir <path>  Repository checkout (or the app directory itself) used by
                     --source dir. Implies --source dir.
  --branch <name>    Branch used by --source branch (default: main).
  --tag <vX.Y.Z>     Pin a specific release (implies --source release).
  --mirror <prefix>  Extra GitHub mirror for release downloads, e.g.
                     --mirror https://ghproxy.net/ . May be repeated. When it is
                     omitted a built-in list is tried after the direct request.
                     Also settable as GITHUB_MIRROR.
  --panel-dir <dir>  1Panel installation directory (default: /opt/1panel, or
                     $PANEL_DIR).
  --no-restart       Only refresh the app store package; leave the running
                     container untouched.
  --keep-versions <n>
                     How many version directories to keep in the store package
                     (default: 5). 1Panel lists every directory it finds, so the
                     last few releases stay selectable when you need to roll
                     back. 0 keeps them all.
  --no-db            Skip the 1Panel SQLite step. The script otherwise points
                     app_installs.app_detail_id back at the right version after
                     a sync, which is what makes the panel upgrade button work
                     again; only disable this if the database is not local.
  --keep-downloads   Leave the downloaded archive in the temp directory.
  --dry-run          Report what would change and exit without touching anything.
  --quiet            Only log warnings and errors (cron friendly).
  -h, --help         Show this help.

Typical 1Panel cron job:
  1. Panel -> Cron job -> Create -> Type: Shell script
  2. Command: /path/to/scripts/1panel-scheduled-update.sh --quiet
  3. Schedule: daily, or every 6 hours.

Without a checkout, paste this into the cron command instead:
  curl -fsSL https://raw.githubusercontent.com/ban-sky/zerotier-planet-2.0/main/scripts/1panel-scheduled-update.sh -o /tmp/ztp-1panel-update.sh && bash /tmp/ztp-1panel-update.sh --quiet

If that download itself is blocked, take the script from the CDN:
  curl -fsSL https://cdn.jsdelivr.net/gh/ban-sky/zerotier-planet-2.0@main/scripts/1panel-scheduled-update.sh -o /tmp/ztp-1panel-update.sh

Exit codes: 0 success or already current, 1 error, 2 usage error.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || die "--source 需要一个值"; source_mode="$2"; shift 2 ;;
    --from-dir) [ "$#" -ge 2 ] || die "--from-dir 需要一个值"; from_dir="$2"; source_mode=dir; shift 2 ;;
    --branch) [ "$#" -ge 2 ] || die "--branch 需要一个值"; branch="$2"; shift 2 ;;
    --tag) [ "$#" -ge 2 ] || die "--tag 需要一个值"; tag="$2"; shift 2 ;;
    --mirror) [ "$#" -ge 2 ] || die "--mirror 需要一个值"; mirrors+=("$2"); shift 2 ;;
    --panel-dir) [ "$#" -ge 2 ] || die "--panel-dir 需要一个值"; panel_dir="$2"; shift 2 ;;
    --no-restart) restart=0; shift ;;
    --keep-versions) [ "$#" -ge 2 ] || die "--keep-versions 需要一个值"; keep_versions="$2"; shift 2 ;;
    --no-db) use_db=0; shift ;;
    --keep-downloads) keep_downloads=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$source_mode" in
  auto|release|cdn|branch|dir) ;;
  *) die "--source 只能是 auto、release、cdn、branch 或 dir，收到：$source_mode" ;;
esac

case "$keep_versions" in
  ''|*[!0-9]*) die "--keep-versions 需要一个非负整数，收到：$keep_versions" ;;
esac

# --tag pins a release, so keep the mode consistent with it.
if [ -n "$tag" ] && [ "$source_mode" = auto ]; then
  source_mode=release
fi

# An explicit --mirror wins; otherwise try the built-in front ends after the
# direct request. GITHUB_MIRROR is the environment-variable spelling.
if [ "${#mirrors[@]}" -eq 0 ] && [ -n "${GITHUB_MIRROR:-}" ]; then
  mirrors=("$GITHUB_MIRROR")
fi
if [ "${#mirrors[@]}" -eq 0 ]; then
  mirrors=("${DEFAULT_MIRRORS[@]}")
fi
for i in "${!mirrors[@]}"; do
  case "${mirrors[$i]}" in
    */) ;;
    *) mirrors[$i]="${mirrors[$i]}/" ;;
  esac
done

# Root is required because the package lands under /opt/1panel. Set
# ZTP_SKIP_ROOT_CHECK=1 to exercise the script against a throwaway --panel-dir.
if [ "${ZTP_SKIP_ROOT_CHECK:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "需要 root 权限（写入 $panel_dir），请用 sudo 运行"
fi

case "$panel_dir" in
  /|/opt) die "拒绝写入 $panel_dir：请用 --panel-dir 指定 1Panel 安装目录" ;;
esac

store_root="$panel_dir/resource/apps/local"
target="$store_root/$APP_KEY"
apps_root="$panel_dir/apps/$APP_KEY"

command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar >/dev/null 2>&1 || die "缺少 tar"


# One attempt, short and bounded: a blocked host has to fail fast instead of
# retrying for minutes (that is what made this script look like it "kept
# retrying" on mainland-China servers).
curl_get() { # url dest
  curl -fsSL --connect-timeout 8 --max-time 180 --retry 1 --retry-delay 1 -o "$2" "$1"
}

# Try the URL directly, then through every configured mirror.
fetch_any() { # url dest
  local url="$1" dest="$2" base
  if curl_get "$url" "$dest"; then return 0; fi
  for base in "${mirrors[@]}"; do
    if curl_get "${base}${url}" "$dest"; then
      log "（经镜像 $base）"
      return 0
    fi
  done
  return 1
}

# Highest installed version directory, or empty.
installed_version() {
  if [ -d "$target" ]; then
    ( cd "$target" && ls -1d [0-9]* 2>/dev/null | sort -V | tail -n1 ) || true
  fi
}

# 1Panel installs an app from the local store under apps/local/<key>/<key>;
# apps installed from the official store live under apps/<key>. Both layouts
# exist in the wild, so look the compose file up instead of assuming one.
find_compose() {
  local dir
  for dir in \
    "$panel_dir/apps/$APP_KEY" \
    "$panel_dir/apps/local/$APP_KEY/$APP_KEY" \
    "$panel_dir/apps/local/$APP_KEY"; do
    if [ -f "$dir/docker-compose.yml" ]; then
      printf '%s\n' "$dir/docker-compose.yml"
      return 0
    fi
  done
  return 0
}

# Version the running app is pinned to, read from its compose file. 1Panel's
# own state lives in SQLite; this file is the only host-side hint we can read.
dry_restart_hint() {
  local compose
  compose="$(find_compose)"
  if [ -n "$compose" ]; then
    log "[dry-run] 之后会在 $(dirname "$compose") 重启应用"
  else
    log "[dry-run] 之后会重启应用（若已安装）"
  fi
}

deployed_version() {
  local compose ref ver
  compose="$(find_compose)"
  [ -n "$compose" ] || return 0
  ref="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$compose" | head -n1)"
  ver="${ref##*:}"
  case "$ver" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$ver" ;;
  esac
}

# True when $1 is not older than $2 (both x.y.z).
not_older() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Newest tag without requiring api.github.com, which is blocked in some
# networks. Three independent channels, cheapest first.
resolve_tag() {
  local base redirect api body versions
  local -a headers=(-H 'Accept: application/vnd.github+json')

  # 1. the /releases/latest redirect: plain github.com, so mirrors proxy it too
  for base in "" "${mirrors[@]}"; do
    redirect="$(curl -fsS -o /dev/null -w '%{redirect_url}' --connect-timeout 8 --max-time 30 \
      "${base}https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
    tag="$(printf '%s' "$redirect" | sed -n 's#.*/tag/\(v[0-9][^/]*\)$#\1#p')"
    if [ -n "$tag" ]; then return 0; fi
  done

  # 2. the REST API, optionally through a mirror and with a token
  api="https://api.github.com/repos/$REPO/releases/latest"
  [ -n "${GITHUB_TOKEN:-}" ] && headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  for base in "" "${mirrors[@]}"; do
    body="$(curl -fsSL --connect-timeout 8 --max-time 30 "${headers[@]}" "${base}${api}" 2>/dev/null || true)"
    tag="$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$tag" ]; then return 0; fi
  done

  # 3. jsDelivr's package metadata: reachable where the two above are not
  body="$(curl -fsSL --connect-timeout 8 --max-time 30 \
    "https://data.jsdelivr.com/v1/packages/gh/$REPO" 2>/dev/null || true)"
  versions="$(printf '%s' "$body" | grep -o '"version":"[0-9][^"]*"' | sed 's/.*"version":"\([^"]*\)"/\1/' | sort -V | tail -n1)"
  if [ -n "$versions" ]; then tag="v$versions"; return 0; fi

  return 1
}

stage_release() { # needs $tag, $version, $tmp
  local archive="1panel-app-${version}.tar.gz"
  local base="https://github.com/$REPO/releases/download/$tag"
  local expected actual

  log "下载 $archive ..."
  fetch_any "$base/$archive" "$tmp/$archive" || return 1
  fetch_any "$base/SHA256SUMS" "$tmp/SHA256SUMS" || return 1

  expected="$(grep " ${archive}\$" "$tmp/SHA256SUMS" | awk '{print $1}' | head -n1)"
  [ -n "$expected" ] || { warn "SHA256SUMS 中没有 $archive"; return 1; }
  actual="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || { warn "校验失败：期望 $expected，实际 $actual"; return 1; }
  log "校验通过 $actual"

  mkdir -p "$tmp/stage"
  tar -xzf "$tmp/$archive" -C "$tmp/stage" || return 1
  staged="$tmp/stage/$APP_KEY"
  [ -d "$staged" ] || { warn "压缩包里没有 $APP_KEY 目录"; return 1; }
}

stage_cdn() { # needs $tag, $version, $tmp
  local -a files=(
    "data.yml"
    "README.md"
    "README_en.md"
    "logo.png"
    "$version/data.yml"
    "$version/docker-compose.yml"
  )
  local entry kind base url f ok
  for entry in "${CDN_MIRRORS[@]}"; do
    kind="${entry%% *}"
    base="${entry#* }"
    rm -rf "$tmp/cdn"
    mkdir -p "$tmp/cdn"
    ok=1
    for f in "${files[@]}"; do
      mkdir -p "$tmp/cdn/$(dirname "$f")"
      if [ "$kind" = "jsdelivr" ]; then
        url="$base/$REPO@$tag/1panel/apps/$APP_KEY/$f"
      else
        url="$base/$REPO/$tag/1panel/apps/$APP_KEY/$f"
      fi
      if ! curl_get "$url" "$tmp/cdn/$f"; then
        ok=0
        break
      fi
    done
    if [ "$ok" -eq 1 ]; then
      staged="$tmp/cdn"
      log "（经镜像 $base）"
      return 0
    fi
  done
  return 1
}

stage_branch() {
  local url="https://github.com/$REPO/archive/refs/heads/$branch.tar.gz"
  log "下载 $branch 分支快照 ..."
  fetch_any "$url" "$tmp/repo.tar.gz" || return 1
  mkdir -p "$tmp/stage"
  tar -xzf "$tmp/repo.tar.gz" -C "$tmp/stage" --strip-components=1 || return 1
  staged="$tmp/stage/1panel/apps/$APP_KEY"
  [ -d "$staged" ] || { warn "分支 $branch 中没有 1panel/apps/$APP_KEY"; return 1; }
}

stage_dir() {
  local src
  if [ -d "$from_dir/1panel/apps/$APP_KEY" ]; then
    src="$from_dir/1panel/apps/$APP_KEY"
  elif [ -f "$from_dir/data.yml" ]; then
    src="$from_dir"
  else
    warn "$from_dir 既不是仓库根目录，也不是 $APP_KEY 应用目录"
    return 1
  fi
  mkdir -p "$tmp/stage"
  cp -a "$src" "$tmp/stage/$APP_KEY"
  staged="$tmp/stage/$APP_KEY"
}

tmp="$(mktemp -d)"
cleanup() { [ "$keep_downloads" -eq 1 ] || rm -rf "$tmp"; }
trap cleanup EXIT

installed="$(installed_version)"

# ---------------------------------------------------------------------------
# Re-create the store directory of a version that is no longer shipped in
# the package but is still installed. Without it 1Panel drops the matching
# app_details row on the next sync and app_installs.app_detail_id dangles,
# which its API then reports as "unexpected end of JSON input".
ensure_version_dir() { # version
  local ver="$1" entry kind base url f ok
  [ -n "$ver" ] || return 0
  [ -d "$target/$ver" ] && return 0
  log "补回已安装版本 $ver 的目录"
  mkdir -p "$tmp/keep/$ver"
  for entry in "${CDN_MIRRORS[@]}"; do
    kind="${entry%% *}"
    base="${entry#* }"
    ok=1
    for f in data.yml docker-compose.yml; do
      if [ "$kind" = "jsdelivr" ]; then
        url="$base/$REPO@v$ver/1panel/apps/$APP_KEY/$ver/$f"
      else
        url="$base/$REPO/v$ver/1panel/apps/$APP_KEY/$ver/$f"
      fi
      if ! curl_get "$url" "$tmp/keep/$ver/$f"; then
        ok=0
        break
      fi
    done
    if [ "$ok" -eq 1 ]; then
      mkdir -p "$target/$ver"
      cp -a "$tmp/keep/$ver/." "$target/$ver/"
      chmod -R a+rX "$target/$ver"
      rm -rf "$tmp/keep"
      return 0
    fi
    rm -rf "$tmp/keep"
  done
  warn "无法从镜像补回 $ver 的目录，1Panel 可能仍会丢掉该版本的记录"
  return 0
}

prune_versions() {
  local keep_list=() v
  protected_version="${protected_version:-$(deployed_version)}"
  if [ -n "$protected_version" ]; then keep_list+=("$protected_version"); fi
  # Every installed row matters, not only the container that is running: each
  # one points at an app_details row that disappears with its directory.
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case " ${keep_list[*]:-} " in
      *" $v "*) ;;
      *) keep_list+=("$v") ;;
    esac
  done < <(installed_versions)
  for v in "${keep_list[@]:-}"; do
    [ -n "$v" ] || continue
    ensure_version_dir "$v"
  done
  [ "$keep_versions" -gt 0 ] || return 0
  [ -d "$target" ] || return 0
  local dirs=() doomed=() d i
  shopt -s nullglob
  dirs=("$target"/[0-9]*)
  shopt -u nullglob
  [ "${#dirs[@]}" -gt "$keep_versions" ] || return 0
  mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | sort -V)
  local name
  for ((i = 0; i < ${#dirs[@]} - keep_versions; i++)); do
    # Never drop a version that is installed: 1Panel keeps a row per version and
    # a missing directory turns into a dangling app_detail_id, which the panel
    # reports as "unexpected end of JSON input".
    name="${dirs[$i]##*/}"
    case " ${keep_list[*]:-} " in
      *" $name "*)
        log "保留已安装版本 $name（不在最近 $keep_versions 个之内）"
        continue
        ;;
    esac
    doomed+=("${dirs[$i]}")
  done
  [ "${#doomed[@]}" -gt 0 ] || return 0
  log "保留最近 $keep_versions 个版本，清理：${doomed[*]##*/}"
  for d in "${doomed[@]}"; do
    rm -rf -- "$d"
  done
}

# ---------------------------------------------------------------------------
# 1Panel's SQLite state (optional)
#
# 1Panel keeps one app_details row per version and points app_installs at one of
# them. A version directory that disappears from the store loses its row on the
# next sync, which leaves the install pointing at nothing; 1Panel then unmarshals
# an empty string and reports "unexpected end of JSON input". So the directories
# are kept here, and the pointer is repaired here as well: a cron run leaves the
# panel ready to upgrade without any manual step.
# ---------------------------------------------------------------------------
db_has_app_installs() { # file
  local hit
  [ -f "$1" ] || return 1
  hit="$(db_sql "$1" "SELECT name FROM sqlite_master WHERE type='table' AND name='app_installs';" 2>/dev/null || true)"
  [ "$hit" = "app_installs" ]
}

db_sql() { # file sql
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$1" "$2"
  else
    python3 - "$1" "$2" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in row))
con.commit()
con.close()
PY
  fi
}

find_panel_db() {
  local candidate
  [ "$use_db" -eq 1 ] || return 0
  if ! command -v sqlite3 >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    warn "缺少 sqlite3/python3，跳过数据库修复（应用商店包仍会更新）"
    return 0
  fi
  for candidate in \
    "$panel_dir/db/agent.db" \
    "$panel_dir/db/1Panel.db" \
    "$panel_dir/db/core.db" \
    "$panel_dir/data/1Panel.db"; do
    if db_has_app_installs "$candidate"; then
      db="$candidate"
      log "数据库：$db"
      return 0
    fi
  done
}

installed_versions() {
  [ -n "$db" ] || return 0
  db_sql "$db" "SELECT version FROM app_installs WHERE name = '$APP_KEY';" 2>/dev/null || true
}

# Point every install row of this app at the app_details row of its own version.
repair_install_refs() {
  [ -n "$db" ] || return 0
  local rows id app_id ver detail want
  rows="$(db_sql "$db" "SELECT id, app_id, version, app_detail_id FROM app_installs WHERE name = '$APP_KEY';" 2>/dev/null || true)"
  [ -n "$rows" ] || return 0
  while IFS='|' read -r id app_id ver detail; do
    [ -n "$id" ] || continue
    want="$(db_sql "$db" "SELECT id FROM app_details WHERE app_id = $app_id AND version = '$ver' LIMIT 1;" 2>/dev/null || true)"
    case "$want" in ''|*[!0-9]*) continue ;; esac
    [ "$detail" = "$want" ] && continue
    if db_sql "$db" "UPDATE app_installs SET app_detail_id = $want WHERE id = $id;" >/dev/null 2>&1; then
      log "修复 $ver 的版本引用：${detail:-空} -> $want"
    else
      warn "无法修复 $ver 的版本引用（数据库被占用？）"
    fi
  done <<<"$rows"
}

# Reading 1Panel's SQLite file needs no network and no writes, so it also runs
# for --dry-run; repair_install_refs is the part that only writes.
find_panel_db

# Resolve the version to install
# ---------------------------------------------------------------------------
if [ "$source_mode" != branch ] && [ "$source_mode" != dir ]; then
  if [ -z "$tag" ]; then
    log "查询最新版本..."
    resolve_tag || die "无法确定最新版本：github.com、api.github.com 与 jsDelivr 都不可达。可加 --mirror 指定镜像、用 --tag 固定版本，或用 --source dir 从本地目录安装"
  fi
  case "$tag" in
    v[0-9]*) ;;
    *) die "版本号格式应为 vX.Y.Z，收到：$tag" ;;
  esac
  version="${tag#v}"

  if [ -n "$installed" ] && not_older "$installed" "$version"; then
    prune_versions
    repair_install_refs
    log "已是 $installed（最新 $version），无需更新"
    exit 0
  fi

  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] 将安装 $tag 到 $target（当前：${installed:-未安装}；来源：$source_mode）"
    if [ "$restart" -eq 1 ]; then dry_restart_hint; fi
    if [ "$keep_versions" -gt 0 ]; then log "[dry-run] 应用包内保留最近 $keep_versions 个版本目录"; fi
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Stage the package
# ---------------------------------------------------------------------------
case "$source_mode" in
  release)
    stage_release || die "release 下载失败：可加 --mirror 指定镜像，或用 --source cdn / --source dir"
    ;;
  cdn)
    stage_cdn || die "镜像下载失败：可用 --source dir 从本地目录安装"
    ;;
  auto)
    if ! stage_release; then
      warn "GitHub Release 下载失败，改用 jsDelivr CDN 拼装应用包"
      stage_cdn || die "Release 与镜像都失败：请检查网络，或用 --source dir 从本地目录安装"
    fi
    ;;
  branch)
    stage_branch || die "分支 $branch 下载失败：可加 --mirror 指定镜像，或用 --source dir"
    version="$( cd "$staged" && ls -1d [0-9]* 2>/dev/null | sort -V | tail -n1 )" || version=""
    [ -n "$version" ] || die "分支 $branch 的应用包里没有版本目录"
    tag="$version"

    if [ -n "$installed" ] && not_older "$installed" "$version"; then
      prune_versions
      repair_install_refs
      log "已是 $installed（分支最新 $version），无需更新"
      exit 0
    fi
    if [ "$dry_run" -eq 1 ]; then
      log "[dry-run] 将从分支 $branch 安装 $version 到 $target（当前：${installed:-未安装}）"
      if [ "$restart" -eq 1 ]; then dry_restart_hint; fi
    if [ "$keep_versions" -gt 0 ]; then log "[dry-run] 应用包内保留最近 $keep_versions 个版本目录"; fi
      exit 0
    fi
    ;;
  dir)
    stage_dir || die "本地目录 $from_dir 不可用"
    version="$( cd "$staged" && ls -1d [0-9]* 2>/dev/null | sort -V | tail -n1 )" || version=""
    [ -n "$version" ] || die "本地应用包里没有版本目录"
    tag="v$version"

    if [ -n "$installed" ] && not_older "$installed" "$version"; then
      prune_versions
      repair_install_refs
      log "已是 $installed（本地最新 $version），无需更新"
      exit 0
    fi
    if [ "$dry_run" -eq 1 ]; then
      log "[dry-run] 将从 $from_dir 安装 $version 到 $target（当前：${installed:-未安装}）"
      if [ "$restart" -eq 1 ]; then dry_restart_hint; fi
    if [ "$keep_versions" -gt 0 ]; then log "[dry-run] 应用包内保留最近 $keep_versions 个版本目录"; fi
      exit 0
    fi
    ;;
esac

[ -f "$staged/data.yml" ] || die "应用包结构异常：缺少 data.yml"
[ -d "$staged/$version" ] || die "应用包结构异常：缺少 $version/ 目录"
[ -f "$staged/$version/docker-compose.yml" ] || die "应用包结构异常：缺少 $version/docker-compose.yml"

# ---------------------------------------------------------------------------
# Merge the store package. Version directories that are already there are kept,
# so 1Panel keeps offering the previous releases in its version dropdown; only
# the oldest ones beyond --keep-versions are dropped.
# ---------------------------------------------------------------------------
mkdir -p "$store_root"
log "安装应用包 $version -> $target"
if [ -d "$target" ]; then
  # Coping over an existing tree merges it: the shared files (data.yml, logo,
  # READMEs) are refreshed and <version>/ is added next to the older ones.
  cp -a "$staged"/. "$target"/
else
  cp -a "$staged" "$target"
fi
chmod -R a+rX "$target"
prune_versions
repair_install_refs

# ---------------------------------------------------------------------------
# Restart the running app on the new image
# ---------------------------------------------------------------------------
if [ "$restart" -eq 1 ]; then
  compose="$(find_compose)"
  if [ -z "$compose" ]; then
    log "没有已安装的应用实例，仅更新了应用商店包"
  else
    command -v docker >/dev/null 2>&1 || die "应用包已更新，但缺少 docker，无法重启应用"
    image_ref="$IMAGE:$version"
    app_dir="$(dirname "$compose")"
    old_ref="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$compose" | head -n1)"
    if [ "$old_ref" = "$image_ref" ]; then
      log "$app_dir 已指向 $image_ref"
    else
      log "$app_dir: $old_ref -> $image_ref"
      cp -a "$compose" "$compose.bak.$(date +%Y%m%d%H%M%S)"
      sed -i -E "s#^([[:space:]]*image:[[:space:]]*)[^[:space:]]*#\1${image_ref}#" "$compose"
    fi
    log "拉取镜像并重启 $app_dir ..."
    if ! ( cd "$app_dir" && docker compose pull -q && docker compose up -d ); then
      warn "重启 $app_dir 失败，请检查 docker compose 的输出"
      exit 1
    fi
  fi
else
  log "跳过容器重启（--no-restart 或未安装该应用）"
fi

log "完成：应用商店包已更新到 $version${installed:+（原 $installed）}"
