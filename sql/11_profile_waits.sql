-- What the backends were doing while those statements ran, sampled every 10 ms by pg_wait_sampling.
-- event_type NULL means "on CPU" (pg_wait_sampling.sample_cpu = on). One sample ~ profile_period ms.
-- This is the closest thing PostgreSQL has to Oracle's ASH, and it is a profile in Millsap's sense:
-- a decomposition of time by what it was spent on.
with w as (
  select queryid,
         coalesce(event_type, 'CPU')          as event_type,
         coalesce(event, 'running')           as event,
         sum(count)                           as samples
  from pg_wait_sampling_profile
  where queryid <> 0
  group by 1, 2, 3
), top as (
  select queryid, left(regexp_replace(query, '\s+', ' ', 'g'), 40) as statement, total_exec_time
  from pg_stat_statements
  where dbid = (select oid from pg_database where datname = current_database())
  order by total_exec_time desc
  limit :limit
)
select t.statement,
       w.event_type || ':' || w.event                                     as spent_on,
       w.samples,
       round(100.0 * w.samples / sum(w.samples) over (partition by t.queryid), 1) as pct_of_stmt
from top t
join w using (queryid)
where w.samples >= 3
order by t.total_exec_time desc, w.samples desc;
