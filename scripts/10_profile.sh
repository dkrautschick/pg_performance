#!/usr/bin/env bash
# Method R in PostgreSQL: run a mixed workload, then read the invoice.
#   1. the system-wide view (what a dashboard shows)
#   2. the per-statement profile from pg_stat_statements (calls x latency)
#   3. per-statement wait profiles from pg_wait_sampling (where each statement's time went)
#   4. what the kernel saw per statement (pg_stat_kcache)
source "$(dirname "$0")/00_lib.sh"
need pgbench
LIMIT="${LIMIT:-6}"

say "Reset all statistics"
reset_stats
ok "pg_stat_statements, pg_wait_sampling, pg_stat_kcache reset"

say "Mixed workload for ${RUN_SECONDS}s: 4 clients TPC-B, 2 clients point lookups, 1 client reporting with a small work_mem"
pgbench -n -T "$RUN_SECONDS" -c 4 -j 1 -s "$PGBENCH_SCALE" >"$OUT/10_tpcb.log" 2>&1 &
p1=$!
pgbench -n -T "$RUN_SECONDS" -c 2 -j 1 -s "$PGBENCH_SCALE" -f "$ROOT/sql/workload_lookup.pgbench" >"$OUT/10_lookup.log" 2>&1 &
p2=$!
PGOPTIONS='-c work_mem=4MB' pgbench -n -T "$RUN_SECONDS" -c 1 -j 1 -s "$PGBENCH_SCALE" -f "$ROOT/sql/workload_report.pgbench" >"$OUT/10_report.log" 2>&1 &
p3=$!
wait $p1 $p2 $p3
for f in tpcb lookup report; do
  printf '  %-7s %s, %s\n' "$f" "$(grep -m1 '^tps' "$OUT/10_$f.log" | cut -d' ' -f1-3)" "$(grep -m1 'latency average' "$OUT/10_$f.log")"
done

if preloaded pg_wait_sampling; then
  say "1. The dashboard view: all waits of all backends, summed (the 'system bottleneck')"
  run "select coalesce(event_type,'CPU') || ':' || coalesce(event,'running') as spent_on, sum(count) as samples,
              round(100.0*sum(count)/sum(sum(count)) over (),1) as pct
       from pg_wait_sampling_profile
       where queryid <> 0          -- background processes (checkpointer, walwriter, ...) report queryid 0
       group by 1 order by 2 desc limit 8"
fi

say "2. The invoice: time per statement (pg_stat_statements)"
runf 10_profile_statements.sql -v limit="$LIMIT"

if preloaded pg_wait_sampling; then
  say "3. Per statement: where the time went (pg_wait_sampling, 10 ms samples)"
  runf 11_profile_waits.sql -v limit=4
fi

if preloaded pg_stat_kcache; then
  say "4. What the kernel saw (pg_stat_kcache)"
  runf 12_profile_kcache.sql -v limit=4
fi

cat <<'EOF'

  Read it like Millsap reads an invoice: the top line is where the money went.
  The dashboard view (1) blames whatever most backends wait on. The report's own profile (3)
  tells you what *the report* waited on. Those are different questions with different answers.
EOF
