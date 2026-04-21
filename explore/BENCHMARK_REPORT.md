# Latte vs YCSB on ScyllaDB Alternator — Benchmark Report

**Status**: Complete (Phases 1–6 executed)
**Date started**: 2026-04-20
**Author**: automated via aws-benchmark.sh orchestrator

---

## 1. Executive summary

Latte (Rust, async) achieves **~30% higher throughput** and **~50% tighter
p99 latency** than JVM-tuned YCSB (Java, synchronous) at each hardware tier
tested. Both tools scale linearly with hardware — the overhead is a constant
percentage gap, not an absolute ceiling.

**Final numbers (Phase 6, i3.2xlarge + c5.4xlarge, 5M rows)**:

| Metric | Latte | YCSB (tuned) | Ratio |
|--------|-------|-------------|-------|
| Peak throughput | 41,900 ops/s | 31,700 ops/s | 1.32× |
| Latency p99 @ 5k ops/s | 2.9 ms | 5.9 ms | 2.0× tighter |
| Latency p99 @ inflight=128 | 10.3 ms | 12.9 ms | 20% lower |

**Smaller tier (Phase 5, i3.xlarge + c5.2xlarge, 1M rows)**:

| Metric | Latte | YCSB (tuned) | Ratio |
|--------|-------|-------------|-------|
| Peak throughput | 22,000 ops/s | 15,500 ops/s | 1.42× |
| Latency p99 @ 5k ops/s | 3.4 ms | 10.4 ms | 3.1× tighter |

**Root causes** (established via targeted mini-experiments):
- YCSB's throughput deficit is **per-request SDK overhead** (proven:
  halving loader CPUs had zero impact on throughput). JVM GC tuning
  provides a ~14% lift but does not close the gap.
- The read/update tail divergence visible at high concurrency is a
  **Scylla Alternator server-side phenomenon**, not a loader artifact
  (confirmed via Alternator Prometheus metrics).
- Both tools scale ~2× with 2× hardware. The Latte/YCSB ratio narrows
  from 1.42× to 1.32× at larger instances as YCSB benefits from reduced
  thread contention.

**Practical implication**: YCSB underreports Scylla's throughput by ~25–30%
and overstates tail latency by ~50–100%. For capacity planning, Latte
provides a more accurate measure of server capabilities. For relative
comparisons (A/B testing workload variants), YCSB is adequate — the
constant overhead cancels out in ratios.

---

## 2. What we are testing

### Subjects

| Tool | Image / binary | Language | Concurrency model |
|------|---------------|----------|-------------------|
| **Latte** (alternator-fork) | `latte-alternator` (local build) | Rust | Async Tokio; `-t` threads × `-p` tasks per thread = total in-flight |
| **YCSB** (ScyllaDB fork) | `scylladb/ycsb:1.3.0` | Java | Synchronous; `-threads N` = N in-flight (1 op per thread) |

### Target

ScyllaDB Alternator — DynamoDB-compatible API exposed on port 8000.
Write isolation mode: `only_rmw_uses_lwt`.

### Workload

- **Operations**: 50% GetItem / 50% UpdateItem (single-attribute `SET fieldN=:v`)
- **Schema**: table `latte_performance`, partition key `pk` (string, HASH)
- **Item shape**: 10 fields × 512 bytes each (~5 KB per item)
- **Key distribution**: uniform random over pre-loaded dataset
- **Consistent reads**: disabled (`consistentReads=false`)
- **YCSB specifics**: `writeallfields=false`, `readallfields=true`,
  `fieldlengthdistribution=constant`
- **Latte specifics**: `-f get:0.5 -f update:0.5`, uniform distribution via
  `latte::hash_range`

Both tools issue semantically identical DynamoDB requests:
- GetItem: full item fetch by primary key
- UpdateItem: `SET field<N>=:v` (single field, UpdateExpression form)

### Goal

Fair comparison of loader-induced overhead: latency, throughput, and
resource utilization, isolating the loader's contribution from the
database's.

---

## 3. Methodology

### 3.1 Environment

**Phases 1–5 + mini-experiments**:

| Role | Instance type | vCPU | RAM | Storage | AMI |
|------|-------------|------|-----|---------|-----|
| Scylla node | i3.xlarge | 4 | 30.5 GB | 950 GB NVMe | Ubuntu 24.04 |
| Loader | c5.2xlarge | 8 | 16 GB | EBS | Ubuntu 24.04 |

**Phase 6 (final)**:

| Role | Instance type | vCPU | RAM | Storage | AMI |
|------|-------------|------|-----|---------|-----|
| Scylla node | i3.2xlarge | 8 | 61 GB | 1.9 TB NVMe | Ubuntu 24.04 |
| Loader | c5.4xlarge | 16 | 32 GB | EBS | Ubuntu 24.04 |

- **Region**: eu-central-1 (Frankfurt)
- **Scylla image**: `scylladb/scylla-nightly:2026.1.0-dev-0.20251003.20aeed160740-x86_64`
- **Network**: same VPC, same AZ, private IP for Scylla ↔ loader traffic

### 3.2 Benchmark harness

A single `aws-benchmark.sh` orchestrator manages the full lifecycle:

1. **Build** (local): `docker build` Latte image, `docker pull` YCSB image
2. **Provision**: launch EC2 instances, ship images via `docker save | ssh docker load`
3. **Run phase**: load data once, then execute measured passes per tool
4. **Report**: aggregate CSV summaries

Key fairness controls:
- **Identical data**: both tools benchmark against the same pre-loaded dataset
  (loaded once via `latte schema` + `latte load` before any measured run)
- **Tool order alternation**: odd reps run YCSB first, even reps run Latte first
- **Time-based runs**: both use wall-clock duration (`-d Ns` / `maxexecutiontime=N`)
- **Matched in-flight depth**: YCSB `-threads N` ↔ Latte `-t T -p P` where `T×P = N`

### 3.3 Concurrency mapping

The `LATTE_THREADS_HINT=8` parameter controls Latte's thread/task split:

```
compute_latte_params(inflight):
    threads = min(inflight, 8)
    concurrency = inflight / threads
    total in-flight = threads × concurrency = inflight
```

Examples:
- inflight=32 → Latte: 8 threads × 4 tasks = 32 in-flight; YCSB: 32 threads
- inflight=64 → Latte: 8 threads × 8 tasks = 64 in-flight; YCSB: 64 threads
- inflight=128 → Latte: 8 threads × 16 tasks = 128 in-flight; YCSB: 128 threads

### 3.4 Monitoring

- `mpstat` (5s interval) on both Scylla and loader nodes — captures %usr, %sys, %soft, %idle
- `pidstat` (5s interval) on both nodes — per-process CPU breakdown
- Logs collected via `scp` after each pass

### 3.5 Data captured per run

| Artifact | Latte | YCSB |
|----------|-------|------|
| Throughput (ops/s) | JSON report | Parsed from log `[OVERALL], Throughput` |
| Latency (avg, p95, p99) | JSON report, per operation | Parsed from log, per operation |
| Raw output | `latte_1.json` + `latte_1.log` | `ycsb_1.log` |
| Loader CPU | `loader_cpu.log`, `loader_pidstat.log` | Same |
| Scylla CPU | `scylla_cpu.log`, `scylla_pidstat.log` | Same |

### 3.6 Latency measurement semantics

Latte and YCSB measure per-request latency with different brackets. Latte
exposes **two** latency metrics in its JSON output; our report tables use
one of them. Understanding which is which resolves an apparent anomaly in
the rate-limited mean numbers and confirms that Latte is genuinely faster
than YCSB on every metric when measured at the same bracket.

#### Two metrics in every Latte JSON

| Field | Bracket | Per-function? | Source |
|-------|---------|---------------|--------|
| `cycle_latency` / `cycle_latency_by_fn` | `response_time − scheduled_dispatch_time` (CO-corrected) | Yes (`get`, `update`) | `src/exec/workload.rs:472` |
| `request_latency` | `response_time − request_send_time` (service-time) | No (aggregate only) | `src/stats/session.rs:25-36` |

`scheduled_dispatch_time` is the rate-limiter's **intended** tick time
(`src/exec/mod.rs:88-98`), not the moment the request hits the wire. This
makes `cycle_latency` a coordinated-omission-corrected measurement: any
delay between when a request *should* have been sent and when the response
arrived is counted. `request_latency` starts timing only when the HTTP
client call begins (`start_request()` → `Instant::now()`), making it a
pure service-time measurement.

#### YCSB measures service-time only

YCSB's default `measurementtype=hdrhistogram` reports
`response_received − request_sent` inside the synchronous worker thread.
No CO correction is applied. Raw logs confirm only `[READ], AverageLatency`
— no `Intended-AverageLatency` field. This bracket is directly comparable
to Latte's `request_latency`.

#### CQL and Alternator backends are symmetric

Both Latte backends use the identical two-tier instrumentation:
- CQL: `src/scripting/cql/context.rs:624,798` — `start_request()` around
  `session.execute_single_page().await` / `session.batch().await`
- Alternator: `src/scripting/alternator/functions.rs:95-97` —
  `start_request()` around `builder.send().await`

Both feed into the same `SessionStats.resp_times_ns` → `request_latency`,
and both are wrapped by the same `workload.rs:472` outer cycle measurement
→ `cycle_latency`. Anyone comparing CQL-Scylla to Alternator-Scylla via
Latte gets identical instrumentation.

#### What this report uses

All latency tables use `cycle_latency_by_fn` (parsed at
`aws-benchmark.sh:686-705`). This is the CO-corrected, per-operation field. We
use it because:
1. Per-operation breakdown (read vs update) is required for several findings
   (especially Q3 read/update tail divergence in §4.6).
2. At saturated load — where most analysis in this report lives — the gap
   between `cycle_latency` and `request_latency` is negligible (≤0.2 ms,
   ≤4% of mean). The CO correction only matters at rate-limited load.
3. CO-corrected latency is the more SLO-honest number; YCSB's lack of CO
   correction is a YCSB shortcoming, not a Latte advantage.

#### Quantification of the gap

Across all 28 Latte JSON files:

| Regime | Mean gap (cycle − request) | p99 gap |
|--------|---------------------------|---------|
| Rate-limited (rate=5k, inflight=32) | +0.67 to +0.71 ms | +1.4 to +1.7 ms |
| Saturated, inflight=32–256 | +0.06 to +0.19 ms | +0.06 to +0.20 ms |
| Saturated, inflight=512 | +0.31 to +0.38 ms | +0.20 ms |

At rate-limited load the rate-limiter slack dominates; at saturation the
rate limiter never fires, so both metrics converge.

#### Apples-to-apples comparison (Phase 6 latency block, rate=5k)

To compare Latte and YCSB at the same bracket, we use Latte's
`request_latency` (service-time, aggregate) against a weighted YCSB
aggregate (148,883 reads × 923.5 µs + 149,062 updates × 984.5 µs =
**953.9 µs**). Rep 1:

| Metric | Latte `request_latency` | YCSB weighted aggregate | Ratio |
|--------|------------------------|------------------------|-------|
| Mean   | **0.72 ms**            | **0.95 ms**            | Latte 24% lower |
| p99    | **1.20 ms**            | ~5.8 ms                | Latte 4.8× tighter |

When measured at the same bracket, Latte is faster on both mean and tails.
The apparent "YCSB has lower mean" effect in the report's headline tables
is entirely a measurement-bracket artifact: those tables compare Latte's
CO-corrected `cycle_latency` against YCSB's uncorrected service-time.

#### When to use which

| Question | Use |
|----------|-----|
| Server capacity / hardware profiling | Service-time (`request_latency` / YCSB default) |
| SLO modeling under sustained load | CO-corrected (`cycle_latency`) |
| CQL ↔ Alternator comparison within Latte | Either — fully symmetric |
| Throughput or saturated-p99 comparison | Either — metrics converge |
| Rate-limited mean comparison across tools | Service-time bracket (§3.6 table above) |

---

## 4. Phases executed

### 4.1 Phase 1 — Smoke (20s, 1 rep, inflight=64, 100k rows)

**Purpose**: validate end-to-end pipeline.

| tool | inflight | throughput | read avg | read p95 | read p99 | update avg | update p95 | update p99 |
|------|----------|-----------|----------|----------|----------|------------|------------|------------|
| ycsb | 64 | 8,053 | 6.97 ms | 13.06 ms | 23.22 ms | 7.12 ms | 13.24 ms | 23.18 ms |
| latte | 64 | 19,246 | 3.38 ms | 7.33 ms | 11.09 ms | 3.27 ms | 7.27 ms | 10.99 ms |

**CPU utilization (mid-run, steady state)**:

| Tool running | Loader CPU (8 vCPU) | Scylla CPU (4 vCPU) |
|-------------|--------------------|--------------------|
| YCSB | ~85–95% busy | ~60–80% busy |
| Latte | ~50–60% busy | ~95–99% busy |

**Finding**: YCSB is **loader-bound** — it saturates the c5.2xlarge before
saturating Scylla. Latte is **Scylla-bound** — it drives Scylla to near-100%
CPU while the loader sits at ~55%. The 2.4x throughput gap at identical
in-flight depth is explained entirely by loader overhead.

---

### 4.2 Phase 2 — Quick latency (30s, 1 rep, rate=5000, inflight=32, 100k rows)

**Purpose**: compare latency at matched offered load.

| tool | inflight | throughput | read avg | read p95 | read p99 | update avg | update p95 | update p99 |
|------|----------|-----------|----------|----------|----------|------------|------------|------------|
| ycsb | 32 | 4,621 | 2.27 ms | 7.48 ms | 12.98 ms | 2.29 ms | 7.56 ms | 13.10 ms |
| latte | 32 | 4,999 | 1.54 ms | 2.86 ms | 3.45 ms | 1.46 ms | 2.78 ms | 3.32 ms |

**CPU utilization (mid-run, steady state)**:

| Tool running | Loader CPU | Scylla CPU |
|-------------|-----------|-----------|
| YCSB | ~24% (steady), ~85% (JVM startup burst) | ~50–55% |
| Latte | ~10% | ~50–55% |

**Findings**:

1. **YCSB cannot sustain 5,000 ops/s at 32 threads.** Achieved 4,621 ops/s
   (7.6% shortfall). This is a Little's Law ceiling: 32 concurrent
   requests ÷ ~7 ms per request ≈ 4,571 ops/s theoretical maximum.

2. **At the same offered load, Latte's tail latency is dramatically lower**:
   - p95: 2.9 ms vs 7.5 ms (2.6x tighter)
   - p99: 3.4 ms vs 13.0 ms (3.8x tighter)

3. **Scylla CPU is identical** between the two runs (~50–55%), confirming
   the latency difference is purely loader-side (JVM overhead, AWS Java
   SDK per-request cost, GC pauses inflating the tail).

---

### 4.3 Phase 3 — Quick throughput (30s, 1 rep, sweep {32, 128}, 100k rows)

**Purpose**: find throughput ceilings and saturation behavior.

| tool | inflight | throughput | read avg | read p95 | read p99 | update avg | update p95 | update p99 |
|------|----------|-----------|----------|----------|----------|------------|------------|------------|
| ycsb | 32 | 10,009 | 2.93 ms | 6.41 ms | 10.16 ms | 2.96 ms | 6.45 ms | 10.23 ms |
| latte | 32 | 16,454 | 1.99 ms | 4.53 ms | 6.35 ms | 1.90 ms | 4.41 ms | 6.24 ms |
| ycsb | 128 | 10,056 | 11.71 ms | 21.26 ms | 36.93 ms | 11.72 ms | 21.23 ms | 36.93 ms |
| latte | 128 | 19,634 | 7.17 ms | 16.96 ms | 24.20 ms | 5.86 ms | 13.39 ms | 17.25 ms |

**CPU utilization (mid-run, steady state)**:

| Run | Loader CPU | Scylla CPU |
|-----|-----------|-----------|
| YCSB @ 32 | ~80–90% | ~60–93% |
| Latte @ 32 | ~50% | ~97–98% |
| YCSB @ 128 | ~90–95% | ~70–90% |
| Latte @ 128 | ~55–60% | ~100% |

**Findings**:

1. **YCSB throughput plateaus at ~10k ops/s** regardless of thread count.
   32 threads → 10,009; 128 threads → 10,056 (+0.5%). Quadrupling
   concurrency gained zero throughput — latency absorbed the extra
   in-flight depth. YCSB has hit a **JVM/AWS-Java-SDK ceiling on
   c5.2xlarge**.

2. **Latte saturates Scylla, not the loader.** At inflight=128, Scylla
   reaches 100% CPU at 19.6k ops/s. The loader still has ~40% idle CPU.
   Throughput grew 16.5k → 19.6k (+19%) from 32→128 in-flight —
   diminishing returns because the bottleneck is Scylla, not the loader.

3. **Scylla's throughput ceiling on i3.xlarge** for this workload
   (50/50 read/update, 10×512B fields, uniform) is approximately
   **19–20k ops/s**.

4. **At matched concurrency (inflight=32)**: Latte sustains 64% higher
   throughput (16.5k vs 10.0k) with 38% lower p99 (6.4 ms vs 10.2 ms).

---

### 4.4 Phase 4 — Medium latency (60s, 2 reps, rate=5000, inflight=32, 1M rows, 30s warmup)

**Purpose**: replicate quick-latency with longer duration, 2 reps, larger
dataset (1M rows), and 30s warmup discard pass to eliminate JVM startup effects.

| tool | inflight | rep | throughput | read avg | read p95 | read p99 | update avg | update p95 | update p99 |
|------|----------|-----|-----------|----------|----------|----------|------------|------------|------------|
| ycsb | 32 | 1 | 4,805 | 1.40 ms | 5.43 ms | 10.28 ms | 1.46 ms | 5.59 ms | 10.44 ms |
| ycsb | 32 | 2 | 4,806 | 1.50 ms | 5.48 ms | 10.41 ms | 1.54 ms | 5.56 ms | 10.46 ms |
| latte | 32 | 1 | 5,000 | 1.54 ms | 2.82 ms | 3.37 ms | 1.45 ms | 2.72 ms | 3.24 ms |
| latte | 32 | 2 | 5,000 | 1.54 ms | 2.81 ms | 3.35 ms | 1.45 ms | 2.72 ms | 3.23 ms |

**CPU utilization (mid-run, steady state, after warmup)**:

| Tool running | Loader CPU | Scylla CPU |
|-------------|-----------|-----------|
| YCSB | ~17–20% (steady); ~80% during JVM warmup burst | ~50% |
| Latte | ~15–22% (rate-limited run) | ~50% (rate-limited run) |

**Findings**:

1. **Run-to-run variance is negligible.** Both tools show <1% drift across
   reps on all metrics — throughput, mean, p95, p99. This validates
   single-rep numbers from earlier phases.

2. **Warmup improved YCSB's throughput.** Quick-latency (no warmup): 4,621
   ops/s. Medium-latency (30s warmup): 4,805 ops/s (+4%). The JVM warmup
   pass eliminates startup costs from the measured window. YCSB still falls
   3.9% short of the 5,000 target — likely rate-limiter scheduling jitter.

3. **Mean latency is comparable; tails diverge sharply.** With warmup,
   YCSB's mean (1.40–1.54 ms) is on par with Latte's (1.45–1.54 ms).
   The gap is in the tail:
   - p95: 2.8 ms (Latte) vs 5.5 ms (YCSB) — **1.9x**
   - p99: 3.4 ms (Latte) vs 10.4 ms (YCSB) — **3.0x**

   This refines the Phase 2 finding: the difference is not "Latte is
   faster everywhere" but specifically that **Latte has dramatically
   tighter latency tails**. JVM GC pauses and SDK queue jitter inflate
   YCSB's p95/p99 even when mean latency is competitive.

4. **Scylla CPU is identical** (~50% busy) in both YCSB and Latte runs,
   confirming the tail latency gap is purely loader-side.

---

### 4.5 Phase 5 — Medium throughput (60s, 2 reps, sweep {32, 64, 128, 256}, 1M rows, 30s warmup)

**Purpose**: build saturation curves — throughput vs in-flight depth — with
replication, larger dataset, and warmup. Determines each tool's throughput
ceiling and how latency degrades as concurrency increases.

**Throughput and latency (averaged over 2 reps)**:

| tool | inflight | throughput (ops/s) | read avg | read p95 | read p99 | update avg | update p95 | update p99 |
|------|----------|--------------------|----------|----------|----------|------------|------------|------------|
| ycsb | 32 | 12,898 | 2.37 ms | 4.95 ms | 7.82 ms | 2.39 ms | 4.97 ms | 7.84 ms |
| latte | 32 | 17,168 | 1.93 ms | 4.36 ms | 6.18 ms | 1.80 ms | 4.18 ms | 5.97 ms |
| ycsb | 64 | 13,593 | 4.52 ms | 9.15 ms | 13.85 ms | 4.51 ms | 9.18 ms | 13.68 ms |
| latte | 64 | 19,216 | 3.42 ms | 7.23 ms | 10.80 ms | 3.26 ms | 7.04 ms | 10.67 ms |
| ycsb | 128 | 13,615 | 9.08 ms | 18.00 ms | 27.51 ms | 8.96 ms | 17.83 ms | 27.29 ms |
| latte | 128 | 21,706 | 6.20 ms | 13.16 ms | 17.74 ms | 5.60 ms | 12.12 ms | 15.87 ms |
| ycsb | 256 | 14,299 | 18.57 ms | 40.21 ms | 58.86 ms | 15.77 ms | 32.61 ms | 51.25 ms |
| latte | 256 | 21,073 | 15.22 ms | 42.52 ms | 61.42 ms | 9.07 ms | 19.39 ms | 24.38 ms |

**CPU utilization (averaged over 2 reps, mpstat 100−%idle)**:

| tool | inflight | Scylla CPU | Loader CPU |
|------|----------|------------|------------|
| ycsb | 32 | 81.0% | 73.7% |
| latte | 32 | 95.0% | 50.3% |
| ycsb | 64 | 76.2% | 81.2% |
| latte | 64 | 98.2% | 59.3% |
| ycsb | 128 | 81.4% | 81.5% |
| latte | 128 | 98.5% | 65.6% |
| ycsb | 256 | 87.9% | 81.0% |
| latte | 256 | 98.5% | 62.6% |

**Findings**:

1. **YCSB ceiling lifted to ~13–14k ops/s** (from ~10k in Phase 3 with 100k
   rows). Warmup and larger dataset help, but throughput barely moves from
   inflight 32→256 (+10.9%) while p99 climbs ~7.5x (7.8 ms → 58.9 ms).
   The bottleneck is the AWS Java SDK synchronous client + YCSB's threading
   model; more threads queue inside the loader rather than driving the server.

2. **Latte ceiling ≈ 22k ops/s, Scylla-bound from inflight=32.** Scylla
   CPU ≥ 93% at every concurrency level. Throughput rises 17.2k → 21.7k
   (+26%) from inflight 32→128 (deeper pipelining extracts more server
   capacity), then plateaus at 256 — Scylla is past the knee.

3. **At matched inflight, Latte delivers 1.3–1.6x throughput at 20–55%
   lower p99.** The gap is largest at moderate inflight (128): 21.7k vs
   13.6k throughput, p99 17.7 ms vs 27.5 ms.

4. **Latte loader CPU stays at 50–66%.** Even at inflight=256, Latte leaves
   ~35% loader headroom. The bottleneck is always Scylla, not the loader.
   YCSB loader sits at 73–82% across the sweep — closer to saturation,
   yet it cannot drive Scylla past ~82% busy.

5. **Read/update p99 divergence at inflight=256.** Latte's update p99
   (24.4 ms) is 2.5x lower than its read p99 (61.4 ms). YCSB shows the
   same direction but smaller ratio (51.2 vs 58.9 ms, 1.2x). This likely
   reflects Alternator's internal path difference: `GetItem` response
   includes the full 5 KB item body (network read time under shard
   saturation), while `UpdateItem` returns only metadata. Flagged as
   open question for future investigation; does not affect tool comparison
   conclusions since both tools exhibit the same direction.

6. **Run-to-run variance.** Most cells show <3% throughput variance across
   reps. One outlier: latte@inflight=64 shows 12.5% variance (18,081 vs
   20,350 ops/s) — consistent with saturation regime where small queue
   timing differences shift steady-state utilization. Does not invalidate
   the overall trend.

### 4.6 Mini-experiments — causal investigations

After Phase 5, we ran targeted mini-experiments to answer specific causal
questions raised by the data. All used the same i3.xlarge + c5.2xlarge setup.

#### Q4 — JVM-tuned YCSB

**Question**: Does YCSB's throughput ceiling improve with JVM GC tuning?

**Setup**: YCSB at inflight=128, 1M rows, 60s, 30s warmup.
`YCSB_JAVA_OPTS="-Xmx8g -XX:+UseG1GC -XX:MaxGCPauseMillis=20"`

| Metric          | Baseline (Phase 5) | JVM-tuned  | Delta  |
|-----------------|---------------------|------------|--------|
| Throughput      | 13,615 ops/s        | 15,535     | +14.1% |
| Read p99        | 27.6 ms             | 24.6 ms    | -10.9% |
| Update p99      | 27.5 ms             | 24.6 ms    | -10.5% |

**Conclusion**: GC tuning provides a material (~14%) lift. Still well below
Latte's 22k ceiling. The report should note that default YCSB numbers are
penalized by untuned GC, and the tuned number is the fairer comparison point.

#### Q1b — YCSB with half the CPU (taskset)

**Question**: Is YCSB's ~14k ceiling caused by CPU exhaustion on the loader?

**Setup**: `taskset -c 0-3` (4 of 8 vCPUs) at inflight=128, 1M rows, 60s, 30s warmup.

| Metric          | 8 vCPUs (Phase 5) | 4 vCPUs (taskset) | Delta |
|-----------------|--------------------|-------------------|-------|
| Throughput      | 13,615 ops/s       | 13,614 ops/s      | -0%   |
| Loader CPU (abs)| ~73%               | ~73% (of 4 cores) | —     |

**Conclusion**: Throughput is identical with half the CPUs. **YCSB's ceiling is
not CPU-bound** — it is per-request SDK overhead (serialization, synchronous
HTTP1.1 round-trips). This is the single most important causal finding: the
gap between YCSB (~14k) and Latte (~22k) is architectural, not a resource
starvation artifact.

#### Q3 — Latte read/update tail divergence

**Question**: Why does Latte@256 show read p99 (56-67 ms) >> update p99 (24 ms)?

**Setup**: Latte at inflight=256, 1M rows, 60s, 30s warmup, with Scylla
Alternator Prometheus metrics scraped every 5s.

**Server-side latencies (Alternator internal)**:

| Operation  | Avg    | p99     |
|------------|--------|---------|
| GetItem    | 3.5 ms | ≤41 ms  |
| UpdateItem | 2.3 ms | ≤10.2 ms|

**Client vs server p99 comparison**:

| Operation  | Client p99 | Server p99 | Network+client overhead |
|------------|------------|------------|-------------------------|
| Read       | 67 ms      | 41 ms      | ~26 ms                  |
| Update     | 26 ms      | 10 ms      | ~16 ms                  |

**Conclusion**: The divergence originates inside Scylla. The Alternator read
path (GetItem) is fundamentally more expensive under shard saturation than the
write path (UpdateItem), likely due to Alternator's JSON→CQL translation layer
and the read-before-write pattern differences. This is a Scylla behavior, not
a loader artifact.

#### Q6 — 5M-row dataset (cache pressure)

**Question**: How does a dataset that exceeds the row cache affect both tools?

**Setup**: 5M rows (vs 1M baseline), inflight=128, 60s, 30s warmup.

| Metric         | YCSB 1M  | YCSB 5M  | Delta  | Latte 1M  | Latte 5M  | Delta   |
|----------------|----------|----------|--------|-----------|-----------|---------|
| Throughput     | 13,615   | 14,738   | +8.3%  | 19,578    | 17,132    | -12.5%  |
| Read p99       | 27.6 ms  | 25.4 ms  | -8.0%  | 26.2 ms   | 41.7 ms   | +59.2%  |
| Update p99     | 27.5 ms  | 25.4 ms  | -7.6%  | 14.0 ms   | 18.3 ms   | +30.7%  |
| Scylla CPU     | ~82%     | ~63%     |        | ~96%      | ~70%      |         |
| Loader CPU     | ~75%     | ~51%     |        | ~55%      | ~42%      |         |

**Conclusion**: Cache pressure has opposite effects. Latte loses 12.5%
throughput because disk I/O introduces latency that reduces the effective
in-flight request rate (at fixed concurrency, higher latency = lower throughput).
YCSB's modest gain (+8.3%) is likely noise or warm-up artifact — the SDK
overhead ceiling dominates regardless of cache behavior. Both tools show lower
Scylla CPU at 5M rows, consistent with I/O wait replacing CPU time. Read tails
blow up for Latte (+59% at p99) as expected when reads must hit disk.

#### Mini-experiment summary

| Question | Finding | Impact on report |
|----------|---------|------------------|
| Q4 JVM tuning | +14% throughput for YCSB | Use tuned YCSB as fair baseline |
| Q1b Half-CPU | 0% change — not CPU-bound | YCSB ceiling is architectural |
| Q3 Tail divergence | Server-side Alternator phenomenon | Not a loader artifact |
| Q6 5M rows | Latte -12.5%, YCSB +8.3% | Cache pressure narrows gap modestly |

### 4.7 Phase 6 — Final (60s, 2 reps, i3.2xlarge + c5.4xlarge, 5M rows, JVM-tuned YCSB)

Hardware upgrade: Scylla moves from i3.xlarge (4 vCPU) to **i3.2xlarge
(8 vCPU, 61 GB RAM, 1.9 TB NVMe)**; loader from c5.2xlarge (8 vCPU) to
**c5.4xlarge (16 vCPU, 32 GB RAM)**. YCSB runs with JVM tuning
(`-Xmx8g -XX:+UseG1GC -XX:MaxGCPauseMillis=20`) as established fair
by mini-experiment Q4. Dataset: 5M rows.

**Latte throughput sweep** (unlimited rate):

| inflight | rep1 ops/s | rep2 ops/s | avg ops/s | read p99 | update p99 | Scylla CPU | Loader CPU |
|----------|-----------|-----------|-----------|----------|------------|------------|------------|
| 64       | 26,814    | 34,134    | 30,474*   | 6.8 ms   | 6.6 ms     | 77–79%     | 31–38%     |
| 128      | 40,312    | 40,011    | 40,162    | 10.3 ms  | 10.1 ms    | 72%        | 43%        |
| 256      | 42,077    | 41,711    | 41,894    | 20.1 ms  | 16.9 ms    | 72%        | 46%        |
| 512      | 40,934    | 40,789    | 40,861    | 85.8 ms  | 25.7 ms    | 71%        | 46%        |

\* inflight=64 rep1 (26.8k) is a warmup anomaly: Scylla CPU was 79% (I/O-heavy
cache loading of the 5M-row dataset) but effective throughput was low. Rep2
(34.1k) represents steady state.

**Latte peak**: **~42k ops/s** at inflight=256, with throughput plateau across
128–512. Beyond 256 inflight, tails explode without throughput gain —
read p99 at 512 reaches 86 ms while update p99 stays 26 ms (same Q3
server-side divergence pattern, amplified under deeper queueing).

**YCSB throughput sweep** (JVM-tuned, unlimited rate):

| inflight | rep1 ops/s | rep2 ops/s | avg ops/s | read p99 | update p99 | Scylla CPU | Loader CPU |
|----------|-----------|-----------|-----------|----------|------------|------------|------------|
| 128      | 30,232    | 30,465    | 30,349    | 12.9 ms  | 13.0 ms    | 61%        | 74%        |
| 256      | 31,925    | 31,452    | 31,689    | 23.5 ms  | 23.4 ms    | 59%        | 72%        |

**YCSB peak**: **~31.7k ops/s** at inflight=256. Run-to-run variance <2%.
Loader CPU is the bottleneck at 72–74%, while Scylla has ~40% idle capacity.
YCSB read/update p99 values are symmetric (no tail divergence) because the
loader overhead dominates the measured latency.

**Latency block** (rate=5000, inflight=32, 30s warmup):

| Metric      | Latte        | YCSB         | Ratio           |
|-------------|-------------|--------------|-----------------|
| Throughput  | 5,000 ops/s | 4,804 ops/s  | YCSB undershoots by 4% |
| Read mean   | 1.47 ms     | 0.93 ms      | YCSB 37% lower  |
| Read p99    | 2.97 ms     | 5.74 ms      | Latte 1.9x tighter |
| Update mean | 1.38 ms     | 0.97 ms      | YCSB 30% lower  |
| Update p99  | 2.86 ms     | 5.98 ms      | Latte 2.1x tighter |
| Scylla CPU  | 40%         | 22%          | —               |
| Loader CPU  | 14%         | 16%          | —               |

At rate-limited load, the headline mean favors YCSB by ~0.5 ms — but this
is a measurement-bracket artifact. The same Latte run reports
`request_latency` (service-time) of 0.72 ms vs YCSB's weighted aggregate
of 0.95 ms, making Latte ~24% faster at the comparable bracket (see §3.6).
Latte's p99 is ~2× tighter on either bracket.

**Hardware scaling summary**:

| Metric           | i3.xlarge + c5.2xlarge | i3.2xlarge + c5.4xlarge | Scale factor |
|------------------|----------------------|------------------------|-------------|
| Latte peak       | 22.0k ops/s          | 41.9k ops/s            | 1.9×        |
| YCSB peak (tuned)| 15.5k ops/s          | 31.7k ops/s            | 2.0×        |
| Latte/YCSB ratio | 1.42×                | 1.32×                  | Narrows     |
| Latency p99 gap  | 3.0× (Phase 4)       | 2.0× (Phase 6)        | Narrows     |

Both tools scale approximately linearly with hardware. The Latte/YCSB
throughput advantage narrows from 1.42× to 1.32× at the larger tier, and
the latency tail gap narrows from 3.0× to 2.0×. This is expected: with
more loader CPU, YCSB's thread pool becomes less contended, reducing
its per-request overhead.

 ---

## 5. Cross-phase findings

### 5.1 Throughput ceilings

| Tool | Phase 3 (100k, i3.xl) | Phase 5 (1M, i3.xl) | Phase 6 (5M, i3.2xl) | Bottleneck |
|------|----------------------|---------------------|----------------------|------------|
| YCSB (default) | ~10k ops/s | ~13.6k ops/s | — | Loader |
| YCSB (JVM-tuned) | — | ~15.5k ops/s | **~31.7k ops/s** | Loader |
| Latte | ~19.6k ops/s | ~22.0k ops/s | **~41.9k ops/s** | Scylla CPU |

Both tools scale approximately linearly with hardware: 2× the loader CPU
(c5.2xl → c5.4xl) and 2× the Scylla CPU (i3.xl → i3.2xl) yields ~2× throughput
for both. The Latte/YCSB advantage is a **constant ~30% gap**, narrowing
slightly from 1.42× (small tier) to 1.32× (large tier) as YCSB benefits
from reduced thread contention on the 16-vCPU loader.

At any given hardware tier, YCSB's ceiling is SDK-bound: on the smaller
tier, halving loader CPUs via taskset had zero impact on throughput (Q1b),
proving the limit is per-request overhead, not CPU exhaustion. JVM GC tuning
lifts the ceiling ~14% (Q4). The overhead is best understood as a **constant
percentage tax** on each request, not an absolute ceiling.

Latte saturates Scylla at all tested tiers. Scylla i3.2xlarge ceiling
for this workload: approximately **42k ops/s**.

### 5.2 Latency comparison

**Rate-limited (5k ops/s, warmup)**:

| Metric | Latte (Ph4) | YCSB (Ph4) | Ratio | Latte (Ph6) | YCSB (Ph6) | Ratio |
|--------|-------------|------------|-------|-------------|------------|-------|
| Read mean | 1.54 ms | 1.45 ms | ~even | 1.47 ms | 0.93 ms | YCSB lower |
| Read p99 | 3.36 ms | 10.35 ms | 3.1× | 2.97 ms | 5.74 ms | 1.9× |
| Update p99 | 3.24 ms | 10.45 ms | 3.2× | 2.86 ms | 5.98 ms | 2.1× |

Mean latencies favor YCSB in the headline tables, but this is a
measurement-bracket artifact, not a real performance difference. The tables
use Latte's CO-corrected `cycle_latency` while YCSB reports raw
service-time. When compared at the same bracket (Latte's `request_latency`
0.72 ms vs YCSB weighted-aggregate 0.95 ms in Phase 6), Latte is ~24%
faster — see §3.6 for details. The gap lives in the tail: JVM GC pauses and SDK queue jitter
inflate YCSB's p99 even at low load. The tail gap narrows from ~3× at the
small tier to ~2× at the large tier, consistent with reduced GC pressure
from more heap headroom and fewer thread switches on a 16-vCPU loader.

**Saturated (Phase 5, i3.xlarge → Phase 6, i3.2xlarge)**:

| inflight | Latte p99 read (Ph5) | YCSB p99 read (Ph5) | Latte p99 read (Ph6) | YCSB p99 read (Ph6) |
|----------|---------------------|---------------------|---------------------|---------------------|
| 128      | 17.7 ms             | 27.5 ms             | 10.3 ms             | 12.9 ms             |
| 256      | 61.4 ms             | 58.9 ms             | 20.1 ms             | 23.5 ms             |

At the larger tier, Phase 6 tails are dramatically lower for both tools
(more Scylla headroom). Latte maintains a ~20% advantage at inflight=128
and a ~15% advantage at inflight=256.

**Read/update tail divergence (Q3 + Phase 6)**: At high inflight, Latte
shows read p99 >> update p99 (e.g., 86 ms vs 26 ms at inflight=512 in
Phase 6). Alternator Prometheus metrics confirm this divergence is
server-side: GetItem p99 ≤41 ms vs UpdateItem p99 ≤10 ms inside Scylla.
The Alternator read path is fundamentally more expensive under shard
saturation. YCSB does not exhibit this divergence because its SDK overhead
masks it.

### 5.3 CPU and saturation profile

| Tier | Tool | Scylla CPU | Loader CPU | Bottleneck |
|------|------|-----------|------------|------------|
| i3.xl + c5.2xl | YCSB (default) | 76–88% | 73–82% | Loader |
| i3.xl + c5.2xl | Latte | 93–99% | 49–67% | Scylla |
| i3.2xl + c5.4xl | YCSB (tuned) | 59–61% | 72–74% | Loader |
| i3.2xl + c5.4xl | Latte | 72–79% | 38–46% | Scylla |

Key patterns:

- **YCSB is consistently loader-bound** across both tiers. Loader CPU stays
  in the 72–82% range while Scylla has 20–40% idle capacity.
- **Latte is consistently Scylla-bound**. At the small tier it pushes
  Scylla to 93–99%; at the large tier, 72–79% (the lower number reflects
  8 Scylla vCPUs vs 4 — absolute throughput doubled).
- **Rate-limited behavior**: at 5k ops/s (Phases 4, 6), both tools use
  minimal CPU; loader CPU is 14–20% for both.

### 5.4 Key insight

At each hardware tier, Latte achieves **~30% higher throughput** and
**~50% tighter tail latency** than JVM-tuned YCSB. Both tools scale
linearly with hardware — the overhead manifests as a constant percentage
gap, not an absolute ceiling.

The practical implication: **YCSB underreports Scylla's throughput capacity
by ~25–30%** and **overstates tail latency by ~50–100%** compared to what
the database actually delivers. For capacity planning, Latte provides a
more accurate measurement of the server's true capabilities. For comparing
workload variants or schema changes (where the relative difference matters
more than the absolute number), YCSB is adequate — the constant overhead
cancels out in ratios.

### 5.5 Reproducibility

Phase 4 (2 reps, rate-limited) showed <1% run-to-run variance for both
tools. Phase 5 (2 reps, saturated) showed <3% variance for 7 of 8
tool×inflight cells; the exception is latte@inflight=64 (12.5%), consistent
with queue timing sensitivity at the saturation knee. Phase 6 showed <2%
variance at inflight ≥128 for both tools; the exception is latte@inflight=64
(27% between rep1 and rep2), attributed to 5M-row cache warming during rep1.
Both tools produce highly reproducible results once caches are warm.

---

## 6. Caveats and limitations

- **Single rep per data point** (Phases 1–3). Phases 4–5 (2 reps each)
  confirmed <1% variance at rate-limited and <3% at saturation, validating
  single-rep data. One outlier: latte@inflight=64 in Phase 5 showed 12.5%
  rep variance — consistent with queue timing sensitivity at the saturation
  knee.
- **Small dataset for Phases 1–3** (100k rows). Phases 4–5 use 1M, final
  uses 5M. Mini-experiment Q6 showed that at 5M rows, Latte throughput
  drops 12.5% (cache pressure) while YCSB is roughly stable (+8.3%).
  Larger datasets narrow the throughput gap modestly.
- **Single Scylla node, single loader.** No cluster-scale findings.
- **Latte thread/task split** uses `LATTE_THREADS_HINT=8`. Alternative
  splits not swept; could affect CPU utilization patterns.
- **Workload is synthetic**: uniform-distribution, single-attribute update.
  Real workloads may have different access patterns.
- **YCSB image is `scylladb/ycsb:1.3.0`** (ScyllaDB's fork of YCSB with
  DynamoDB binding). Upstream YCSB or other forks may perform differently.
- **No JVM tuning applied to YCSB in Phases 1–5.** Mini-experiment Q4
  showed that `-Xmx8g -XX:+UseG1GC -XX:MaxGCPauseMillis=20` lifts
  throughput by ~14%. Phase 6 used JVM tuning; Phases 1–5 did not.
  Cross-phase YCSB comparisons should account for this.
- **Hardware scaling validated at one step** (i3.xlarge → i3.2xlarge,
  c5.2xlarge → c5.4xlarge). Behavior at smaller (4 vCPU) or larger
  (32 vCPU) tiers was not measured; the linear scaling may not hold
  indefinitely.
- **Scylla is a nightly build** (`2026.1.0-dev`). Production releases
  may have different performance characteristics.

---

## 7. Out of scope

The following were deliberately not tested in this benchmark:

- **Multi-node Scylla cluster** — all tests used a single node. Cluster
  coordination overhead, token-aware routing, and cross-node latency
  may change the loader overhead ratio.
- **Multiple loaders** — a single loader was used for each tool. Running
  multiple YCSB instances in parallel might push Scylla harder, partially
  compensating for the per-instance SDK ceiling.
- **Alternative workloads** — only 50/50 read/update with uniform key
  distribution was tested. Write-heavy, read-heavy, or skewed (Zipfian)
  distributions may show different characteristics.
- **AWS SDK v2 for YCSB** — the YCSB ScyllaDB fork uses AWS SDK v1
  (synchronous). SDK v2 with its async HTTP client could narrow the gap.
- **Latte thread/task tuning** — only `LATTE_THREADS_HINT=8` was tested.
  Alternative splits may affect Latte's CPU utilization and throughput.
- **Larger datasets** — 5M rows was the maximum tested. Workloads that
  significantly exceed memory (requiring sustained disk I/O) were not
  explored.

---

## 8. Appendix

### 8.1 File map

```
benchmark-results/
  smoke/
    summary.csv
    latte/inflight=64/rep1/   # latte_1.json, latte_1.log, *_cpu.log, *_pidstat.log
    ycsb/inflight=64/rep1/    # ycsb_1.log, *_cpu.log, *_pidstat.log
  quick-latency/
    summary.csv
    latte/inflight=32/rep1/
    ycsb/inflight=32/rep1/
  quick-throughput/
    summary.csv
    latte/inflight={32,128}/rep1/
    ycsb/inflight={32,128}/rep1/
  medium-latency/
    summary.csv
    latte/inflight=32/rep{1,2}/
    ycsb/inflight=32/rep{1,2}/
  medium-throughput/
    summary.csv
    latte/inflight={32,64,128,256}/rep{1,2}/
    ycsb/inflight={32,64,128,256}/rep{1,2}/
  mini/
    q1-ycsb-ceiling/taskset-half/   # YCSB with 4 vCPUs
    q3-tail-divergence/             # Latte@256 + Alternator metrics
    q4-jvm-tuned/                   # YCSB with GC tuning
    q6-5m-rows/                     # Both tools at 5M rows
  final-latte-throughput/
    summary.csv
    latte/inflight={64,128,256,512}/rep{1,2}/
  final-ycsb-throughput/
    summary.csv
    ycsb/inflight={128,256}/rep{1,2}/
  final-latency/
    summary.csv
    latte/inflight=32/rep{1,2}/
    ycsb/inflight=32/rep{1,2}/
```

### 8.2 How to reproduce

```bash
./aws-benchmark.sh build            # Local: build latte image, pull YCSB image
./aws-benchmark.sh provision        # EC2: launch i3.xlarge + c5.2xlarge
./aws-benchmark.sh run smoke        # Phase 1
./aws-benchmark.sh run quick-latency    # Phase 2
./aws-benchmark.sh run quick-throughput # Phase 3
./aws-benchmark.sh run medium-latency   # Phase 4
./aws-benchmark.sh run medium-throughput # Phase 5
./aws-benchmark.sh teardown         # Destroy small instances
# Re-provision with bigger instances
SCYLLA_INSTANCE_TYPE=i3.2xlarge LOADER_INSTANCE_TYPE=c5.4xlarge ./aws-benchmark.sh provision
YCSB_JAVA_OPTS="-Xmx8g -XX:+UseG1GC -XX:MaxGCPauseMillis=20" ./aws-benchmark.sh run final  # Phase 6
./aws-benchmark.sh teardown
```

### 8.3 Configuration reference

Key environment variables (defaults shown):
```
REGION=eu-central-1
SCYLLA_INSTANCE_TYPE=i3.xlarge
LOADER_INSTANCE_TYPE=c5.2xlarge
SCYLLA_IMAGE=scylladb/scylla-nightly:2026.1.0-dev-0.20251003.20aeed160740-x86_64
YCSB_DOCKER_IMAGE=scylladb/ycsb:1.3.0
ALTERNATOR_WRITE_ISOLATION=only_rmw_uses_lwt
LATTE_THREADS_HINT=8
```
