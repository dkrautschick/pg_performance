#!/usr/bin/env bash
# Vector workload, part 2: the knob pgvector gives you at query time, hnsw.ef_search.
# Performance of a vector query has a new axis: the answer can be fast and wrong. Recall@k is part of the
# requirement, next to the percentile. "95% of searches under 5 ms with recall >= 0.95" is a specification;
# "vector search is fast" is not.
source "$(dirname "$0")/00_lib.sh"
EF="${EF:-10 20 40 80 160 320}"
[[ "$(q "select to_regclass('item_truth') is not null")" == "t" ]] || die "run 50_vector_seed.sh first"
runf 51_vector_bench.sql

say "Exact search for comparison (no index can serve it: ORDER BY distance + 0)"
IFS='|' read -r _ emean _ ep99 erecall _ < <(q "select * from vec_bench(10, null, true)")
ok "exact: mean ${emean} ms, p99 ${ep99} ms, recall ${erecall}"

say "HNSW, top-10, ef_search sweep (server-side timing, $(q "select count(*) from item_queries") queries each)"
q "select vec_bench()" >/dev/null   # warm the cache once
printf '\n  %9s %9s %9s %9s %8s\n' ef_search mean_ms p50_ms p99_ms recall
printf '  %9s %9s %9s %9s %8s\n' --------- --------- --------- --------- --------
for ef in $EF; do
  IFS='|' read -r _ mean p50 p99 recall _ < <(psql -X -Atq -c "set hnsw.ef_search = $ef" -c "select * from vec_bench()")
  printf '  %9s %9s %9s %9s %8s\n' "$ef" "$mean" "$p50" "$p99" "$recall"
done

say "The plan, so you know which index answered"
psql -X -q -c "set hnsw.ef_search = 40" -c "explain (analyze, buffers, costs off, summary off)
  select id from items order by embedding <=> (select embedding from item_queries where qid = 1) limit 10" | sed -n '1,14p'

cat <<'EOF'
  ef_search is a dial between latency and correctness. pgvector's default is 40. Where the dial should sit
  is a business decision (what does a wrong neighbour cost in your RAG answer?), so measure recall on your
  own embeddings, with your own queries, before anyone calls it "tuned".
EOF
