#!/usr/bin/env bash
# Vector workload, part 4: memory is the capacity that matters. Half-precision (halfvec) and binary
# quantization shrink the index; the price is paid in recall, so measure both sides of the invoice.
source "$(dirname "$0")/00_lib.sh"
[[ "$(q "select to_regclass('item_truth') is not null")" == "t" ]] || die "run 50_vector_seed.sh first"

timed() { local t0; t0=$(date +%s.%N); psql -X -v ON_ERROR_STOP=1 -q -c "set maintenance_work_mem = '${VEC_MWM:-512MB}'" -c "$1"; awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }'; }

say "Three HNSW indexes on the same embeddings"
run "drop index if exists items_embedding_half, items_embedding_bit"
t_half=$(timed "create index items_embedding_half on items using hnsw ((embedding::halfvec($VEC_DIM)) halfvec_cosine_ops)")
t_bit=$(timed "create index items_embedding_bit on items using hnsw ((binary_quantize(embedding)::bit($VEC_DIM)) bit_hamming_ops)")
ok "halfvec index built in ${t_half} s, binary index in ${t_bit} s"

say "Recall@10 of each, ef_search = 40 (binary: 40 candidates by Hamming distance, re-ranked exactly)"
run "set hnsw.ef_search = 40;
with r as (
  select 'vector (float4)' as variant, pg_relation_size('items_embedding_hnsw') as bytes,
         (select avg(hit) from (
            select q.qid, (select count(*) from item_truth t where t.qid = q.qid and t.id = any(a.ids)) / 10.0 as hit
            from item_queries q, lateral (select array_agg(id) ids from (
              select id from items order by embedding <=> q.embedding limit 10) s) a) x) as recall
  union all
  select 'halfvec (float2)', pg_relation_size('items_embedding_half'),
         (select avg(hit) from (
            select q.qid, (select count(*) from item_truth t where t.qid = q.qid and t.id = any(a.ids)) / 10.0 as hit
            from item_queries q, lateral (select array_agg(id) ids from (
              select id from items order by embedding::halfvec($VEC_DIM) <=> q.embedding::halfvec($VEC_DIM) limit 10) s) a) x)
  union all
  select 'bit + re-rank', pg_relation_size('items_embedding_bit'),
         (select avg(hit) from (
            select q.qid, (select count(*) from item_truth t where t.qid = q.qid and t.id = any(a.ids)) / 10.0 as hit
            from item_queries q, lateral (select array_agg(id) ids from (
              select id from (
                select id, embedding from items
                order by binary_quantize(embedding)::bit($VEC_DIM) <~> binary_quantize(q.embedding) limit 40) c
              order by c.embedding <=> q.embedding limit 10) s) a) x)
)
select variant, pg_size_pretty(bytes) as index_size, round(recall, 3) as recall_at_10 from r"

say "Binary quantization lives on oversampling: N candidates by Hamming distance, re-ranked by the real distance"
echo "  (hnsw.ef_search must be >= N, otherwise the index hands over at most ef_search candidates)"
printf '\n  %10s %12s %8s\n' candidates ms_per_query recall
printf '  %10s %12s %8s\n' ---------- ------------ --------
for c in ${OVERSAMPLE:-40 200 1000}; do
  t0=$(date +%s.%N)
  r=$(psql -X -Atq -c "set hnsw.ef_search = $c" -c "select round(avg(hit), 3) from (
        select (select count(*) from item_truth t where t.qid = q.qid and t.id = any(a.ids)) / 10.0 as hit
        from item_queries q, lateral (select array_agg(id) ids from (
          select id from (
            select id, embedding from items
            order by binary_quantize(embedding)::bit($VEC_DIM) <~> binary_quantize(q.embedding) limit $c) c
          order by c.embedding <=> q.embedding limit 10) s) a) x")
  n=$(q "select count(*) from item_queries")
  printf '  %10s %12s %8s\n' "$c" "$(awk -v a="$t0" -v b="$(date +%s.%N)" -v n="$n" 'BEGIN { printf "%.2f", 1000 * (b - a) / n }')" "$r"
done

cat <<'EOF'

  The table itself does not shrink (the expression indexes keep the float4 column as the source of truth),
  but the part that must stay in memory for fast searches does. Whether a recall loss is acceptable is,
  again, a requirement question and not a tuning question.
EOF
if [[ "${KEEP_INDEX:-no}" != "yes" ]]; then
  run "drop index items_embedding_half, items_embedding_bit"
  ok "extra indexes dropped (KEEP_INDEX=yes keeps them)"
fi
