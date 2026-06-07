#!/bin/sh
set -e

REMOTE="${RCLONE_REMOTE:?RCLONE_REMOTE is required}"
BASE="${RCLONE_IMMICH_PATH:?RCLONE_IMMICH_PATH is required}"
DEST="${CACHE_DIR:-/var/cache/immich-edge}"
TRANSFERS="${RCLONE_TRANSFERS:-8}"

STAMP_FILE="$DEST/.last_sync"
FULL_SYNC_STAMP="$DEST/.last_full_sync"
# How often to run a full sync (catches deletions of old files that the
# incremental --max-age window misses). Default: 24h.
FULL_SYNC_INTERVAL="${FULL_SYNC_INTERVAL:-86400}"

# ─── helpers ──────────────────────────────────────────────────────────────────

parse_size_bytes() {
  local val num unit
  val=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  num=$(echo "$val" | sed 's/[^0-9]//g')
  unit=$(echo "$val" | sed 's/[0-9]//g')
  case "$unit" in
    g|gb) echo $((num * 1073741824)) ;;
    m|mb) echo $((num * 1048576)) ;;
    k|kb) echo $((num * 1024)) ;;
    *)    echo "$num" ;;
  esac
}

dir_bytes() { du -sb "$1" 2>/dev/null | cut -f1; }

# Delete oldest files (by mtime) until dir is under limit_bytes.
evict_to_limit() {
  local limit_bytes="$1" dir="$2"
  local used need_free freed=0 tmpfile size path

  used=$(dir_bytes "$dir")
  [ "$used" -le "$limit_bytes" ] && return 0

  need_free=$(( used - limit_bytes ))
  echo "immich-edge sync: cache $(( used / 1048576 ))MB > limit $(( limit_bytes / 1048576 ))MB — freeing $(( need_free / 1048576 ))MB"

  tmpfile=$(mktemp)
  find "$dir" -type f ! -name '.last_sync' ! -name '.last_full_sync' \
    ! -path "*/nginx/*" ! -path "*/nginx_meta/*" \
    | while IFS= read -r f; do stat -c "%Y %s %n" "$f" 2>/dev/null || true; done \
    | sort -n > "$tmpfile"

  while IFS= read -r line; do
    [ "$freed" -ge "$need_free" ] && break
    size=$(echo "$line" | awk '{print $2}')
    path=$(echo "$line" | cut -d' ' -f3-)
    rm -f "$path"
    freed=$(( freed + size ))
    echo "  evicted $(( size / 1024 ))KB: $(basename "$path")"
  done < "$tmpfile"
  rm -f "$tmpfile"

  find "$dir" -mindepth 1 -type d -empty ! -name 'nginx' ! -name 'nginx_meta' -delete 2>/dev/null || true
  echo "immich-edge sync: cache after eviction: $(( $(dir_bytes "$dir") / 1048576 ))MB / $(( limit_bytes / 1048576 ))MB"
}

# Fill remaining space (limit - current) by downloading the newest missing
# files from remote. Runs per sub-path, rechecking budget after each.
backfill_if_space() {
  local limit_bytes="$1"
  local used available

  used=$(dir_bytes "$DEST")
  [ "$used" -ge "$limit_bytes" ] && return 0

  echo "immich-edge sync: $(( (limit_bytes - used) / 1048576 ))MB free — backfilling newest missing files"

  for sub in \
      "${IMMICH_THUMBS_PATH:-thumbs}" \
      "${IMMICH_ENCODED_PATH:-encoded-video}" \
      "${IMMICH_PROFILE_PATH:-profile}"; do

    used=$(dir_bytes "$DEST")
    available=$(( limit_bytes - used ))
    [ "$available" -le 0 ] && break

    echo "  backfilling $sub (budget $(( available / 1048576 ))MB)"
    rclone_base copy \
      --order-by "modtime,descending" \
      --max-transfer "${available}" \
      "${REMOTE}:${BASE}/${sub}" "${DEST}/${sub}" || true
  done

  echo "immich-edge sync: cache after backfill: $(( $(dir_bytes "$DEST") / 1048576 ))MB / $(( limit_bytes / 1048576 ))MB"
}

rclone_base() {
  rclone --config /etc/immich-edge/rclone.conf --transfers "$TRANSFERS" --checksum --progress "$@"
}

# ─── determine sync mode ──────────────────────────────────────────────────────

now=$(date +%s)
do_full_sync=0

if [ ! -f "$STAMP_FILE" ]; then
  echo "immich-edge sync: first run — full sync"
  do_full_sync=1
elif [ ! -f "$FULL_SYNC_STAMP" ]; then
  echo "immich-edge sync: no full-sync record — running full sync"
  do_full_sync=1
else
  last_full=$(cat "$FULL_SYNC_STAMP")
  if [ $(( now - last_full )) -ge "$FULL_SYNC_INTERVAL" ]; then
    echo "immich-edge sync: full sync interval elapsed — running full sync"
    do_full_sync=1
  fi
fi

# Incremental: max_age covers files newer than last sync + 5m buffer for
# thumbnails that Immich finished generating just after the previous run.
max_age=""
if [ "$do_full_sync" = "0" ] && [ -f "$STAMP_FILE" ]; then
  last=$(cat "$STAMP_FILE")
  max_age=$(( now - last + 300 ))
fi

# ─── sync ─────────────────────────────────────────────────────────────────────

sync_path() {
  local sub="$1"
  local src="${REMOTE}:${BASE}/${sub}"
  local dst="${DEST}/${sub}"

  if [ "$do_full_sync" = "1" ]; then
    # Full sync: no --order-by (would require stat-ing every remote file before
    # starting; unnecessary since existing files are skipped by size comparison).
    echo "immich-edge sync: full sync $sub"
    rclone_base sync --progress "$src" "$dst"
  else
    # Incremental: --max-age limits transfers to files newer than last sync.
    # rclone sync still deletes local files removed from remote (deletions work
    # regardless of --max-age). Old evicted files (mtime before last sync) are
    # not re-downloaded.
    echo "immich-edge sync: incremental sync $sub (max-age ${max_age}s)"
    rclone_base sync --max-age "${max_age}s" "$src" "$dst"
  fi
}

if [ -n "${CACHE_MAX_SIZE:-}" ]; then
  limit=$(parse_size_bytes "$CACHE_MAX_SIZE")
  # Pre-sync: evict oldest first to make room for incoming new files
  evict_to_limit "$limit" "$DEST"
fi

sync_path "${IMMICH_THUMBS_PATH:-thumbs}"
sync_path "${IMMICH_ENCODED_PATH:-encoded-video}"
sync_path "${IMMICH_PROFILE_PATH:-profile}"

if [ -n "${CACHE_MAX_SIZE:-}" ]; then
  # Post-sync: new files may have pushed us over limit
  evict_to_limit "$limit" "$DEST"
  # Backfill: if there is headroom, fill it with the newest missing files
  backfill_if_space "$limit"
fi

# ─── update stamps ────────────────────────────────────────────────────────────

echo "$now" > "$STAMP_FILE"
[ "$do_full_sync" = "1" ] && echo "$now" > "$FULL_SYNC_STAMP"

echo "immich-edge sync: seed complete"
