-- The vector demo table: an id, a category to filter on, an embedding.
-- :dim is set by the script (psql -v dim=384).
set client_min_messages = warning;
drop table if exists items, item_queries, item_truth cascade;
create table items (
  id        bigint primary key,
  category  int not null,
  embedding vector(:dim) not null
);
create table item_queries (
  qid       int primary key,
  embedding vector(:dim) not null
);
