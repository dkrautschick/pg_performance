#!/usr/bin/env bash
# "Users feel the variance, not the mean." (Millsap)
# pgbench logs every transaction (-l); we compare the mean with the percentiles and with what
# pg_stat_statements can tell you (mean and stddev per statement, no percentiles).
source "$(dirname "$0")/00_lib.sh"
need pgbench
CLIENTS="${CLIENTS:-4}"

say "TPC-B for ${RUN_SECONDS}s, $CLIENTS clients, every transaction logged; a CHECKPOINT halfway through"
rm -f "$OUT"/20_pgbench_log.*
reset_stats
( sleep $((RUN_SECONDS / 2)); q "checkpoint" >/dev/null ) &
pgbench -n -T "$RUN_SECONDS" -c "$CLIENTS" -j 1 -s "$PGBENCH_SCALE" -l --log-prefix="$OUT/20_pgbench_log" >"$OUT/20_pgbench.out" 2>&1
wait
grep -E '^(tps|latency average)' "$OUT/20_pgbench.out" | sed 's/^/  /'

say "One transaction = one 'experience'. Same data, two ways to summarise it"
read -r n mean p50 p90 p99 p999 max < <(latency_stats "$OUT"/20_pgbench_log.*)
printf '  %-28s %10s\n' "transactions" "$n"
printf '  %-28s %10s ms\n' "mean (what averages show)" "$mean" "median (p50)" "$p50" "p90" "$p90" "p99" "$p99" "p99.9" "$p999" "max" "$max"

say "Histogram of transaction latency"
awk '{ ms = $3 / 1000
       if (ms < 1) k = "1|<1 ms"; else if (ms < 2) k = "2|1-2 ms"; else if (ms < 5) k = "3|2-5 ms"
       else if (ms < 10) k = "4|5-10 ms"; else if (ms < 50) k = "5|10-50 ms"; else if (ms < 100) k = "6|50-100 ms"
       else k = "7|>=100 ms"
       b[k]++; n++ }
     END { for (k in b) printf "%s|%d|%.2f\n", k, b[k], 100 * b[k] / n }' "$OUT"/20_pgbench_log.* |
  sort -t'|' -k1,1n | while IFS='|' read -r _ label count pct; do
    bar=$(printf '%*s' "$(awk -v p="$pct" 'BEGIN { print int(p / 2) }')" '' | tr ' ' '#')
    printf '  %-10s %8s  %6s%%  %s\n' "$label" "$count" "$pct" "$bar"
  done

say "What pg_stat_statements knows about the same run: mean, stddev, max. No percentiles."
run "select left(query, 45) as statement, calls, round(mean_exec_time::numeric,3) as mean_ms,
            round(stddev_exec_time::numeric,3) as stddev_ms, round(max_exec_time::numeric,1) as max_ms
     from pg_stat_statements where query ilike 'update%' or query ilike 'insert%' order by total_exec_time desc"

say "Does the server-side profile add up to what the client experienced?"
server_ms=$(q "select round((sum(total_exec_time) / $n)::numeric, 3) from pg_stat_statements
               where dbid = (select oid from pg_database where datname = current_database())
                 and query not ilike '%pg_stat_statements%'")
gap=$(awk -v c="$mean" -v s="$server_ms" 'BEGIN { printf "%.3f", c - s }')
pct=$(awk -v c="$mean" -v s="$server_ms" 'BEGIN { printf "%.0f", 100 * (c - s) / c }')
printf '  %-52s %8s ms\n' "client: mean transaction latency" "$mean" \
  "server: statement execution time per transaction" "$server_ms" \
  "unaccounted for (round trips, commit, CPU queue, ...)" "$gap"
echo "  -> ${pct}% of the experience is invisible to pg_stat_statements."
echo "     A profile must add up to the response time you are fixing; this one does not, so measure at the client too."

cat <<EOF

  A requirement worth writing down looks like Millsap's two-tier specification:
    "TPC-B transaction under ${p90} ms in 90% of executions and under ${p99} ms in 99%."
  The mean (${mean} ms) cannot express it, and neither can a dashboard of CPU utilization.
EOF
