"""Summary graph comparing the Pool option (TRUE vs FALSE) from results.txt.

Focuses on GET throughput (Kops/sec), the metric common to both Garnet and
Valkey under both pool settings. Produces a 2x2 grouped bar chart:
    rows    = value length (8, 100 bytes)
    columns = system (Garnet, Valkey)
    x-axis  = batch size, bars grouped by Pool TRUE vs Pool FALSE.
"""
import numpy as np
import matplotlib.pyplot as plt

batches = [64, 256, 1024, 4096]

# GET throughput in Kops/sec: data[system][pool][vallen] = [b64, b256, b1024, b4096]
data = {
    "Garnet": {
        "Pool TRUE": {8: [849806.90, 1808601.90, 2850508.00, 4158201.80],
                      100: [692743.60, 992639.80, 1198472.30, 1202047.40]},
        "Pool FALSE": {8: [2018391.50, 4308267.00, 6216495.10, 8673690.00],
                       100: [1326370.70, 1907062.70, 2016449.40, 2041419.10]},
    },
    "Valkey": {
        "Pool TRUE": {8: [203440.70, 281310.30, 256209.50, 205481.00],
                      100: [144843.30, 306520.70, 203769.40, 171773.40]},
        "Pool FALSE": {8: [429358.80, 892702.00, 1367059.70, 1661024.90],
                       100: [399656.10, 752576.50, 1067487.20, 1209536.40]},
    },
}

systems = ["Garnet", "Valkey"]
vallens = [8, 100]
colors = {"Pool TRUE": "#4C72B0", "Pool FALSE": "#DD8452"}

fig, axes = plt.subplots(2, 2, figsize=(13, 9), sharex=True)
x = np.arange(len(batches))
w = 0.38

for r, vl in enumerate(vallens):
    for c, sys in enumerate(systems):
        ax = axes[r][c]
        for i, pool in enumerate(["Pool TRUE", "Pool FALSE"]):
            vals = [v / 1000.0 for v in data[sys][pool][vl]]  # -> Mops/sec
            bars = ax.bar(x + (i - 0.5) * w, vals, w, label=pool,
                          color=colors[pool])
            for b, v in zip(bars, vals):
                ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.1f}",
                        ha="center", va="bottom", fontsize=7)
        ax.set_title(f"{sys}  |  GET  |  value length = {vl} B", fontsize=11)
        ax.set_xticks(x)
        ax.set_xticklabels(batches)
        ax.grid(axis="y", ls="--", alpha=0.4)
        if c == 0:
            ax.set_ylabel("Throughput (Mops/sec)")
        if r == 1:
            ax.set_xlabel("Batch size")

handles, labels = axes[0][0].get_legend_handles_labels()
fig.legend(handles, labels, loc="upper center", ncol=2, fontsize=11,
           bbox_to_anchor=(0.5, 0.98))
fig.suptitle("Pool Option Comparison - GET Throughput (Large Cluster, 250 instances)",
             fontsize=14, y=1.0)
fig.tight_layout(rect=[0, 0, 1, 0.95])
out = "pool_summary.png"
fig.savefig(out, dpi=150, bbox_inches="tight")
print(f"Saved {out}")
