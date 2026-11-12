#!/bin/sh
# Starts/stops a throwaway local PostgreSQL 16 for the SQL tests.
# Usage: tests/db/pg.sh start|stop   (run as root or as the postgres OS user)
BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
DATA=${TT_PG_DATA:-/tmp/tt-pg}
PORT=${TT_PG_PORT:-54329}
OPTS="-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp -c max_connections=60"
if [ "$(id -u)" = 0 ]; then
  mkdir -p "$DATA" && chown postgres "$DATA"
  exec su postgres -s /bin/sh -c "PG_BIN=$BIN TT_PG_DATA=$DATA TT_PG_PORT=$PORT $0 $1"
fi
case "$1" in
  stop) "$BIN/pg_ctl" -D "$DATA" -m fast stop ;;
  *) [ -f "$DATA/PG_VERSION" ] || "$BIN/initdb" -D "$DATA" -A trust -U postgres >/dev/null
     "$BIN/pg_ctl" -D "$DATA" -o "$OPTS" -l "$DATA/log" -w start ;;
esac
