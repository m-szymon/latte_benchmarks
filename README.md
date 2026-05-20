## AWS Verification Benchmarks (`aws-benchmark.sh`)

The `aws-benchmark.sh` script automates the comparison on AWS EC2 instances, testing hypotheses about performance differences at scale.

### Usage

1. **Build and Provision**:
   ```bash
   ./aws-benchmark.sh build
   ./aws-benchmark.sh provision
   ```
2. **Run benchmarks**:
   ```bash
   ./aws-benchmark.sh run smoke
   ./aws-benchmark.sh run latency
   ./aws-benchmark.sh run throughput
   ```
3. **Report and Teardown**:
   ```bash
   ./aws-benchmark.sh report
   ./aws-benchmark.sh teardown
   ```

### Configuration

Environment variables can be used to customize the AWS run:
- `REGION`: AWS region (default: `eu-central-1`)
- `SCYLLA_INSTANCE_TYPE`: Instance type for Scylla (default: `i3.2xlarge`)
- `LOADER_INSTANCE_TYPE`: Instance type for loaders (default: `c5.4xlarge`)

## Local Verification Benchmarks (`local-benchmark.sh`)

The `local-benchmark.sh` script automates a full comparison between Latte and YCSB using local Docker containers. It sets up a 3-node Scylla cluster and runs various benchmark scenarios.

### Usage

1. **Build images**:
   ```bash
   ./local-benchmark.sh build
   ```
2. **Provision Scylla cluster**:
   ```bash
   ./local-benchmark.sh provision
   ```
3. **Run benchmarks**:
   - `smoke`: Quick sanity check.
     ```bash
     ./local-benchmark.sh run smoke
     ```
   - `latency`: Rate-limited comparison.
     ```bash
     ./local-benchmark.sh run latency
     ```
   - `throughput`: Saturated comparison.
     ```bash
     ./local-benchmark.sh run throughput
     ```
4. **Generate report**:
   ```bash
   ./local-benchmark.sh report
   ```
5. **Teardown**:
   ```bash
   ./local-benchmark.sh teardown
   ```
