"""Analyze per-VM Kops/sec variance from a benchmark results directory.

For each VM log, extract the per-second ClusterBench Kops/sec samples and compute
mean, std, min, max, and coefficient of variation (CV% = std/mean*100).
"""
import glob
import os
import re
import statistics
import sys

results_dir = sys.argv[1] if len(sys.argv) > 1 else "."

# Matches the 3rd numeric column (Kops/sec) on ClusterBench data rows.
row_re = re.compile(
    r"\|ClusterBench\|\s+[\d,]+\s+\|\s+[\d,]+\s+\|\s+([\d,]+\.\d+)\s+\|")
name_re = re.compile(r"(vm\d+)-([a-z0-9]+client\d*)-")

rows = []
for path in sorted(glob.glob(os.path.join(results_dir, "*.log"))):
    fname = os.path.basename(path)
    m = name_re.search(fname)
    vm, group = (m.group(1), m.group(2)) if m else (fname, "?")
    kops = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            mm = row_re.search(line)
            if mm:
                kops.append(float(mm.group(1).replace(",", "")))
    if not kops:
        rows.append((group, vm, 0, None, None, None, None, None))
        continue
    mean = statistics.mean(kops)
    std = statistics.stdev(kops) if len(kops) > 1 else 0.0
    cv = (std / mean * 100) if mean else 0.0
    rows.append((group, vm, len(kops), mean, std, min(kops), max(kops), cv))

# Sort by group, then by CV descending (most variable first).
rows.sort(key=lambda r: (r[0], -(r[7] if r[7] is not None else -1)))

hdr = f"{'group':<16}{'vm':<7}{'n':>3}  {'mean':>9}  {'std':>9}  {'min':>9}  {'max':>9}  {'CV%':>7}"
print(hdr)
print("-" * len(hdr))
for g, vm, n, mean, std, lo, hi, cv in rows:
    if mean is None:
        print(f"{g:<16}{vm:<7}{n:>3}  {'NO DATA':>9}")
        continue
    print(f"{g:<16}{vm:<7}{n:>3}  {mean:>9.1f}  {std:>9.1f}  {lo:>9.1f}  {hi:>9.1f}  {cv:>7.1f}")

# Per-group aggregate summary.
print("\n=== Per-group summary (across VMs) ===")
gh = f"{'group':<16}{'VMs':>4}  {'sumKops':>11}  {'avgMean':>9}  {'avgCV%':>7}  {'minVM':>9}  {'maxVM':>9}  {'spread%':>8}"
print(gh)
print("-" * len(gh))
groups = {}
for g, vm, n, mean, std, lo, hi, cv in rows:
    if mean is None:
        continue
    groups.setdefault(g, []).append((mean, cv))
for g in sorted(groups):
    means = [x[0] for x in groups[g]]
    cvs = [x[1] for x in groups[g]]
    total = sum(means)
    avg_mean = statistics.mean(means)
    avg_cv = statistics.mean(cvs)
    lo_vm, hi_vm = min(means), max(means)
    spread = (hi_vm - lo_vm) / avg_mean * 100 if avg_mean else 0
    print(f"{g:<16}{len(means):>4}  {total:>11,.0f}  {avg_mean:>9.1f}  "
          f"{avg_cv:>7.1f}  {lo_vm:>9.1f}  {hi_vm:>9.1f}  {spread:>8.1f}")
