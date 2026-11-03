#!/usr/bin/env bash
# Vector workload, part 1: load clustered embeddings, compute the exact answers once, build an HNSW index.
# What this measures: load time, table vs. index size against shared_buffers, and how long an index build takes.
source "$(dirname "$0")/00_lib.sh"
need python3
python3 -c "import numpy" 2>/dev/null || die "python3 with numpy needed (pip install numpy)"
[[ "$(q "select count(*) from pg_extension where extname = 'vector'")" == "1" ]] || die "pgvector not installed (run 01_setup.sh)"
QUERIES="${QUERIES:-50}"
K="${K:-10}"

say "Schema, ${VEC_ROWS} rows x ${VEC_DIM} dimensions, ${VEC_CLUSTERS} clusters, ${VEC_CATEGORIES} categories"
runf 50_vector_schema.sql -v dim="$VEC_DIM"
t0=$(date +%s.%N)
python3 "$ROOT/tools/gen_vectors.py" --rows "$VEC_ROWS" --dim "$VEC_DIM" --clusters "$VEC_CLUSTERS" --categories "$VEC_CATEGORIES" |
  psql -X -v ON_ERROR_STOP=1 -qc "copy items (id, category, embedding) from stdin"
python3 "$ROOT/tools/gen_vectors.py" --dim "$VEC_DIM" --clusters "$VEC_CLUSTERS" --queries "$QUERIES" |
  psql -X -v ON_ERROR_STOP=1 -qc "copy item_queries (qid, embedding) from stdin"
run "vacuum analyze items"; run "analyze item_queries"
ok "loaded $(q "select count(*) from items") rows in $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }') s"

say "Ground truth: exact top-$K for $QUERIES queries (a sequential scan per query; this is what an index saves)"
t0=$(date +%s.%N)
run "create table item_truth as
       select q.qid, n.id, n.rnk
       from item_queries q
       cross join lateral (
         select i.id, row_number() over (order by i.embedding <=> q.embedding) as rnk
         from items i order by i.embedding <=> q.embedding limit $K) n;
     alter table item_truth add primary key (qid, id)"
exact=$(awk -v a="$t0" -v b="$(date +%s.%N)" -v n="$QUERIES" 'BEGIN { printf "%.1f", 1000 * (b - a) / n }')
ok "exact search: ${exact} ms per query (sequential scan, no index)"
echo "$exact" >"$OUT/50_exact_ms"

say "HNSW index (m = 16, ef_construction = 64, the pgvector defaults), cosine distance"
run "drop index if exists items_embedding_hnsw"
t0=$(date +%s.%N)
psql -X -v ON_ERROR_STOP=1 -qc "set maintenance_work_mem = '${VEC_MWM:-512MB}'" \
     -c "create index items_embedding_hnsw on items using hnsw (embedding vector_cosine_ops)"
ok "index built in $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }') s"

say "Footprint: does the working set fit in memory?"
run "select pg_size_pretty(pg_relation_size('items'))                 as heap,
            pg_size_pretty(pg_total_relation_size('items') - pg_relation_size('items') - pg_indexes_size('items')) as toast,
            pg_size_pretty(pg_relation_size('items_embedding_hnsw'))  as hnsw_index,
            pg_size_pretty(pg_relation_size('items_pkey'))            as pk_index,
            current_setting('shared_buffers')                         as shared_buffers"
cat <<'EOF'
  An HNSW search touches graph pages at random. If the index does not fit in memory, every hop
  is a disk read, and the latency profile is an I/O profile. Size the box for the index, not for the table.
EOF
