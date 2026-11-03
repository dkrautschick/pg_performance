# Thinking clearly about PostgreSQL (and AI) performance

### What a two-part talk at DOAG 2013 taught me about response time, why it matters more for vector search than it ever did for OLTP, and what the coming GPUs will not change

*Every number in this post was measured with the scripts in the companion repository
[dkrautschick/pg_performance](https://github.com/dkrautschick/pg_performance), on a deliberately small box (one vCPU, 3 GB of RAM,
PostgreSQL 18.6, pgvector 0.8.7). Your numbers will be different. The shapes will not, and the shapes are the point.*

## Nuremberg, November 2013

Some talks you forget on the way to the coffee. Some you carry around for a decade. At the DOAG conference in Nuremberg in 2013 I sat
through a two-part session by Cary Millsap called *Thinking Clearly about Performance*. I was an Oracle DBA then, my head full of wait
events, hit ratios and the comforting belief that a sufficiently large AWR report contains the answer to everything.

What stuck was not a trick. It was a way of asking the question. Millsap is the person behind Method R, the Oracle trace-file profilers and
the book *Optimizing Oracle Performance*, yet the talk was barely about Oracle. It was about what performance *is*, in words that work for
any database, any programming language and any manager. The paper behind it, first published in 2010 in ACM Queue and Communications of the
ACM and today chapter 1 of [*The Method R Guide to Mastering Oracle Trace Data*](https://method-r.com/wp-content/uploads/2018/07/TCAP-from-MOTD2.pdf),
is still the best thirty pages on the topic I know.

Since then I changed databases, from Oracle to PostgreSQL, and audiences, from DBA teams to developers and the people who sign the cloud
bill. I gave talks about performance analysis in PostgreSQL in Prague (2022) and Paris (2024). And now the questions I get are about vector
search, RAG pipelines and whether we should all buy GPUs. Interestingly, Millsap's paper answers most of those too. This post is my attempt
to retell it for PostgreSQL in 2026: for the DBA who has seen everything, for the developer who just wants the endpoint to be fast, and for the
decision maker who has to choose between a bigger instance, a vector database and "the AI team's GPU budget".

## "The system is slow" is not a sentence

Every performance problem I have ever been called for started with one of two sentences. *"The system is slow."* Bad. *"The system was slow."*
Worse. (It is in my 2022 slides, and it is still true.)

Millsap's first move is to take the sentence apart. A **task** is a business unit of work: "book order", "search the knowledge base", "answer
the customer's question". An **experience** is one execution of a task by one person at one moment. **Response time** is the duration of an
experience. **Throughput** is how many experiences complete per unit of time. And then the sentence that changed how I write tickets:

> Performance is not an attribute of a system. It is an attribute of each individual experience with a system.

"Is the database fast?" has no answer. The database is fast for one task and slow for another, fast at 10:00 and slow at 10:05, fast for one
tenant and slow for the one with forty million rows. What you *can* answer is "how long did *this* experience take, and why?"

That is not pedantry. It decides what you measure. If performance belongs to the experience, then CPU utilization, buffer hit ratio and IOPS
are not performance. They are *surrogate measures*: easy to collect, sometimes correlated with what the user feels, and, as Millsap puts it
with admirable bluntness, they suck. Not because they are always wrong. Because they are *sometimes* right, which makes you trust them right
up to the moment they betray you.

The vocabulary for the rest of this post, in one table:

| Term | Meaning | PostgreSQL where you see it |
|---|---|---|
| Response time *R* | duration of one experience | client-side timing, `pgbench -l`, application traces |
| Throughput *X* | experiences per second | `tps` in pgbench, `calls` per interval in `pg_stat_statements` |
| Percentile | "*R* below 1 s in 99% of experiences" | not in `pg_stat_statements` (only mean, stddev, min, max) |
| Profile | response time split into what it was spent on, adding up to *R* | `pg_stat_statements`, `pg_wait_sampling`, `EXPLAIN (ANALYZE, BUFFERS)` |
| Service time *S* | time actually working on a resource | CPU seconds in `pg_stat_kcache`, I/O time with `track_io_timing` |
| Queueing delay *Q* | time waiting for a busy resource | invisible as such; shows up as growing *R* at constant *S* |
| Coherency delay | time waiting to coordinate with others | wait events `Lock:*`, `LWLock:*`, `IO:WALSync` on commit |
| Knee | utilization above which *R* starts to explode | the point where adding clients stops adding throughput |

## Users feel the variance, not the mean

Millsap's second move: averages lie in exactly the way users do not. He shows two lists of ten response times with the same mean of 1.000 s.
In one, nine of ten are under a second. In the other, only six are. Same average, very different Monday.

`scripts/20_percentiles.sh` runs pgbench's TPC-B-like transaction for 15 seconds with four clients, logs every single transaction and summarises
the same 16,067 experiences two ways:

| | ms |
|---|---|
| mean | 3.70 |
| median (p50) | 3.44 |
| p90 | 4.81 |
| p99 | 8.44 |
| p99.9 | 15.22 |
| max | 19.36 |

One transaction in a hundred takes more than twice the average. One in a thousand takes four times as long. In an earlier run of the same
script, where the `CHECKPOINT` halfway through hit harder, the maximum was 61 ms. The mean barely moved.

Now the uncomfortable part: `pg_stat_statements`, the extension every PostgreSQL monitoring tool is built on, stores `mean_exec_time`,
`stddev_exec_time`, `min_exec_time` and `max_exec_time`. No percentiles, and a standard deviation does not help much for distributions with a
long tail on one side. If you want percentiles, you need per-experience data: a client-side histogram, `pgbench -l`, the application's own
metrics, or a sampled log (`log_min_duration_sample`, `log_transaction_sample_rate`).

A requirement worth writing down therefore looks like Millsap's two-tier specification:

> "The transaction completes in under 5 ms in 90% of executions and under 9 ms in 99% of executions."

"Average under 4 ms" lets the worst hundredth of your users go hang. "CPU under 80%" is not a requirement at all, it is a wish about a surrogate.

## The invoice: Method R in PostgreSQL

Here is the heart of the paper. A **profile** is a table that decomposes a response time into the things it was spent on, sorted by how much
time each one took. Millsap calls it an invoice, and the metaphor is perfect. There are only two ways an invoice can be too high: a quantity
is too large, or a unit price is too high. There are only two ways a response time can be too long: some **call count** is too large, or some
**call latency** is too high. Everything in performance optimisation is one of those two.

From that he builds three axioms:

1. **To improve a system, you must measure what matters.** What matters is the experience, not the component.
2. **You cannot guess where your system spends its time; you must measure it.** Knuth, Kernighan, everybody: their guesses about hot spots were wrong.
3. **The fastest call is no call.** Eliminating calls beats making calls faster, and it is also the best way to make the remaining calls faster.

And a method, Method R, small enough for a slide:

```
while performance is not economically optimal
    pick the experience you most need to improve           (business priority, not loudest complaint)
    profile it: measure its response time R and where R went
    if your program makes unnecessary calls         -> eliminate them
    else if calls are not running at hardware speed -> eliminate other programs' calls competing with yours
    else                                            -> upgrade the hardware
```

Note what is at the end of the list. Hardware is the last resort, not the first. "Kill it with iron" (my 2022 slide calls it KIWI) is
sometimes right, but only after you have proven the calls are necessary and already run at full speed.

### What PostgreSQL gives you for a profile

Oracle people are spoiled (I was one): extended SQL trace, ASH, AWR, ADDM, and the Diagnostics Pack licence to go with it. PostgreSQL has none
of that built in. What it has is extensibility, and in my experience that is a feature, not a workaround. The toolbox I install on every
cluster before the first problem arrives, because a profile you start collecting during the incident is a profile of the wrong hour:

- **`pg_stat_statements`** (contrib): one row per normalised statement with `calls`, total, mean, min, max and stddev of execution and planning
  time, rows, buffer hits and reads, temp blocks, WAL bytes, and with `track_io_timing = on` the time spent in I/O. That is calls × latency per
  statement, the invoice by line item.
- **`pg_wait_sampling`** (Postgres Pro, open source): samples every backend's wait event every 10 ms and keeps a profile per process and
  per `queryid`. Unsampled `pg_stat_activity` only tells you what is happening *now*; this tells you what happened. It is the closest thing
  to ASH in the PostgreSQL world, and it joins with `pg_stat_statements` on `queryid`.
- **`pg_stat_kcache`** (PoWA team): what the kernel saw per statement: user and system CPU time, real file system reads and writes, context
  switches. It answers a question the other two cannot: was it really CPU?
- **`auto_explain`** (contrib): the plan, with buffers, of every statement slower than a threshold, in the log. The only way to see the plan
  that *was* used at 03:12, not the plan you get when you try it at 10:00.
- **Logging plus [pgBadger](https://pgbadger.darold.net/)**: `log_min_duration_statement`, `log_lock_waits`, `log_temp_files = 0`,
  `log_checkpoints`, `log_autovacuum_min_duration`, a `log_line_prefix` with application name, client and `%Q` (query id). Cheap,
  boring, and the place where 'what happened last night' usually is.

The catch, and the reason for my 2024 talk: in PostgreSQL every relevant piece of information is there, *but only for now*. Statistics are
cumulative since the last reset, wait samples live in a ring buffer, `pg_stat_activity` is a snapshot. A profile needs a time window. So you
need snapshots in a repository: [pg_profile](https://github.com/zubkov-andrei/pg_profile) does exactly that in pure PL/pgSQL (samples of
`pg_stat_statements`, `pg_stat_kcache`, `pg_wait_sampling` and the statistics views, every 30 minutes from cron, with baselines and diff
reports between two windows). [pgwatch](https://github.com/cybertec-postgresql/pgwatch) and similar tools do the same as time series. Which
one you choose matters less than having one *before* the incident. On managed services, check which of these extensions are available; not
all of them are everywhere.

### A profile, read like an invoice (`10_profile.sh`)

The script resets all statistics and runs a mixed workload for 15 seconds on the one-vCPU box: four clients doing TPC-B transactions, two
doing primary-key lookups, one running a small report (`WHERE bid = $1 ORDER BY abalance DESC LIMIT 10`, no index on `bid`). Then it prints
four views of the same 15 seconds.

**View 1, the dashboard.** All wait samples of all client backends, summed. This is what most monitoring shows:

| spent on | share |
|---|---|
| CPU | 79.5% |
| Lock:transactionid | 11.6% |
| IO:AioIoCompletion | 5.9% |
| everything else | 3.0% |

The obvious conclusions: "the box is CPU bound, buy more cores" and "we have a locking problem". Both are statements about the *system*.
Remember Millsap's payroll job: a monitoring tool said the system's bottleneck was latch waits, the team spent months on latches, and the
payroll job's own profile showed latches were 1.2% of *its* time. Its real problem was the network.

**View 2, the invoice** (`pg_stat_statements`, sorted by total time):

| statement | calls | total ms | % | mean ms | blocks/call | rows/call |
|---|---|---|---|---|---|---|
| `SELECT ... WHERE bid = $1 ORDER BY ...` | 73 | 14,986 | 68.8 | 205.3 | 16,576 | 10 |
| `UPDATE pgbench_branches ...` | 4,501 | 5,153 | 23.6 | 1.15 | 5 | 1 |
| `UPDATE pgbench_tellers ...` | 4,501 | 734 | 3.4 | 0.16 | 5 | 1 |
| `SELECT abalance ... WHERE aid = $1` | 42,847 | 451 | 2.1 | 0.011 | 4 | 1 |

The top line is where the money went: 73 executions of a report, 69% of all database time. And the line carries its own diagnosis: 16,576
buffer visits to return 10 rows. That is Millsap's "efficiency" example almost literally (his had 7,428,322 buffer touches for a 698-row
result). Second line: the branch update, cheap per call but expensive in total.

**View 3, per statement, where the time went** (`pg_wait_sampling`, joined on `queryid`):

| statement | spent on | share of the statement |
|---|---|---|
| the report | CPU | 96.5% |
| `UPDATE pgbench_branches` | Lock:transactionid | 94.9% |
| `UPDATE pgbench_tellers` | Lock:transactionid | 93.9% |
| point lookup | CPU | 100% |

So the "locking problem" from view 1 belongs to two specific statements (with scale 10 there are only ten branch rows for four clients to
fight over: coherency delay, more on that below), and the "CPU problem" belongs to the report.

**View 4, what the kernel saw** (`pg_stat_kcache`): the report ran for 14.99 s in total, but used only 5.31 s of user and 0.34 s of system
CPU. `pg_wait_sampling` reported 96.5% "CPU" for the same statement. Both are right. A sampler can only see that a backend is *not waiting
on anything PostgreSQL instruments*; it cannot see whether the process is on the CPU or in the operating system's run queue waiting for one.
Seven busy sessions and pgbench itself on one vCPU: about 9 of the report's 15 seconds were queueing for the CPU. Without `pg_stat_kcache`
you would call that statement "CPU bound" and start optimising its arithmetic.

Here is the full Method R loop on that profile. Prediction first, Amdahl's law style: the report is 69% of database time, so fixing it can
save at most 69% of database time, and nothing for the branch updates. Then the remedy, `scripts/15_eliminate_calls.sh`: one index on
`(bid, abalance desc)`. Measured with one client and nothing else running:

| | mean ms | blocks per call |
|---|---|---|
| before | 88.83 | 16,600 |
| after | 0.019 | 14 |

Eliminating calls, where "calls" are buffer visits: 16,600 became 14, and the report is 4,600 times faster. Notice also the before-value: 88.8
ms alone, 205.3 ms in the mixed workload. Same statement, same plan, same rows. The difference of 2.3× is load, which is the next section.
And notice the price on the other side of the invoice, which the script prints: a 6.9 MB index that every future update of `abalance` has to
maintain. Millsap's "match the scope of the solution to the scope of the problem" applies: if the report runs twice a day, a read replica
or an analytical sidekick may be the cheaper remedy than an index on the OLTP primary.

### The profile has to add up

Millsap's definition of a profile has a strict second half: its lines must add up exactly to the response time you are diagnosing. No
overlaps, no gaps. The percentile run above lets us check that for PostgreSQL:

| | ms per transaction |
|---|---|
| client: mean transaction latency (pgbench) | 3.703 |
| server: statement execution time (`pg_stat_statements`) | 0.370 |
| **unaccounted for** | **3.333** |

Ninety per cent of the experience is invisible to the most popular PostgreSQL performance extension. On this box most of it is CPU queueing
(four sessions and the client on one vCPU), plus seven round trips per transaction (BEGIN, five statements, END) and the commit's WAL flush.
On your system it will be network round trips, the connection pool, the ORM, TLS, the application's own work. Millsap had a whole chapter on
"unaccounted-for time" in Oracle trace files. In PostgreSQL the gap is usually larger, because the server's statistics end where the statement
ends. A server-side profile is a profile of the server. If the experience is the user's, measure at the client too.

## The fastest call is no call: the client side

The cheapest place to win performance is where most DBAs never look: the application. The classic is the ORM's N+1 pattern: load a list, then
fetch each element with its own query. `scripts/40_roundtrips.sh` fetches the same 50 rows two ways, 50 single-row `SELECT`s in one
transaction or one `SELECT ... WHERE aid BETWEEN $1 AND $1 + 49`, once directly on localhost and once through `tools/latency_proxy.py`, a
fifty-line asyncio proxy that delays every packet a little in each direction. Configured with 0.5 ms each way, it costs about 2.5 ms per round
trip in practice, roughly what a client in the next availability zone sees.

| variant | client ms per transaction | server ms per transaction | round trips |
|---|---|---|---|
| N+1, localhost | 3.45 | 0.25 | 52 |
| one query, localhost | 0.10 | 0.02 | 1 |
| N+1, 2.5 ms round trip | **130.43** | 0.54 | 52 |
| one query, 2.5 ms round trip | **2.57** | 0.03 | 1 |

The database's work is under a millisecond in every variant. The user's wait differs by a factor of 50. No index, no `shared_buffers`, no
bigger instance and no GPU changes the 130 ms, because the database is not where the time goes. Millsap's formula is `d = c · f(c)`: duration
is call count times a latency that itself grows with the call count. With a network in between, *c* is round trips.

The client-side checklist I give developers, in Millsap's order (eliminate calls first):

- **Fetch sets, not rows.** `WHERE id = ANY($1)`, joins, `JOIN LATERAL`, `COPY` for bulk loads, multi-row `INSERT`s, batching in the driver
  (pipeline mode in libpq and many drivers).
- **Look at your ORM's SQL log once.** Count the statements of one request. If you are surprised, that is the finding.
- **Keep connections.** PostgreSQL forks a process per connection. Connecting per request is a call you can eliminate; a pooler (PgBouncer or the
  one in your platform) eliminates it for everyone.
- **Keep transactions short.** Millsap's example of a form with separate "Update" and "Save" buttons, where a user clicks Update and goes to
  lunch, is the PostgreSQL `idle in transaction` session holding row locks and blocking vacuum. `idle_in_transaction_session_timeout` is the
  guard rail; the fix is in the code.
- **Prepare what repeats**, and set a fetch size for big results, so a million-row export is not a million round trips (or one 4 GB response).
- **Instrument.** Set `application_name`, tag queries (sqlcommenter-style comments survive into logs), propagate trace ids. A database
  that knows which request a statement belongs to can produce a profile per experience instead of per statement.

## Load: why "it was fine in test" (queueing and coherency)

Even a perfectly efficient program gets slower when others use the same resources. Millsap names two reasons, and both are visible in PostgreSQL.

**Queueing delay.** `scripts/30_queueing.sh` runs the cheapest query there is, one row by primary key, with 1, 2, 4, … 64 concurrent
clients on the single vCPU:

| clients | tps | mean ms | p99 ms | clients / tps (ms) |
|---|---|---|---|---|
| 1 | 6,219 | 0.16 | 0.62 | 0.16 |
| 2 | 11,941 | 0.16 | 0.33 | 0.17 |
| 4 | 11,275 | 0.34 | 0.81 | 0.36 |
| 8 | 12,209 | 0.57 | 1.32 | 0.66 |
| 16 | 12,512 | 1.06 | 2.09 | 1.28 |
| 32 | 11,102 | 2.35 | 3.57 | 2.88 |
| 64 | 8,612 | 5.15 | 8.87 | 7.43 |

From two clients on, throughput is flat: the CPU is full. Every client after that adds nothing but waiting. Response time grows linearly with
the clients, exactly as Little's law says (the last column, clients divided by throughput, tracks the measured mean). The query does not get
slower, `pg_stat_statements` would show the same execution time at 1 and at 64 clients. The *experience* gets slower, because *R = S + Q*, and
*Q* is everything above the first row.

Millsap's practical rule is the **knee**: the utilization beyond which small load spikes cause large response time spikes. For M/M/m queueing
systems it is about 50% for one CPU, 74% for 8, 81% for 16, 86% for 32 and 92% for 128. Real systems are not M/M/m, so treat these as starting
points, adjust them against your percentile requirement, and notice what they say about sizing: a 4-vCPU database "at only 60% CPU" may already
be past its knee, while a 64-vCPU one at 85% may be fine. And the knee is per resource: CPU, disk, network, and in PostgreSQL also the number of
active backends, which is why a connection pooler capping active connections near the core count is a performance feature, not an
administrative nuisance.

**Coherency delay.** At 64 clients the throughput does not just stay flat, it *drops* from 12,500 to 8,600 tps. Work that serves nobody grows
with the number of participants: context switches, lock manager and buffer-mapping coordination, cache lines bouncing between processes.
Neil Gunther's Universal Scalability Law models exactly this retrograde curve. The profile in view 3 above showed the other face of it:
`UPDATE pgbench_branches` spent 95% of its time in `Lock:transactionid`, waiting for other transactions to commit changes to the same ten rows.
No amount of CPU helps there. Coherency delay is a design property (a hot row, a counter table, a global sequence of work), and it is the
reason Millsap warns that a test on an unloaded system can never give a go/no-go for production. PostgreSQL 19 adds a `pg_stat_lock` view with
per-lock-type statistics, which makes this kind of profile easier to get without a sampling extension.

## The server side: tuning, in that order

Having said that the client side is often cheaper, the server side still matters, and Method R gives it an order:

1. **Find the statement** (`pg_stat_statements`, sorted by total time, not by mean: the 0.01 ms query called 40,000 times can matter more
   than the 200 ms one called twice).
2. **Read its plan with buffers.** `EXPLAIN (ANALYZE, BUFFERS)`, with `SETTINGS` and `WAL` when relevant, ideally the one `auto_explain`
   logged at the time. Buffers are call counts. "Rows removed by filter: 999,990" is a call count. A sort spilling to disk is a call count
   (temp blocks). Visualisers like [explain.dalibo.com](https://explain.dalibo.com/) help once plans get long.
3. **Eliminate the calls in the plan**: the right index, a rewrite, fresh statistics (`ANALYZE`, extended statistics for correlated columns),
   a working autovacuum so the planner's estimates and the visibility map are true, `work_mem` for the one query that sorts, not for all.
4. **Then the instance**: `shared_buffers` and the operating system cache for the working set, checkpoint spacing (`max_wal_size`), parallel
   workers for the analytical minority, connection limits for the queueing reasons above. PostgreSQL's defaults are deliberately small;
   [pgtune](https://pgtune.leopard.in.ua/) or [pgconfigurator](https://pgconfigurator.cybertec.at/) are a fine first pass.
5. **Then hardware**, with a prediction of what it will buy, derived from the profile.

The current releases help along that path. PostgreSQL 18 brought an asynchronous I/O subsystem (`io_method`, with `worker` as the default; you
can see it as `IO:AioIoCompletion` in the dashboard view above) and makes `EXPLAIN ANALYZE` include buffer counts by default, so the call
counts are there even for people who forget to ask. PostgreSQL 19, at release candidate stage as I write this with general availability
planned for 19 November 2026, adds `pg_stat_lock`, parallel autovacuum workers, `REPACK [CONCURRENTLY]`, the `pg_plan_advice` extension to
guide the planner without permanent hints, and switches JIT off by default (one of the more common sources of mysterious planning-time
spikes in OLTP profiles). Read the release notes for your version; none of it replaces the profile.

## AI workloads: performance gets a new dimension

Now to the questions I actually get these days. "We need a vector database." "Our RAG endpoint is slow." "Should PostgreSQL run on GPUs?"
Millsap's framework works unchanged, with one addition that changes a lot.

### A fast wrong answer is not performance

A B-tree returns the right rows or none. An approximate nearest-neighbour (ANN) index like HNSW returns *probably* the right rows, and how
probably is a dial you set. For vector search, the definition of a good experience has a third term next to response time and throughput:
**recall**, the fraction of the true nearest neighbours that the index actually returned.

`scripts/50_vector_seed.sh` loads 100,000 synthetic, clustered 384-dimensional embeddings (the size of a typical small sentence-embedding
model), computes the exact top-10 for 50 queries, and builds an HNSW index with pgvector's defaults (`m = 16`, `ef_construction = 64`). Already
the setup has two findings for capacity planning: the index (195 MB) is *larger* than the table (157 MB), and it took 32 seconds to build on one
vCPU. HNSW search jumps around the graph at random, so if that index does not fit in memory, every hop is a disk read. Size for the index,
not for the table.

`scripts/51_vector_recall.sh` then sweeps `hnsw.ef_search`, the size of the candidate list at query time (server-side timing, 50 queries each):

| method | mean ms | p99 ms | recall@10 |
|---|---|---|---|
| exact (sequential scan) | 57.08 | 62.26 | 1.000 |
| HNSW, `ef_search = 10` | 0.58 | 1.84 | 0.796 |
| HNSW, `ef_search = 20` | 0.69 | 1.99 | 0.918 |
| HNSW, `ef_search = 40` (default) | 0.84 | 2.37 | 0.968 |
| HNSW, `ef_search = 80` | 1.00 | 2.64 | 0.974 |
| HNSW, `ef_search = 320` | 1.46 | 3.86 | 0.994 |

The index is 70 times faster than the exact search. And at the fastest setting, one in five "nearest neighbours" is not one. The requirement
therefore has three parts, and Millsap's two-tier specification grows a third: *"95% of searches under 2 ms, 99% under 5 ms, with recall@10
of at least 0.95, measured on our embeddings and our queries."* Where the dial sits is a business decision (what does a wrong document in the
LLM's context cost you?), not a tuning default.

### The WHERE clause is where it gets interesting

Real retrieval queries are never "the nearest 10 of everything". They are "the nearest 10 for this tenant, this language, this product line".
With an HNSW index, PostgreSQL asks the index for candidates in distance order and applies the filter afterwards. `scripts/52_vector_filter.sh`
adds `WHERE category = 7`, which matches 1% of the rows:

| variant | mean ms | p99 ms | recall@10 | rows returned |
|---|---|---|---|---|
| HNSW, default (post-filter) | 1.12 | 3.33 | 0.026 | **0.3** |
| HNSW, `iterative_scan = relaxed_order` | 6.89 | 14.24 | 0.942 | 10 |
| HNSW, `iterative_scan = strict_order` | 8.44 | 34.25 | 0.832 | 10 |
| B-tree on `category`, exact distance | 1.07 | 3.36 | 1.000 | 10 |

Read the first row twice. The query asked for 10 rows and got 0.3 on average, with no error and no warning. The index handed over about 40
candidates (`ef_search`), of which 1% survived the filter. The latency dashboard is green. The RAG pipeline receives almost no context, and the
LLM confidently answers from nothing. That is a performance problem in Millsap's sense, because it is a bad experience, and no monitoring
of response times will ever show it.

pgvector 0.8 added iterative index scans for exactly this case: the scan keeps walking the graph until enough rows pass the filter (bounded by
`hnsw.max_scan_tuples`). It works, at six to eight times the latency. And the last row is the punchline I like best: for a selective filter, the
plain B-tree on the filter column plus an exact distance sort over the 1,000 matching rows is as fast as the broken default and exactly
right. The newest index type is not automatically the right one. The profile tells you which one is, and the planner's choice between them
depends on statistics you should check with `EXPLAIN` instead of trusting. Partial HNSW indexes per filter value or partitioning by tenant are
further options when the filter values are few and stable.

### Memory is the capacity that matters

`scripts/53_vector_footprint.sh` builds two more indexes on the same column, as expression indexes: half precision (`halfvec`, 2 bytes per
dimension) and binary quantization (1 bit per dimension, with the real vectors used to re-rank the candidates):

| index | size | recall@10 at `ef_search = 40` |
|---|---|---|
| `vector` (float4) | 195 MB | 0.968 |
| `halfvec` (float2) | 112 MB | 0.980 |
| `bit` + re-rank of 40 candidates | 33 MB | 0.270 |

Half precision nearly halves the part that must stay in memory at no measurable recall cost on this data. Binary quantization shrinks it to a
sixth and, with too few candidates, gives you a fast random number generator. With more candidates (and `ef_search` raised to match, otherwise
the index stops at `ef_search` rows) it recovers: 0.75 with 200 candidates at about 1.6 ms per query, 0.996 with 1,000 candidates at about 8 ms.
Synthetic data is unkind to binary quantization; real embeddings usually do better. That is exactly why you measure it on yours.

### Where the time of an AI request goes

Now apply the profile to a whole RAG request, from the user's question to the answer on the screen. The following is an *illustration*, not a
measurement, but the shape is what I see in real traces:

| step | typical share of response time |
|---|---|
| embed the question (call to an embedding model) | 2 – 10% |
| vector search + metadata filter in PostgreSQL | 0.5 – 3% |
| fetch the chunks, re-rank | 2 – 10% |
| LLM generation | 80 – 95% |

Amdahl's law, Millsap's favourite: improvement is proportional to how much the experience uses the thing you improve. Making the vector search
twice as fast saves 0.5 to 1.5% of this user's wait. Migrating to a dedicated vector database to make it ten times faster saves at most 3%,
and adds a second system, a synchronisation pipeline and a consistency problem between the embeddings and the rows they describe. For many
RAG systems the database is not the bottleneck, and the honest recommendation is to keep the vectors next to the data in PostgreSQL and spend
the effort on the LLM side (streaming, caching, smaller models for easier questions).

There are two exceptions, and both are old friends from this post:

- **Agents multiply call counts.** An agent that plans, retrieves, reflects and retrieves again issues dozens of queries per user question,
  often one at a time, from a framework that opens a connection per tool call. That is N+1 with an LLM in the loop, and the latency table of the
  round-trip demo applies to it unchanged. Batch the retrievals, pool the connections, cache the embeddings.
- **Embedding pipelines are bulk loads.** Re-embedding a corpus after a model change writes every vector again and rebuilds every ANN index:
  hours of `maintenance_work_mem`-bound, CPU-bound work and a lot of WAL. That is a capacity-planning task with a load profile, best scheduled
  like the "2 p.m. backup" in Millsap's examples: not during the peak.

## GPUs and databases: what the invoice says

The newest question: will PostgreSQL run on GPUs, and should it? GPUs are already how embeddings are made and how the dedicated vector
libraries (FAISS, NVIDIA cuVS with its CAGRA graph index) build and search indexes. In PostgreSQL there are early projects such as
[pg_cuvs](https://github.com/pg-cuvs/pg_cuvs), which builds a CAGRA graph on the GPU and can export it as a regular pgvector HNSW index that
is then served on the CPU. That split, build on the GPU, query on the CPU, is a pattern several database engines with vector search already use.

The best data I know on the question comes from a group at ETH Zürich ([*To GPU or Not to GPU: Vector Search in Relational Engines*, May
2026](https://arxiv.org/abs/2605.15957)). They extended TPC-H with real review and image embeddings, wrote queries that combine joins and
aggregates with vector search, used PostgreSQL with pgvector as one baseline, and ran everything on CPUs, GPUs and hybrids over PCIe 5.0 and
NVLink. Their findings read like a Method R case study:

- **Data movement is the line item at the top of the invoice.** With today's indexes, which store the embeddings inside the index, moving the
  index to the GPU took over 95% of the query time on most queries. Even with NVLink, running the vector search on the GPU did not pay off
  unless the index already lived in GPU memory.
- **The relational part gains more than the vector part.** In their analytical queries the joins, filters and aggregations around the vector
  search were often far more expensive than the search itself, and they were also what the GPU accelerated most. Profile first, and the
  "obvious" GPU candidate turns out to be the smaller line.
- **Fix the call count, not the bandwidth.** Their improvement was structural: separate the small graph or centroids from the large
  embeddings, move only the small part, and let the GPU fetch just the embeddings it needs. That is eliminating calls, again.

Two more Millsap lenses on GPUs:

- **GPUs like deterministic arrivals; users are random.** A GPU is efficient on large batches: one big matrix multiplication instead of many
  small ones. Interactive queries arrive randomly and one at a time. Batching them means making the first user wait for the last one, which is
  queueing delay you introduced on purpose. That is fine for a nightly re-embedding job and questionable for a search box with a p99 target.
- **Parallelism only helps with spare capacity.** Millsap's warning about parallel query applies to any accelerator: it shortens one
  experience by using more resources at once; on a busy system it is just a faster way to add load.

So my expectation for the next years, as an opinion and not a forecast: GPUs will show up next to PostgreSQL first where the work is bulk and
batchable (embedding generation, index builds, large analytical scans), and in the query path only where the profile shows the data already
sits where the GPU is. The question to ask a vendor is the same as for any other upgrade: *which line of my profile does this make shorter,
and by how much?* If the answer is a peak TFLOPS number, you were handed a surrogate measure.

## For the three people in the room

**For the DBA.**
- Install the toolbox before you need it: `pg_stat_statements`, `pg_wait_sampling`, `pg_stat_kcache`, `auto_explain`, sensible logging,
  `track_io_timing = on` (check the cost with `pg_test_timing`; on modern hardware it is tens of nanoseconds), and snapshots in a repository
  (`pg_profile`, pgwatch, your platform's tooling).
- Sort by total time, read buffers as call counts, and check that your profile adds up to what the user experienced. When it does not, the
  missing time is outside the database, and that is a finding too.
- Size against the knee and a percentile, not against an average utilization.

**For the developer.**
- You own the call count. Count the statements per request, fetch sets, keep connections and transactions short, tag your queries.
- Performance is a feature (Millsap: it has to be designed, built, tested and supported). An application that is easy to measure in
  production is one that is easy to fix in production.
- For vector search: measure recall with your embeddings, test with your real filters, and look at the number of rows you got back.

**For the decision maker.**
- Ask for a problem statement in Millsap's two parts: the current state and the goal state, as response time percentiles of named tasks, plus
  what you are willing to pay for the difference. "The system is slow" and "CPU must stay below 80%" are not problem statements.
- Ask for the profile before the purchase order. Hardware, a new database product and a GPU are all "upgrade the hardware" in Method R: the
  last step, after the calls are necessary and running at hardware speed.
- For AI: the database is usually a small line on the invoice of a RAG request. Keeping vectors next to the data in PostgreSQL is often the
  cheaper architecture; a dedicated vector store or a GPU has to win a measured share of *your* response time to be worth a second system.

## Questions I keep getting

**Is pg_stat_statements enough?** It is the minimum, and it is a statement-level invoice of the server. It has no percentiles, no wait
breakdown and no view of time outside the server. Combine it with wait sampling and client-side timing.

**Do the extensions slow PostgreSQL down?** Measurably, slightly. Millsap quotes Tom Kyte's answer about Oracle's instrumentation: its
overhead is "negative ten percent or less", because what the vendor learned from it made the product faster. The same is true for your own
system: the cost of instrumentation is a few percent; the cost of guessing is the project.

**When should I move vectors out of PostgreSQL?** When the profile of the experiences you care about shows the vector search as a large line
that PostgreSQL cannot shorten: index memory you cannot afford, filtered queries you cannot make both fast and correct, or ingest rates the
index maintenance cannot follow. Tens of millions of vectors are fine on a well-sized PostgreSQL; the threshold is a measurement, not a number
from a blog post. Including this one.

**Is HNSW always better than IVFFlat?** It has better recall per millisecond for most workloads and copes with changing data, at the price of
slower builds and more memory. IVFFlat builds fast and is small, but needs data before you build it and degrades as the data drifts. And, as
the filter demo shows, sometimes the B-tree wins.

## The two-minute version

- Performance is an attribute of an experience, not of a system. Name the task, measure its response time, state the goal as percentiles.
- A profile is an invoice: call count times latency per line, adding up to the response time. Fix the top line, predict the gain before you
  fix it, and check that the profile actually adds up; in the demo 90% of a transaction was invisible to the server.
- The fastest call is no call: an index turned 16,600 buffer visits into 14, one set-based query turned 130 ms into 2.6 ms.
- Load adds queueing and coherency delay; size against the knee and a percentile, and cap active connections near the cores.
- For vector search, recall is part of performance: a filtered HNSW query can return 0.3 of 10 rows without an error. Measure recall, rows,
  and memory, not only milliseconds.
- GPUs, vector databases and bigger instances are all "upgrade the hardware": the last step of Method R, after the profile says so.

## References

- Cary Millsap, *Thinking Clearly about Performance*, chapter 1 of *The Method R Guide to Mastering Oracle Trace Data*, 2nd edition (2016);
  [PDF from Method R](https://method-r.com/wp-content/uploads/2018/07/TCAP-from-MOTD2.pdf). First published 2010 in ACM Queue and Communications of the ACM.
- Cary Millsap, Jeff Holt, *Optimizing Oracle Performance*, O'Reilly 2003 (Method R).
- Dirk Krautschick, *Pro-active performance analysis in PostgreSQL*, Prague PostgreSQL Developer Day 2022,
  [slides](https://archive.p2d2.cz/files/20220602_dkrautschick_PragDevDay_Performance.pdf).
- Dirk Krautschick, *Sustainable Database Performance Profiling in PostgreSQL*, PG Day Paris 2024,
  [slides](https://www.postgresql.eu/events/pgdayparis2024/sessions/session/5067/slides/482/20240314_dkrautschick_PGdayParis_SustainableDatabasePerformanceProfilingInPostgreSQL.pdf).
- Mageirakos, André, Kabić, Wu, Chronis, Alonso, *To GPU or Not to GPU: Vector Search in Relational Engines*, arXiv:2605.15957, May 2026.
- Neil J. Gunther, *Guerrilla Capacity Planning* (Universal Scalability Law).
- Tools: [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html),
  [auto_explain](https://www.postgresql.org/docs/current/auto-explain.html),
  [pg_wait_sampling](https://github.com/postgrespro/pg_wait_sampling), [pg_stat_kcache](https://github.com/powa-team/pg_stat_kcache),
  [pg_profile](https://github.com/zubkov-andrei/pg_profile), [pgBadger](https://pgbadger.darold.net/),
  [pgvector](https://github.com/pgvector/pgvector), [pg_cuvs](https://github.com/pg-cuvs/pg_cuvs).
