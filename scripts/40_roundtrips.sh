#!/usr/bin/env bash
# Client side: the same 50 rows, fetched as 50 single-row queries (the ORM's N+1) or as one query.
# Measured directly on localhost and through tools/latency_proxy.py, which adds PROXY_DELAY_MS each way.
# The server does the same work in both cases; the client pays per round trip.
# This is Millsap's payroll job: the bottleneck was "SQL*Net message from client", not the database.
source "$(dirname "$0")/00_lib.sh"
need pgbench; need python3
ROWS="${ROWS:-50}"
SECS="${SECS:-8}"

# The N+1 script: ROWS statements in one transaction, generated so you can change ROWS
n1="$OUT/40_n_plus_1.pgbench"
{
  echo "\\set aid random(1, 100000 * :scale - $ROWS)"
  echo "BEGIN;"
  for i in $(seq 0 $((ROWS - 1))); do echo "SELECT abalance FROM pgbench_accounts WHERE aid = :aid + $i;"; done
  echo "END;"
} >"$n1"
set_based="$ROOT/sql/workload_set_based.pgbench"

measure() { # label host port script
  reset_stats
  pgbench -n -T "$SECS" -c 1 -j 1 -s "$PGBENCH_SCALE" -h "$2" -p "$3" -f "$4" >"$OUT/40_$1.out" 2>&1 \
    || die "pgbench failed, see $OUT/40_$1.out"
  local client tx server calls
  client=$(awk '/latency average/ { print $4 }' "$OUT/40_$1.out")
  tx=$(awk '/actually processed/ { print $NF }' "$OUT/40_$1.out")
  read -r server calls < <(q "select round((sum(total_exec_time) / $tx)::numeric, 3), sum(calls)
                              from pg_stat_statements
                              where dbid = (select oid from pg_database where datname = current_database())
                                and query not ilike '%pg_stat_statements%'" | tr '|' ' ')
  printf '  %-28s %12s %14s %10s\n' "$1" "$client" "$server" "$calls"
}

say "Start the latency proxy: +${PROXY_DELAY_MS} ms each way on port $PROXY_PORT"
python3 "$ROOT/tools/latency_proxy.py" --listen "$PROXY_PORT" --target "$PGHOST:$PGPORT" --delay-ms "$PROXY_DELAY_MS" >"$OUT/40_proxy.log" 2>&1 &
proxy=$!
trap 'kill $proxy 2>/dev/null || true' EXIT
sleep 1
psql -X -h 127.0.0.1 -p "$PROXY_PORT" -Atqc "select 1" >/dev/null || die "proxy does not answer"
ok "proxy up (pid $proxy)"

say "$ROWS rows per transaction, one client, ${SECS}s per variant"
printf '\n  %-28s %12s %14s %10s\n' variant "client_ms/tx" "server_ms/tx" statements
printf '  %-28s %12s %14s %10s\n' ---------------------------- ------------ -------------- ----------
measure "N+1, localhost"          "$PGHOST"   "$PGPORT"      "$n1"
measure "one query, localhost"    "$PGHOST"   "$PGPORT"      "$set_based"
measure "N+1, via proxy"          127.0.0.1   "$PROXY_PORT"  "$n1"
measure "one query, via proxy"    127.0.0.1   "$PROXY_PORT"  "$set_based"

rtt=$(awk -v d="$PROXY_DELAY_MS" 'BEGIN { printf "%.1f", 2 * d }')
cat <<EOF

  server_ms/tx is the database's own view (pg_stat_statements); client_ms/tx is what the user waits for.
  Through the proxy every round trip costs at least ${rtt} ms more. N+1 makes $((ROWS + 2)) round trips per
  transaction, the set-based version 1. Same rows, same indexes, same server time per row:
  the difference is entirely call count (Millsap: d = c x f(c); the fastest call is no call).
  No server parameter, no index and no bigger instance fixes this. Changing the code does.
EOF
