# Latte Alternator driver benchmarks

Compare three **Latte** Alternator drivers on a **3-node Scylla** cluster with Alternator enabled. Each `run` phase exercises a uniform workload (`performance.rn`) and a matching hot-partition workload (`hot_partition.rn`).

## Drivers

| Tool | Image | Routing |
|------|-------|---------|
| `latte` | `latte-alternator` | Baseline (`develop` branch) |
| `latte-new-rr` | `latte-alternator-new` | Round-robin |
| `latte-new-affinity` | `latte-alternator-new` | `--key-route-affinity` (mode from read/update mix) |

Tool order alternates by repetition to reduce ordering bias. Hot phases use a separate order (`benchmark-hot-common.sh`).

## Quick start

Both orchestrators share the same commands. Use `local-benchmark.sh` for Docker on your machine, or `aws-benchmark.sh` for EC2.

```bash
./local-benchmark.sh build       # or ./aws-benchmark.sh build
./local-benchmark.sh provision
./local-benchmark.sh run smoke   # also runs smoke-hot
./local-benchmark.sh run latency # also runs latency-hot
./local-benchmark.sh run throughput # also runs throughput-hot
./local-benchmark.sh report
./local-benchmark.sh teardown
```

**Prerequisites**

- **Local:** Docker, Python 3
- **AWS:** AWS CLI, SSH, Docker (to build loader images), EC2 key pair (`KEY_NAME`, default `latte-bench-key`)

## What each run does

Every `run {smoke|latency|throughput}` executes two sub-phases:

1. **Uniform** — `performance.rn`, 50% GET / 50% UPDATE, uniform keys
2. **Hot** — `*-hot`, `hot_partition.rn`, 99% traffic to hot keys, 30% read / 70% update

Hot keyspace sizing: hot items ≈ 10% of `ROW_COUNT`, spread across `HOT_PARTITIONS` (default 32). See `compute_hot_keyspace_params` in `benchmark-hot-common.sh`.

### Phase settings

| | smoke | latency | throughput (uniform) | throughput-hot |
|---|-------|---------|----------------------|----------------|
| **Purpose** | Sanity check | Rate-limited compare | Saturated compare | Hot-key saturation |
| **Local duration** | 10s | 30s (+10s warmup) | 30s (+10s warmup) | 120s (+30s warmup) |
| **AWS duration** | 60s | 120s (+30s warmup) | 120s (+30s warmup) | 120s (+30s warmup) |
| **Local rate** | 500 ops/s | 500 ops/s | unlimited | unlimited |
| **AWS rate** | 5000 ops/s | 5000 ops/s | unlimited | unlimited |
| **Local inflight** | 16 | 32 | 64, 128 | 128, 256 |
| **AWS inflight** | 32 | 32 | 128, 256 | 128, 256 |
| **Local rows** | 10k | 100k | 100k | 100k |
| **AWS rows** | 100k | 1M | 1M | 1M |
| **Reps** | 2 / 1 | 2 / 2 | 2 / 2 | 2 / 2 |

Reps and row counts are **local / AWS**. Smoke-hot and latency-hot reuse the uniform timing above; only throughput-hot differs (last column). AWS hot phases pin `HOT_PARTITIONS=32`; locally they are derived from `ROW_COUNT`.

## Results

Output goes to `benchmark-results-local/` (local) or `benchmark-results/` (AWS):

```
<phase>/
  summary.csv
  <tool>/inflight=<N>/rep<R>/
    latte_1.json
    latte_1.log
    workload_params.txt      # hot phases only
    docker_stats.log
    scylla_prometheus.log
```

`report` prints all `*/summary.csv` tables. To inspect one run:

```bash
python3 analyze_latte_results.py benchmark-results-local/smoke/latte/inflight=16/rep1
python3 analyze_scylla_metrics.py benchmark-results-local/smoke/latte/inflight=16/rep1/scylla_prometheus.log
```

## Configuration

| Variable | Default | Notes |
|----------|---------|-------|
| `SCYLLA_NODES` | `3` | Cluster size |
| `SCYLLA_IMAGE` | Scylla nightly `2026.1.0-dev-...` | |
| `ALTERNATOR_WRITE_ISOLATION` | `only_rmw_uses_lwt` | |
| `LATTE_THREADS_HINT` | `8` | threads = min(inflight, hint) |
| `HOT_TRAFFIC_RATIO` | `0.99` | Hot phases only |
| `HOT_COOLDOWN_SEC` | `15` | Pause between hot tool runs |
| `RESULTS_DIR` | `benchmark-results-local` or `benchmark-results` | |

Local-only: `SCYLLA_CPUS` (default `2`), `NETWORK_NAME` (default `latte-net`).

AWS-only: `REGION` (`eu-central-1`), `SCYLLA_INSTANCE_TYPE` (`i3.2xlarge`), `LOADER_INSTANCE_TYPE` (`c5.4xlarge`), `KEY_NAME` / `KEY_FILE`, `BENCH_TAG` (`latte-bench-active`).

Run `./local-benchmark.sh` or `./aws-benchmark.sh` with no arguments for full usage.

## Repository layout

| Path | Role |
|------|------|
| `local-benchmark.sh` / `aws-benchmark.sh` | Orchestration |
| `benchmark-hot-common.sh` | Shared hot-phase helpers |
| `run-latte-benchmark.sh` | Loader container entrypoint |
| `performance.rn` / `hot_partition.rn` | Workload definitions |
| `analyze_latte_results.py` / `analyze_scylla_metrics.py` | Result parsers |
| `Dockerfile.latte` / `Dockerfile.latte-new` | Driver images |
