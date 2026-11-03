-- pg_stat_kcache: what the operating system saw for the same statements.
-- fs_reads/fs_writes are real file system I/O (not shared_buffers hits), user/sys are CPU seconds.
-- If "user_s + sys_s" is close to total time in 10_profile_statements, the statement is CPU bound.
select left(regexp_replace(s.query, '\s+', ' ', 'g'), 50)                as statement,
       round((s.total_exec_time / 1000)::numeric, 2)                       as total_s,
       round(k.exec_user_time::numeric, 2)                                  as user_s,
       round(k.exec_system_time::numeric, 2)                                as sys_s,
       pg_size_pretty(k.exec_reads)                                         as fs_reads,
       pg_size_pretty(k.exec_writes)                                        as fs_writes
from pg_stat_kcache() k
join pg_stat_statements s using (queryid, userid, dbid)
where k.top and s.dbid = (select oid from pg_database where datname = current_database())
order by s.total_exec_time desc
limit :limit;
