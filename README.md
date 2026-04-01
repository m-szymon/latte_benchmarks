# Alternator Benchmarks (Docker)

This directory is intended to be run via Docker images built from:

- `Dockerfile.latte` → entrypoint runs `run-latte-benchmark.sh` (Latte benchmark)
- `Dockerfile.ycsb` → entrypoint runs `run-ycsb-benchmark.sh` (YCSB benchmark)

Both containers:

- verify endpoint reachability
- create schema and preload data with `latte-alternator`
- execute one benchmark tool
- write artifacts into `OUTDIR`
- print parsed summary via `analyze_*.py`

## Prerequisites

- Docker installed
- Reachable Alternator endpoint (default `http://172.17.0.2:8000`)
- Use `--net host` if benchmark containers must reach host-network services

## Build images

From this directory:

```bash
docker build -t latte-alternator -f Dockerfile.latte .
docker build -t ycsb-alternator -f Dockerfile.ycsb .
```

## Run Latte benchmark container

```bash
docker run --rm latte-alternator
```

Example with parameter overrides:

```bash
mkdir -p output/latte
docker run --rm --net host \
  -v "$PWD/output/latte:/output" \
  -e OUTDIR=/output \
  -e ALT_ENDPOINT=http://127.0.0.1:8000 \
  -e TABLE=latte_perf \
  -e THREADS=16 \
  -e CONCURRENCY=64 \
  -e ROW_COUNT=100000 \
  -e REQUEST_COUNT=500000 \
  -e FIELDCOUNT=10 \
  -e FIELDLENGTH=512 \
  -e READ_PROPORTION=0.7 \
  -e UPDATE_PROPORTION=0.3 \
  -e RATE=20000 \
  -e LATTE_WORKLOAD=performance.rn \
  latte-alternator
```

### Latte container parameters

- `ALT_ENDPOINT`: Alternator endpoint
- `TABLE`: table name
- `THREADS`: Latte threads (`-t`)
- `CONCURRENCY`: Latte `-p` value
- `ROW_COUNT`: preload item count
- `REQUEST_COUNT`: operation count (`-d`)
- `FIELDCOUNT`: number of fields per item
- `FIELDLENGTH`: field size
- `READ_PROPORTION`: Latte `get` proportion (default `0.5`)
- `UPDATE_PROPORTION`: Latte `update` proportion (default `0.5`)
- `RATE`: optional target throughput (`-r`), unset = max throughput
- `LATTE_WORKLOAD`: workload file (default `performance.rn`)
- `OUTDIR`: output directory inside container

Outputs:

- `latte_load.log`
- `latte_1.log`
- `latte_1.json`

## Run YCSB benchmark container

```bash
docker run --rm ycsb-alternator
```

Example with parameter overrides:

```bash
mkdir -p output/ycsb
docker run --rm --net host \
  -v "$PWD/output/ycsb:/output" \
  -e OUTDIR=/output \
  -e ALT_ENDPOINT=http://127.0.0.1:8000 \
  -e TABLE=latte_perf \
  -e YCSB_THREADS=48 \
  -e ROW_COUNT=100000 \
  -e REQUEST_COUNT=500000 \
  -e FIELDCOUNT=10 \
  -e FIELDLENGTH=512 \
  -e READ_PROPORTION=0.7 \
  -e UPDATE_PROPORTION=0.3 \
  -e RATE=20000 \
  -e LATTE_WORKLOAD=performance.rn \
  ycsb-alternator
```

### YCSB container parameters

- `ALT_ENDPOINT`: Alternator endpoint
- `TABLE`: table name
- `YCSB_THREADS`: YCSB thread count
- `ROW_COUNT`: preload item count
- `REQUEST_COUNT`: operation count
- `FIELDCOUNT`: number of fields per item
- `FIELDLENGTH`: field size
- `READ_PROPORTION`: YCSB `readproportion` (default `0.5`)
- `UPDATE_PROPORTION`: YCSB `updateproportion` (default `0.5`)
- `RATE`: optional YCSB `-target` throughput value
- `LATTE_WORKLOAD`: preload workload file (default `performance.rn`)
- `OUTDIR`: output directory inside container

Outputs:

- `latte_load.log`
- `ycsb_1.log`


