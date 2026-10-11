#!/bin/sh
# Usage: wait-for-postgres.sh DB...
# Blocks until every DB accepts a login. Connection settings come from the
# libpq env (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGCONNECT_TIMEOUT).
# Sonarr/Prowlarr hang ("waiting for user intervention") instead of exiting
# when their database is missing, so they must not start before it exists.
set -eu

for db in "$@"; do
  i=0
  until err=$(psql -d "$db" -Atqc 'select 1' 2>&1 >/dev/null); do
    i=$((i + 1))
    # libpq errors never contain the password.
    echo "waiting for database $db as $PGUSER@$PGHOST (try $i): $(printf '%s' "$err" | head -n 1)"
    sleep 3
  done
  echo "database $db is ready"
done
