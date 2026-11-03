#!/usr/bin/env bash
# Undo: demo tables and indexes, statistics, the out/ directory.
#   DROP_DB=yes     also drops the database $PG_DB
#   STOP_STACK=yes  also runs docker compose down -v
source "$(dirname "$0")/00_lib.sh"
say "Demo objects"
run "set client_min_messages = warning;
     drop table if exists items, item_queries, item_truth cascade;
     drop function if exists vec_bench(int, int, boolean);
     drop index if exists pgbench_accounts_bid_abalance"
pgbench -i -I d >/dev/null 2>&1 && ok "pgbench tables dropped"
reset_stats && ok "statistics reset"
rm -rf "$OUT" && ok "out/ removed"
if [[ "${DROP_DB:-no}" == "yes" ]]; then
  psql -X -d postgres -qc "drop database if exists $PG_DB" && ok "database $PG_DB dropped"
fi
if [[ "${STOP_STACK:-no}" == "yes" ]]; then
  docker compose -f "$ROOT/docker/compose.yml" down -v && ok "docker stack removed"
fi
