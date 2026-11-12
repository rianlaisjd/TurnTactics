#!/bin/sh
# Rebuilds database "tt" = tt_base + release migrations, then runs the release checks.
# Usage: tests/db/pg.sh start && tests/db/baseline.sh && tests/db/release.sh
export PGHOST=127.0.0.1 PGPORT=${TT_PG_PORT:-54329} PGUSER=postgres
cd "$(dirname "$0")/../.." || exit 1
psql -q -d postgres -c "drop database if exists tt" -c "create database tt template tt_base" 2>&1 | grep -v NOTICE
for f in 020_accounts_invites 021_notifications 022_rules_engine 023_chat_replies_retention; do
  psql -q -v ON_ERROR_STOP=1 -d tt -f "supabase/$f.sql" 2>&1 | grep -v 'skipping' | grep . && { echo "MIGRATION FAIL $f"; exit 1; }
done
# Re-running every migration must be harmless.
for f in 020_accounts_invites 021_notifications 022_rules_engine 023_chat_replies_retention; do
  psql -q -v ON_ERROR_STOP=1 -d tt -f "supabase/$f.sql" 2>&1 | grep -v 'skipping' | grep . && { echo "RERUN FAIL $f"; exit 1; }
done
echo "PASS migrations 020-023 apply twice cleanly"
status=0
for f in 025_release_checks_rules 026_release_checks_chat_push; do
  out=$(psql -q -v ON_ERROR_STOP=1 -d tt -f "supabase/$f.sql" 2>&1 | grep -v '^CONTEXT\|^PL/pgSQL\|^SQL statement')
  if echo "$out" | grep -q "checks passed"; then echo "PASS $f: $(echo "$out" | grep -o '([0-9]* assertions)')"; else echo "FAIL $f"; echo "$out" | head -6; status=1; fi
done
exit $status
