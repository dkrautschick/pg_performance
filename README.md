# Thinking clearly about PostgreSQL (and AI) performance

Companion repository for the blog post in [`BLOG.md`](BLOG.md) (five bullets in [`BLOG_TLDR.md`](BLOG_TLDR.md)), and the foundation for a talk
of the same name. It retells Cary Millsap's *Thinking Clearly about Performance* for PostgreSQL in 2026, server side, client side, and for
vector and AI workloads, and every claim in the post that has a number in it has a script here that produces the number.

The ideas are vendor-neutral; the demos run on PostgreSQL 18 with pgvector and three sampling extensions. Every script resets what it needs,
runs a workload with `pgbench` or SQL, and prints the profile, not a single average.

| Script | Millsap idea | What it shows |
|---|---|---|
| `01_setup.sh` | measure what matters | database, extensions, preload check, the settings without which no timing data exists, `pg_test_timing` |
| `10_profile.sh` | the profile is an invoice | the same 15 s as a dashboard (all waits), as an invoice (`pg_stat_statements`), as per-statement wait profiles (`pg_wait_sampling`) and as kernel time (`pg_stat_kcache`) |
| `15_eliminate_calls.sh` | the fastest call is no call | the top line of the invoice, fixed with one index: 16,600 → 14 buffer visits, and what the index costs |
| `20_percentiles.sh` | users feel the variance | mean vs. p50/p90/p99/max of every transaction; the profile does not add up: 90% of the client's time is invisible to the server |
| `30_queueing.sh` | load, queueing, the knee | 1 … 64 clients on the same query: flat throughput, growing latency, Little's law, retrograde scaling |
| `40_roundtrips.sh` | eliminate calls (client side) | N+1 vs. one query, on localhost and through a latency proxy: 130 ms vs. 2.6 ms for the same 50 rows |
| `50_vector_seed.sh` | capacity | 100,000 clustered embeddings, exact ground truth, HNSW build time, index vs. table vs. `shared_buffers` |
| `51_vector_recall.sh` | requirements have a third axis | `hnsw.ef_search` sweep: latency percentiles *and* recall@10, against exact search |
| `52_vector_filter.sh` | a fast wrong answer | a 1% filter: HNSW returns 0.3 of 10 rows; iterative scans and a plain B-tree compared |
| `53_vector_footprint.sh` | memory is the capacity | `vector` vs. `halfvec` vs. binary quantization: index size, recall, oversampling |

`run_all.sh` runs everything in the order of the post (about 10 minutes with the defaults on a small box), `99_cleanup.sh` undoes it.

## Prerequisites

- `psql` and `pgbench` (PostgreSQL client package, 17 or newer; tested with 18)
- `python3` with `numpy` for the vector generator (`tools/gen_vectors.py`); the latency proxy (`tools/latency_proxy.py`) needs only the standard library
- A PostgreSQL 18 server with `pg_stat_statements`, `pg_wait_sampling`, `pg_stat_kcache` and `auto_explain` in `shared_preload_libraries`, and
  pgvector 0.8 or newer. The Docker stack below has all of it; on Debian/Ubuntu with the PGDG repository it is
  `apt install postgresql-18 postgresql-18-pgvector postgresql-18-pg-wait-sampling postgresql-18-pg-stat-kcache` plus `docker/perf.conf`.
  Without `pg_wait_sampling` and `pg_stat_kcache` the scripts skip those views and tell you so.

## Quick start

```bash
git clone https://github.com/dkrautschick/pg_performance && cd pg_performance
chmod +x scripts/*.sh tools/*.py                 # GitHub's web upload drops the executable bits
cp .env.example .env                             # defaults match the Docker stack
docker compose --env-file .env -f docker/compose.yml up -d --build --wait

scripts/01_setup.sh              # extensions, checks, pgbench schema (scale 10, 1,000,000 accounts)
scripts/10_profile.sh            # four views of one workload
scripts/15_eliminate_calls.sh    # fix the top line, measure before and after
scripts/20_percentiles.sh        # mean vs. percentiles, and the unaccounted-for time
scripts/30_queueing.sh           # the knee (STEPS="1 2 4 8 16 32 64", SECS=8)
scripts/40_roundtrips.sh         # N+1 vs. one query (PROXY_DELAY_MS=0.5)
scripts/50_vector_seed.sh        # embeddings, ground truth, HNSW (VEC_ROWS=100000, VEC_DIM=384)
scripts/51_vector_recall.sh      # ef_search vs. latency vs. recall
scripts/52_vector_filter.sh      # filtered vector search (CAT=7)
scripts/53_vector_footprint.sh   # halfvec, binary quantization

scripts/run_all.sh               # all of the above
scripts/99_cleanup.sh            # demo objects and out/; DROP_DB=yes, STOP_STACK=yes for more
```

Raw outputs (pgbench logs, per-transaction latencies) land in `out/`. All knobs are environment variables with defaults in `.env.example`.

## The numbers in the post

Measured with `run_all.sh` defaults on one vCPU and 3 GB of RAM, PostgreSQL 18.6, pgvector 0.8.7, pg_wait_sampling 1.1.11, pg_stat_kcache 2.3.2,
`shared_buffers = 512MB`. Small on purpose: on one CPU, queueing shows up early and clearly. Everything is local, so "network" is the proxy.

| Demo | Result |
|---|---|
| profile | dashboard: 80% CPU, 12% lock waits; invoice: one report = 69% of DB time, 16,576 buffers for 10 rows; kernel: 5.6 s CPU of 15 s runtime |
| eliminate calls | report 88.8 ms → 0.019 ms, 16,600 → 14 buffers per call, index 6.9 MB |
| percentiles | TPC-B mean 3.70 ms, p99 8.44 ms, max 19.4 ms; server-side 0.37 ms of 3.70 ms (90% unaccounted for) |
| queueing | 2 clients 11,941 tps at 0.16 ms; 16 clients 12,512 tps at 1.06 ms; 64 clients 8,612 tps at 5.15 ms |
| round trips | 50 rows: N+1 130.4 ms vs. one query 2.6 ms at ~2.5 ms per round trip; server under 0.6 ms in both |
| vector recall | exact 57 ms; HNSW 0.58 ms at recall 0.80 (`ef_search` 10), 0.84 ms at 0.97 (40), 1.46 ms at 0.99 (320) |
| vector filter | 1% filter: default HNSW 0.3 rows of 10 (recall 0.03); iterative scan 6.9 ms, recall 0.94; B-tree + exact 1.07 ms, recall 1.0 |
| footprint | HNSW 195 MB (table 157 MB); `halfvec` 112 MB at recall 0.98; binary 33 MB, recall 0.27 / 0.75 / 0.996 with 40 / 200 / 1,000 candidates |

## Test status, honestly

All scripts were run end to end against a local PostgreSQL 18.6 from the PGDG packages (Ubuntu 24.04) with the configuration in
`docker/perf.conf`, both with the defaults and with `run_all.sh` in a reduced mode (`RUN_SECONDS=4 VEC_ROWS=20000`); `shellcheck` is clean.
**Not tested: the Docker stack itself** (no Docker in the test environment). The Dockerfile builds on `pgvector/pgvector:0.8.7-pg18` and installs
the two sampling extensions from PGDG, which that Debian-based image has configured; issues welcome if it does not build for you.

The vector data is synthetic (Gaussian clusters, normalised): good for showing mechanics, unkind to binary quantization, and no substitute for
measuring recall on your own embeddings. The RAG time breakdown in the post is labelled as an illustration because it is one.

## Layout

```
scripts/   numbered bash scripts, all source scripts/00_lib.sh; run_all.sh, 99_cleanup.sh
sql/       the profile queries (10_*, 11_*, 12_*), the vector schema and benchmark function, pgbench workload files
tools/     gen_vectors.py (clustered embeddings in COPY format), latency_proxy.py (adds a delay per direction)
docker/    Dockerfile (PostgreSQL 18 + pgvector + pg_wait_sampling + pg_stat_kcache), compose.yml, perf.conf
docs/      observability.md: every setting in perf.conf, what it buys and what it costs
BLOG.md    the blog post; BLOG_TLDR.md its five bullets
```

## Notes and gotchas

- **`pg_wait_sampling` "CPU" means "not waiting on anything PostgreSQL instruments"**, which includes waiting in the OS run queue. `pg_stat_kcache`
  shows the real CPU seconds; the difference is queueing. `10_profile.sh` shows both side by side.
- **`pg_stat_statements` ends where the statement ends.** Round trips, commit latency seen by the client, pooler waits and the application are
  not in it. `20_percentiles.sh` compares client and server time.
- **HNSW and filters:** without `hnsw.iterative_scan`, a selective `WHERE` can return fewer than `LIMIT` rows. No error, no warning.
- **Binary quantization with re-ranking needs `hnsw.ef_search` ≥ the number of candidates**, otherwise the index stops at `ef_search` rows.
- **`15_eliminate_calls.sh` and `53_vector_footprint.sh` drop the indexes they create** so the other demos start from the same state; `KEEP_INDEX=yes` keeps them.
- **The latency proxy is a demo tool**, not a network emulator: fixed delay, no jitter, and Python adds about a millisecond per round trip on top of the configured delay.

## License

MIT. Measure first, then argue.
