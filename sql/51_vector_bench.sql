-- vec_bench(k, filter_category, exact): run every query in item_queries through the current settings
-- (hnsw.ef_search, hnsw.iterative_scan, ...) and return latency percentiles and recall@k
-- against item_truth (unfiltered) or against an exact filtered answer computed on the fly.
-- Timing is server-side (clock_timestamp around each query), so no round trips are included.
drop function if exists vec_bench(int, int);
drop function if exists vec_bench(int, int, boolean);
create or replace function vec_bench(k int default 10, filter_category int default null, exact boolean default false)
returns table (queries int, mean_ms numeric, p50_ms numeric, p99_ms numeric, recall numeric, avg_rows numeric)
language plpgsql as $$
declare
  q record; t0 timestamptz; got bigint[]; truth bigint[];
  lat double precision[] := '{}'; hits int := 0; total int := 0; nrows int := 0;
begin
  for q in select qid, embedding from item_queries order by qid loop
    t0 := clock_timestamp();
    -- "+ 0" turns the distance into an expression the HNSW index cannot order by: exact search
    if filter_category is null and not exact then
      select array_agg(id) into got from (
        select id from items order by embedding <=> q.embedding limit k) s;
    elsif filter_category is null then
      select array_agg(id) into got from (
        select id from items order by (embedding <=> q.embedding) + 0 limit k) s;
    elsif not exact then
      select array_agg(id) into got from (
        select id from items where category = filter_category order by embedding <=> q.embedding limit k) s;
    else
      select array_agg(id) into got from (
        select id from items where category = filter_category order by (embedding <=> q.embedding) + 0 limit k) s;
    end if;
    lat := lat || extract(epoch from clock_timestamp() - t0) * 1000;

    if filter_category is null then
      select array_agg(id) into truth from item_truth t where t.qid = q.qid;
    else
      -- exact filtered answer
      select array_agg(id) into truth from (
        select id from items where category = filter_category order by (embedding <=> q.embedding) + 0 limit k) s;
    end if;

    nrows := nrows + coalesce(cardinality(got), 0);
    hits  := hits + (select count(*) from unnest(got) g where g = any(truth));
    total := total + coalesce(cardinality(truth), 0);
  end loop;

  return query
    select cardinality(lat),
           round(avg(x)::numeric, 3),
           round(percentile_cont(0.5) within group (order by x)::numeric, 3),
           round(percentile_cont(0.99) within group (order by x)::numeric, 3),
           round(hits::numeric / nullif(total, 0), 3),
           round(nrows::numeric / cardinality(lat), 1)
    from unnest(lat) x;
end $$;
