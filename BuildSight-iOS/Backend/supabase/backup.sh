#!/bin/zsh
# Exports the project's data to a timestamped, compressed SQL file, and keeps the newest 14.
# The free Supabase plan has no backups, so run this regularly (see docs/BACKUPS.md).
#
#   BS_DB_URL='postgresql://postgres:PASSWORD@db.PROJECTREF.supabase.co:5432/postgres' \
#     ./Backend/supabase/backup.sh ~/BuildSightBackups
#
# BS_DB_URL is your database connection string (Supabase > Project Settings > Database > URI). It
# contains your database password: pass it in the environment, never write it in a file in the repo.
# Set BS_INCLUDE_AUTH=1 to also include user accounts (email and hashed passwords): keep that file private.
set -e
: "${BS_DB_URL:?Set BS_DB_URL first (see the comment at the top of this file)}"
command -v pg_dump >/dev/null || { echo "Install pg_dump first: brew install libpq && brew link --force libpq"; exit 1; }
OUT="${1:-$HOME/BuildSightBackups}"
mkdir -p "$OUT"
FILE="$OUT/buildsight-$(date +%Y%m%d-%H%M%S).sql.gz"
SCHEMAS=(--schema=public)
[ "${BS_INCLUDE_AUTH:-0}" = "1" ] && SCHEMAS+=(--schema=auth)
pg_dump "$BS_DB_URL" --no-owner --no-privileges "${SCHEMAS[@]}" | gzip > "$FILE"
chmod 600 "$FILE"
echo "Saved $FILE ($(du -h "$FILE" | cut -f1))"
# Keep the newest 14 backups.
ls -1t "$OUT"/buildsight-*.sql.gz 2>/dev/null | tail -n +15 | while read -r old; do rm -f "$old"; done
