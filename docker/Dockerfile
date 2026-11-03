# PostgreSQL 18 with pgvector (from the pgvector image) plus the sampling extensions
# from the PGDG apt repository that the official image already has configured.
FROM pgvector/pgvector:0.8.7-pg18
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-18-pg-wait-sampling \
      postgresql-18-pg-stat-kcache \
      python3 python3-numpy \
 && rm -rf /var/lib/apt/lists/*
