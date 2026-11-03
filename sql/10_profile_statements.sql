-- The invoice: where did the database spend its time, per statement?
-- Sorted by total time, because total time (calls x mean) is what the users paid.
-- Millsap: a response time is too long because a call count is too high or a latency is too high.
--          "calls" and "mean_ms" are exactly those two columns.
select
  left(regexp_replace(query, '\s+', ' ', 'g'), 60)                         as statement,
  calls,
  round(total_exec_time::numeric, 1)                                       as total_ms,
  round((100 * total_exec_time / sum(total_exec_time) over ())::numeric, 1)           as pct,
  round(mean_exec_time::numeric, 3)                                        as mean_ms,
  round(stddev_exec_time::numeric, 3)                                      as stddev_ms,
  round(max_exec_time::numeric, 1)                                         as max_ms,
  round(rows::numeric / nullif(calls, 0), 1)                               as rows_per_call,
  round((shared_blks_hit + shared_blks_read)::numeric / nullif(calls, 0))  as blks_per_call,
  round(shared_blk_read_time::numeric, 1)                                  as io_read_ms,
  temp_blks_written                                                         as temp_blks
from pg_stat_statements
where dbid = (select oid from pg_database where datname = current_database())
  and query not ilike '%pg_stat_statements%'
  and query not ilike '%pg_wait_sampling%'
order by total_exec_time desc
limit :limit;
