#!/usr/bin/env bash
# Vector workload, part 3: the WHERE clause. Real RAG queries are never "nearest 10 of everything";
# they are "nearest 10 of this tenant, this language, this product line". With an HNSW index the filter
# is applied *after* the index produced ef_search candidates, so a selective filter can leave you with
# fewer than k rows, silently. pgvector 0.8 added iterative index scans for exactly this.
source "$(dirname "$0")/00_lib.sh"
[[ "$(q "select to_regclass('item_truth') is not null")" == "t" ]] || die "run 50_vector_seed.sh first"
runf 51_vector_bench.sql
CAT="${CAT:-7}"
sel=$(q "select round(100.0 * count(*) filter (where category = $CAT) / count(*), 2) from items")

say "Filter: category = $CAT (${sel}% of the rows), top-10, ef_search = 40"
printf '\n  %-34s %9s %9s %9s %8s %9s\n' variant mean_ms p50_ms p99_ms recall rows/query
printf '  %-34s %9s %9s %9s %8s %9s\n' ---------------------------------- --------- --------- --------- -------- ---------
bench() { # label, exact, extra settings...
  local label="$1" exact="$2"; shift 2
  local args=(-c "set hnsw.ef_search = 40")
  for s in "$@"; do args+=(-c "$s"); done
  IFS='|' read -r _ mean p50 p99 recall rows < <(psql -X -Atq "${args[@]}" -c "select * from vec_bench(10, $CAT, $exact)")
  printf '  %-34s %9s %9s %9s %8s %9s\n' "$label" "$mean" "$p50" "$p99" "$recall" "$rows"
}
bench "HNSW, post-filter (default)"       false "set hnsw.iterative_scan = off"
bench "HNSW, iterative_scan = relaxed"    false "set hnsw.iterative_scan = relaxed_order"
bench "HNSW, iterative_scan = strict"     false "set hnsw.iterative_scan = strict_order"
run "create index if not exists items_category on items (category)" 2>/dev/null
run "analyze items"
bench "B-tree on category, exact distance" true

say "Why the default returns so few rows"
cat <<EOF
  ef_search = 40 means the index hands over about 40 candidates. With ${sel}% of the rows matching the filter,
  you expect 40 x ${sel}% = $(awk -v s="$sel" 'BEGIN { printf "%.1f", 40 * s / 100 }') of them to survive the WHERE clause. You asked for 10.
  Nobody gets an error. The application gets fewer documents, the LLM gets less context, and the answer
  gets worse. That is a performance problem (it is about the quality of the experience) that no latency
  dashboard will ever show you.

  The remedies, each with a price:
    - hnsw.iterative_scan: keeps walking the graph until k rows pass the filter (bounded by hnsw.max_scan_tuples)
    - a B-tree on the filter column: exact answers, cost grows with the number of matching rows
    - partial HNSW indexes or partitioning by the filter column, when the filter values are few and stable
EOF
run "drop index if exists items_category"
