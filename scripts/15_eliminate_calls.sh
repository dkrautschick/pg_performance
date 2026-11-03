#!/usr/bin/env bash
# Method R, step "optimize the experience": the report from 10_profile.sh reads ~16,000 blocks to return 10 rows.
# Axiom 3: the fastest call is no call. Here the calls are buffer visits, and an index removes most of them.
# Prediction first (Amdahl): the report is ~70% of the database time in 10_profile.sh, so that is the ceiling of what this fix can save.
source "$(dirname "$0")/00_lib.sh"
need pgbench
SECS="${SECS:-10}"

report() {
  reset_stats
  PGOPTIONS='-c work_mem=4MB' pgbench -n -T "$SECS" -c 1 -j 1 -s "$PGBENCH_SCALE" \
    -f "$ROOT/sql/workload_report.pgbench" >"$OUT/15_$1.log" 2>&1
  run "select '$1' as variant, calls,
              round(mean_exec_time::numeric, 3) as mean_ms,
              round(((shared_blks_hit + shared_blks_read)::numeric / calls)) as blks_per_call,
              round(rows::numeric / calls, 1) as rows_per_call
       from pg_stat_statements where query like 'SELECT aid, abalance FROM pgbench_accounts WHERE bid%'"
}

say "Plan before"
run "explain (analyze, buffers, costs off, timing off, summary off)
     select aid, abalance from pgbench_accounts where bid = 1 order by abalance desc, filler limit 10" | sed -n '1,12p'

say "Before: ${SECS}s of the report, one client"
run "drop index if exists pgbench_accounts_bid_abalance"
report before

say "The fix: one index that matches the filter and the sort"
run "create index pgbench_accounts_bid_abalance on pgbench_accounts (bid, abalance desc)"
run "analyze pgbench_accounts"

say "Plan after"
run "explain (analyze, buffers, costs off, timing off, summary off)
     select aid, abalance from pgbench_accounts where bid = 1 order by abalance desc, filler limit 10" | sed -n '1,12p'

say "After: ${SECS}s of the report, one client"
report after

say "The price of the fix (the other side of the invoice)"
run "select pg_size_pretty(pg_relation_size('pgbench_accounts_bid_abalance')) as index_size"
cat <<'EOF'
  Every index is a promise to slow down the next UPDATE of abalance (no more HOT updates on that column).
  Match the scope of the fix to the scope of the problem: if the report runs twice a day, a read replica
  or an analytical sidekick may be the cheaper remedy.
EOF
if [[ "${KEEP_INDEX:-no}" != "yes" ]]; then
  run "drop index pgbench_accounts_bid_abalance"
  ok "index dropped again so the other demos start from the same state (KEEP_INDEX=yes keeps it)"
fi
