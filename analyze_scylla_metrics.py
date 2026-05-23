#!/usr/bin/env python3
"""
analyze_scylla_metrics.py — Parse Prometheus scrape log(s) from Scylla node(s).

Input: one or more files with repeated blocks separated by "---TIMESTAMP <epoch>---"
lines. Local combined logs may also contain "---NODE <port>---" markers between
per-node metric blocks within a snapshot.

Output: JSON dict to stdout with aggregated server-side metrics:
  ops_per_sec           — Total Alternator request rate across nodes
  p99_ms                — Max p99 Alternator latency across nodes
  reactor_util_pct      — Max reactor utilization across all shards/nodes
  max_node_ops_per_sec  — Highest per-node Alternator ops/sec
  ops_imbalance_ratio   — max_node_ops / avg_node_ops (1.0 = perfectly balanced)

Usage:
  python3 analyze_scylla_metrics.py <scylla_prometheus.log> [scylla2_prometheus.log ...]
  python3 analyze_scylla_metrics.py --dry-run <scylla_prometheus.log>
"""
import json
import re
import sys


def parse_snapshots(path):
    """Parse prometheus log into list of (timestamp, lines) snapshots."""
    snapshots = []
    current_ts = None
    current_lines = []

    with open(path, 'rb') as f:
        text = f.read().replace(b'\x00', b'').decode('utf-8', errors='replace')
    for line in text.splitlines():
        m = re.match(r'^---TIMESTAMP (\d+)---', line)
        if m:
            if current_ts is not None and current_lines:
                snapshots.append((int(current_ts), current_lines))
            current_ts = m.group(1)
            current_lines = []
        elif current_ts is not None and not line.startswith('#') and line.strip():
            current_lines.append(line.strip())

    if current_ts is not None and current_lines:
        snapshots.append((int(current_ts), current_lines))

    return snapshots


def split_node_blocks(lines):
    """Split snapshot lines into per-node blocks using ---NODE markers."""
    blocks = []
    current = []

    for line in lines:
        if re.match(r'^---NODE \d+---', line):
            if current:
                blocks.append(current)
            current = []
        else:
            current.append(line)

    if current:
        blocks.append(current)

    if not blocks and lines:
        blocks = [lines]

    return blocks


def extract_metric(lines, pattern):
    """Extract all values matching a metric name pattern. Returns list of (labels, value)."""
    results = []
    for line in lines:
        m = re.match(r'^(' + pattern + r'(?:\{[^}]*\})?)\s+([0-9eE.+\-]+)', line)
        if m:
            try:
                results.append((m.group(1), float(m.group(2))))
            except ValueError:
                pass
    return results


def counter_ops_per_sec(first_lines, last_lines, dt):
    op_counter_patterns = [
        r'scylla_alternator_operation_total',
        r'scylla_alternator_operation',
        r'scylla_transport_requests_served',
    ]

    for pat in op_counter_patterns:
        first_vals = extract_metric(first_lines, pat)
        last_vals = extract_metric(last_lines, pat)
        if first_vals and last_vals:
            first_total = sum(v for _, v in first_vals)
            last_total = sum(v for _, v in last_vals)
            delta = last_total - first_total
            if delta > 0 and dt > 0:
                return delta / dt
    return 0.0


def max_p99_ms(lines):
    p99_patterns = [
        r'scylla_alternator_op_latency_summary',
        r'scylla_alternator_operation_latency_summary',
    ]

    for pat in p99_patterns:
        p99_values = []
        for line in lines:
            if re.match(pat + r'\{', line) and 'quantile="0.99' in line:
                m_val = re.search(r'\s+([0-9eE.+\-]+)$', line)
                if m_val:
                    try:
                        val_us = float(m_val.group(1))
                        if val_us > 0:
                            p99_values.append(val_us)
                    except ValueError:
                        pass
        if p99_values:
            return max(p99_values) / 1000.0
    return 0.0


def max_reactor_util(lines):
    vals = extract_metric(lines, r'scylla_reactor_utilization')
    if vals:
        return max(v for _, v in vals)
    return 0.0


def analyze_node_series(snapshots):
    """Return per-node ops/sec series from snapshots with optional node blocks."""
    if len(snapshots) < 2:
        return []

    first_ts, first_lines = snapshots[0]
    last_ts, last_lines = snapshots[-1]
    dt = last_ts - first_ts
    if dt <= 0:
        return []

    first_blocks = split_node_blocks(first_lines)
    last_blocks = split_node_blocks(last_lines)
    node_count = max(len(first_blocks), len(last_blocks))

    per_node_ops = []
    for idx in range(node_count):
        first_block = first_blocks[idx] if idx < len(first_blocks) else first_blocks[-1]
        last_block = last_blocks[idx] if idx < len(last_blocks) else last_blocks[-1]
        per_node_ops.append(counter_ops_per_sec(first_block, last_block, dt))

    return per_node_ops


def analyze_file(path, dry_run=False):
    snapshots = parse_snapshots(path)
    if not snapshots:
        return None

    if dry_run:
        _, lines = snapshots[-1]
        names = set()
        for line in lines:
            m = re.match(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)', line)
            if m:
                names.add(m.group(1))
        for name in sorted(names):
            tag = ""
            for kw in ['alternator', 'reactor', 'cache', 'storage_proxy', 'transport']:
                if kw in name:
                    tag = "  <-- relevant"
                    break
            print(f"{name}{tag}")
        return None

    per_node_ops = analyze_node_series(snapshots)
    _, last_lines = snapshots[-1]
    last_blocks = split_node_blocks(last_lines)

    return {
        "per_node_ops_per_sec": per_node_ops,
        "p99_ms": max(max_p99_ms(block) for block in last_blocks) if last_blocks else 0.0,
        "reactor_util_pct": max(max_reactor_util(block) for block in last_blocks) if last_blocks else 0.0,
        "snapshots": len(snapshots),
    }


def aggregate_results(file_results):
    all_node_ops = []
    p99_values = []
    reactor_values = []
    snapshots = 0

    for result in file_results:
        if not result:
            continue
        all_node_ops.extend(result["per_node_ops_per_sec"])
        if result["p99_ms"] > 0:
            p99_values.append(result["p99_ms"])
        if result["reactor_util_pct"] > 0:
            reactor_values.append(result["reactor_util_pct"])
        snapshots = max(snapshots, result["snapshots"])

    total_ops = sum(all_node_ops)
    max_node_ops = max(all_node_ops) if all_node_ops else 0.0
    avg_node_ops = total_ops / len(all_node_ops) if all_node_ops else 0.0
    imbalance = (max_node_ops / avg_node_ops) if avg_node_ops > 0 else 0.0

    return {
        "ops_per_sec": f"{total_ops:.1f}",
        "p99_ms": f"{max(p99_values):.3f}" if p99_values else "0",
        "reactor_util_pct": f"{max(reactor_values):.1f}" if reactor_values else "0",
        "max_node_ops_per_sec": f"{max_node_ops:.1f}",
        "ops_imbalance_ratio": f"{imbalance:.3f}",
        "snapshots": snapshots,
    }


def analyze(paths, dry_run=False):
    if dry_run:
        analyze_file(paths[0], dry_run=True)
        return

    file_results = [analyze_file(path) for path in paths]
    if not any(file_results):
        print(json.dumps({"error": "no snapshots found"}))
        return

    print(json.dumps(aggregate_results(file_results)))


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--dry-run']
    dry_run = '--dry-run' in sys.argv

    if not args:
        print("Usage: analyze_scylla_metrics.py [--dry-run] <scylla_prometheus.log> [...]")
        sys.exit(1)

    analyze(args, dry_run=dry_run)
