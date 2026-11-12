#!/bin/sh
# Runs every automated check that needs no external service.
#   tests/run-all.sh
# Needs: PostgreSQL 16 server binaries (no Docker), Node 22+, Chrome/Chromium. Installs nothing.
cd "$(dirname "$0")/.." || exit 1
fail=0
tests/db/pg.sh start >/dev/null 2>&1
echo "== pre-release baseline (migrations 001-018 and their original checks)"; tests/db/baseline.sh || fail=1
echo "== release migrations 020-023 and SQL checks";                         tests/db/release.sh || fail=1
echo "== real concurrent sessions";                                          tests/db/concurrency.sh || fail=1
echo "== unit tests"; if node --test tests/unit/logic.test.mjs >/tmp/tt-unit.log 2>&1; then grep -E "^ℹ (pass|fail)" /tmp/tt-unit.log; else cat /tmp/tt-unit.log; fail=1; fi
echo "== browser end-to-end (real UI + real SQL; Auth and push delivery stubbed)"; tests/db/release.sh >/dev/null 2>&1; node tests/e2e/run.mjs || fail=1
tests/db/pg.sh stop >/dev/null 2>&1
[ $fail = 0 ] && echo "ALL LOCAL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
