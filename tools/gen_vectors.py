#!/usr/bin/env python3
"""Synthetic, clustered embeddings in COPY text format: id, category, embedding.

Random uniform vectors are a bad test for ANN indexes (every point is about equally far from
every other), so the points are drawn around CLUSTERS random centroids, normalised to length 1
like most real embedding models produce. Categories are random and independent of the
clusters, which is what makes filtered vector search hard. Deterministic with --seed.

    python3 tools/gen_vectors.py --rows 100000 --dim 384 --clusters 200 --categories 100 | \
      psql -c "COPY items (id, category, embedding) FROM STDIN"
"""
import argparse
import sys

import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--rows", type=int, default=100000)
ap.add_argument("--dim", type=int, default=384)
ap.add_argument("--clusters", type=int, default=200)
ap.add_argument("--categories", type=int, default=100)
ap.add_argument("--spread", type=float, default=0.35, help="noise around each centroid")
ap.add_argument("--seed", type=int, default=42)
ap.add_argument("--queries", type=int, default=0, help="emit N query vectors (id, embedding) instead")
a = ap.parse_args()

rng = np.random.default_rng(a.seed)
centroids = rng.standard_normal((a.clusters, a.dim)).astype(np.float32)
out = sys.stdout
batch = 5000

if a.queries:
    rng_q = np.random.default_rng(a.seed + 1)
    c = rng_q.integers(0, a.clusters, a.queries)
    v = centroids[c] + a.spread * rng_q.standard_normal((a.queries, a.dim)).astype(np.float32)
    v /= np.linalg.norm(v, axis=1, keepdims=True)
    for i in range(a.queries):
        out.write(f"{i + 1}\t[{','.join(f'{x:.5f}' for x in v[i])}]\n")
    sys.exit(0)

for start in range(0, a.rows, batch):
    n = min(batch, a.rows - start)
    c = rng.integers(0, a.clusters, n)
    v = centroids[c] + a.spread * rng.standard_normal((n, a.dim)).astype(np.float32)
    v /= np.linalg.norm(v, axis=1, keepdims=True)
    cat = rng.integers(1, a.categories + 1, n)
    lines = [f"{start + i + 1}\t{cat[i]}\t[{','.join(f'{x:.5f}' for x in v[i])}]" for i in range(n)]
    out.write("\n".join(lines) + "\n")
