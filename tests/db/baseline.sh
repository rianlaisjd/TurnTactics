#!/bin/sh
# Builds database "tt_base": the shim plus every pre-release migration (001-018),
# then runs the three pre-release check files against it. Needs tests/db/pg.sh start.
export PGHOST=127.0.0.1 PGPORT=${TT_PG_PORT:-54329} PGUSER=postgres
cd "$(dirname "$0")/../.." || exit 1
psql -q -d postgres -c "drop database if exists tt_base" -c "create database tt_base" || exit 1
psql -q -v ON_ERROR_STOP=1 -d tt_base -f tests/db/shim.sql || exit 1
for f in 001_online 003_test_mode 005_player_icons 007_pacific_clock 010_rule_proposals 012_shared_victory 014_room_recovery 016_slideshow_rules 018_chat; do
  psql -q -v ON_ERROR_STOP=1 -d tt_base -f "supabase/$f.sql" >/dev/null 2>&1 || { echo "BASELINE FAIL $f"; exit 1; }
done
for f in 015_recovery_checks 017_slideshow_checks 019_chat_checks; do
  if psql -q -v ON_ERROR_STOP=1 -d tt_base -f "supabase/$f.sql" 2>&1 | grep -q "passed"; then echo "PASS baseline $f"
  elif [ "$f" = 015_recovery_checks ]; then echo "KNOWN-FAIL baseline $f (pre-existing: it starts a 3x3 board, which 016 forbids)"
  else echo "FAIL baseline $f"; fi
done
