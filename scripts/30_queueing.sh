#!/usr/bin/env bash
# Load and queueing delay: the same tiny query, more and more concurrent clients.
# Throughput stops growing at the capacity of the box; from then on every extra client only adds waiting.
# Response time R = service time S + queueing delay Q. S stays constant, Q is what grows.
# Little's law check (closed system, no think time): mean latency ~ clients / throughput.
source "$(dirname "$0")/00_lib.sh"
need pgbench
STEPS="${STEPS:-1 2 4 8 16 32 64}"
SECS="${SECS:-8}"
CPUS=$(nproc 2>/dev/null || echo "?")

say "Select-only (one row by primary key), ${SECS}s per step, clients: $STEPS (this box: $CPUS CPU)"
printf '\n  %7s %10s %10s %10s %10s %12s\n' clients tps mean_ms p99_ms max_ms "clients/tps"
printf '  %7s %10s %10s %10s %10s %12s\n' ------- ---------- ---------- ---------- ---------- ------------
: >"$OUT/30_queueing.csv"
for c in $STEPS; do
  rm -f "$OUT"/30_log.*
  pgbench -n -S -T "$SECS" -c "$c" -j 1 -s "$PGBENCH_SCALE" -l --log-prefix="$OUT/30_log" >"$OUT/30_run_$c.out" 2>&1
  tps=$(awk '/^tps/ { printf "%.0f", $3 }' "$OUT/30_run_$c.out")
  read -r _ mean _ _ p99 _ max < <(latency_stats "$OUT"/30_log.*)
  little=$(awk -v c="$c" -v t="$tps" 'BEGIN { printf "%.3f", 1000 * c / t }')
  printf '  %7s %10s %10s %10s %10s %12s\n' "$c" "$tps" "$mean" "$p99" "$max" "$little"
  echo "$c,$tps,$mean,$p99,$max" >>"$OUT/30_queueing.csv"
done
rm -f "$OUT"/30_log.*

cat <<'EOF'

  Throughput (tps) flattens once the CPU is saturated; mean and p99 latency keep climbing with every client.
  That climb is queueing delay, not slower queries: pg_stat_statements would show the same mean_exec_time
  for the SELECT at 1 client and at 64. Millsap's M/M/m knee table puts the comfortable utilization of
  1 CPU at ~50%, of 8 at ~74%, of 32 at ~86%. A connection pooler in front of PostgreSQL is how you keep
  the number of *active* backends near the knee, however many clients the application opens.
EOF
