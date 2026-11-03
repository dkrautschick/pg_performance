#!/usr/bin/env bash
# Shared helpers. Every script sources this file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

: "${PG_HOST:=localhost}" "${PG_PORT:=5432}" "${PG_USER:=postgres}" "${PG_PASSWORD:=perf}" "${PG_DB:=perfdb}"
: "${PGBENCH_SCALE:=10}" "${RUN_SECONDS:=15}"
: "${VEC_ROWS:=100000}" "${VEC_DIM:=384}" "${VEC_CLUSTERS:=200}" "${VEC_CATEGORIES:=100}"
: "${PROXY_DELAY_MS:=0.5}" "${PROXY_PORT:=6543}"
export PGHOST="$PG_HOST" PGPORT="$PG_PORT" PGUSER="$PG_USER" PGPASSWORD="$PG_PASSWORD" PGDATABASE="$PG_DB"

OUT="$ROOT/out"
mkdir -p "$OUT"

say()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; exit 1; }

# psql wrappers: q = one bare value, run = pretty output, runf = a file from sql/
q()    { psql -X -v ON_ERROR_STOP=1 -Atqc "$1"; }
run()  { psql -X -v ON_ERROR_STOP=1 -qc "$1"; }
runf() { local f="$1"; shift; psql -X -v ON_ERROR_STOP=1 -q "$@" -f "$ROOT/sql/$f"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

# Is a library preloaded? (pg_stat_statements, pg_wait_sampling, ...)
preloaded() { q "show shared_preload_libraries" | tr ',' '\n' | sed 's/ //g' | grep -qx "$1"; }

reset_stats() {
  q "select pg_stat_statements_reset()" >/dev/null
  if preloaded pg_wait_sampling; then q "select pg_wait_sampling_reset_profile()" >/dev/null; fi
  if preloaded pg_stat_kcache;  then q "select pg_stat_kcache_reset()" >/dev/null; fi
}

# Percentiles from a pgbench per-transaction log (-l). Column 3 is latency in microseconds.
# Prints: n mean p50 p90 p99 p999 max (milliseconds)
latency_stats() {
  awk '{print $3}' "$@" | sort -n | awk '
    { v[NR]=$1; s+=$1 }
    END {
      if (NR==0) { print "0 0 0 0 0 0 0"; exit }
      i50=int(NR*0.50); if(i50<1)i50=1
      i90=int(NR*0.90); if(i90<1)i90=1
      i99=int(NR*0.99); if(i99<1)i99=1
      i999=int(NR*0.999); if(i999<1)i999=1
      printf "%d %.3f %.3f %.3f %.3f %.3f %.3f\n", NR, s/NR/1000, v[i50]/1000, v[i90]/1000, v[i99]/1000, v[i999]/1000, v[NR]/1000
    }'
}
