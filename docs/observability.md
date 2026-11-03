# The observability baseline, setting by setting

`docker/perf.conf` is what the scripts expect. This page says what each line buys and what it costs, so you can decide what goes to
production. The rule from the blog post: collect the profile *before* the incident, because a profile you start during the incident is a
profile of the wrong hour.

## Needs a restart

| Setting | Buys | Costs |
|---|---|---|
| `shared_preload_libraries = 'pg_stat_statements'` | the per-statement invoice: calls, time, rows, buffers, WAL, temp | shared memory for `pg_stat_statements.max` entries; a few percent CPU on very short statements |
| `... pg_wait_sampling` | per-process and per-`queryid` wait profiles, sampled every 10 ms (`profile_period`) | a background worker; small shared memory; not available on every managed service |
| `... pg_stat_kcache` | real CPU (user/system) and file system I/O per statement | a `getrusage()` call per statement; requires `pg_stat_statements` |
| `... auto_explain` | the plan that was actually used for slow statements, in the log | with `log_analyze = on` every statement is instrumented; keep `log_timing = off` unless you need per-node times |

## Reloadable

| Setting | Buys | Costs |
|---|---|---|
| `compute_query_id = on` | the same `queryid` in `pg_stat_statements`, `pg_stat_activity`, `pg_wait_sampling` and the log (`%Q`) | negligible (it is on automatically when `pg_stat_statements` is loaded) |
| `track_io_timing = on` | I/O time in `pg_stat_statements`, `pg_stat_io`, `EXPLAIN (ANALYZE, BUFFERS)` | two clock reads per I/O; run `pg_test_timing` first (tens of ns per call on modern hardware is fine) |
| `track_wal_io_timing = on` | WAL write and sync time in `pg_stat_io` | as above, per WAL I/O |
| `track_functions = all` | call counts and times per PL function | small, per function call |
| `log_min_duration_statement = '1s'` | every slow statement in the log, for pgBadger | log volume; set it to what "slow" means for your requirements |
| `log_lock_waits = on` | a log line when a lock wait exceeds `deadlock_timeout` | none worth mentioning |
| `log_temp_files = 0` | every spill to disk, with its size | log volume on systems that spill a lot (which is a finding) |
| `log_checkpoints`, `log_autovacuum_min_duration` | when the background work happened and how long it took | none worth mentioning |
| `log_line_prefix` with `%a %h %Q` | application, client and query id on every line: joins the log to the profile | none |

## What none of these give you

- **Percentiles.** `pg_stat_statements` has mean, stddev, min and max. Percentiles need per-experience data: client-side histograms,
  application metrics, `pgbench -l`, or sampled logging (`log_min_duration_sample` with `log_statement_sample_rate`, `log_transaction_sample_rate`).
- **History.** All of the above is cumulative since the last reset or a ring buffer. Snapshots into a repository (pg_profile, pgwatch,
  your platform's metrics) turn them into time windows you can compare.
- **Time outside the server.** Round trips, pooler queues, the ORM, the network. `scripts/20_percentiles.sh` and `scripts/40_roundtrips.sh`
  show how large that part can be.
