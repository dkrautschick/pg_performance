#!/usr/bin/env bash
# Database, extensions, a pgbench schema, and a check of everything the other scripts rely on.
source "$(dirname "$0")/00_lib.sh"
need psql; need pgbench

say "Connection and version"
psql -X -d postgres -Atqc "select 1" >/dev/null || die "cannot connect to $PGHOST:$PGPORT as $PGUSER"
if [[ "$(psql -X -d postgres -Atqc "select count(*) from pg_database where datname = '$PG_DB'")" == "0" ]]; then
  psql -X -d postgres -qc "create database $PG_DB" && ok "created database $PG_DB"
fi
ok "$(q "select version()")"
[[ "$(q "show server_version_num")" -ge 170000 ]] || warn "scripts are tested on PostgreSQL 18; 17 works mostly, older versions lack some columns"

say "Preloaded libraries (need a restart to change)"
for lib in pg_stat_statements pg_wait_sampling pg_stat_kcache auto_explain; do
  if preloaded "$lib"; then ok "$lib"; else warn "$lib not in shared_preload_libraries"; fi
done
preloaded pg_stat_statements || die "pg_stat_statements is the minimum; add it to shared_preload_libraries and restart"

say "Extensions"
runf 01_extensions.sql
run "select extname, extversion from pg_extension order by 1"

say "Settings that decide whether timing data exists at all"
run "select name, current_setting(name) as value from pg_settings where name in ('track_io_timing','track_wal_io_timing','compute_query_id','pg_stat_statements.track','io_method','shared_buffers','work_mem','max_connections') order by 1"
[[ "$(q "show track_io_timing")" == "on" ]] || warn "track_io_timing is off: no I/O time in pg_stat_statements and EXPLAIN. Measure the cost with pg_test_timing, then switch it on."

say "pgbench schema, scale $PGBENCH_SCALE"
pgbench -i -q -s "$PGBENCH_SCALE" --foreign-keys >/dev/null 2>&1
run "vacuum analyze"
ok "pgbench_accounts: $(q "select count(*) from pgbench_accounts") rows, $(q "select pg_size_pretty(pg_total_relation_size('pgbench_accounts'))")"

say "Timer overhead on this box (what instrumentation costs, in nanoseconds per call)"
if command -v pg_test_timing >/dev/null 2>&1; then
  pg_test_timing -d 1 2>/dev/null | sed -n '1,4p'
else
  warn "pg_test_timing not in PATH (it is in the server bin directory)"
fi
