-- The minimum toolbox. Each needs its library in shared_preload_libraries (except vector).
create extension if not exists pg_stat_statements;
do $$ begin
  if exists (select from pg_available_extensions where name = 'pg_wait_sampling')
     and current_setting('shared_preload_libraries') like '%pg_wait_sampling%' then
    create extension if not exists pg_wait_sampling;
  end if;
  if exists (select from pg_available_extensions where name = 'pg_stat_kcache')
     and current_setting('shared_preload_libraries') like '%pg_stat_kcache%' then
    create extension if not exists pg_stat_kcache;
  end if;
  if exists (select from pg_available_extensions where name = 'vector') then
    create extension if not exists vector;
  end if;
end $$;
