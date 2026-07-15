"""Pool = TRUE summaries (large cluster).

Figure 1 (pool_true_summary.png): GET vs SET (singlelog) throughput.
Figure 2 (pool_true_set_variants.png): SET variants comparison
    (singlelog, singlelog - 0% replica reads, mlogx8).
All data is for Pool = TRUE only, so that qualifier is omitted from labels.
Pool = TRUE config: Instances 250, Workers 16000, Connections 32000.
"""
import numpy as np
import matplotlib.pyplot as plt

batches = [64, 256, 1024, 4096]
systems = ["Garnet", "Valkey"]
vallens = [8, 100]

CONFIG = "Worker Pool = TRUE  |  Instances 250, Workers 16000, Connections 32000"

# Pool = TRUE throughput in Kops/sec.
data = {
    "Garnet": {
        "GET": {8: [849806.90, 1808601.90, 2850508.00, 4158201.80],
                100: [692743.60, 992639.80, 1198472.30, 1202047.40]},
        "SET (singlelog)": {8: [363126.90, 508029.40, 1298600.50, 644975.80],
                            100: [280190.40, 516025.30, 780204.30, 549646.50]},
        "SET (singlelog) - 0% replica reads": {8: [334365.70, 311212.10, 555374.10, 583480.70],
                                               100: [192800.70, 296966.70, 299419.20, 340710.20]},
        "SET (mlogx8)": {8: [174023.70, 295279.60, 599972.30, 687137.50],
                         100: [146587.60, 300698.30, 534060.40, 604071.90]},
    },
    "Valkey": {
        "GET": {8: [203440.70, 281310.30, 256209.50, 205481.00],
                100: [144843.30, 306520.70, 203769.40, 171773.40]},
        "SET (singlelog)": {8: [63764.40, 70135.50, 65745.20, 64040.40],
                            100: [75330.20, 73100.90, 57343.00, 43524.20]},
        "SET (singlelog) - 0% replica reads": {8: [43537.60, 48804.70, 47470.50, 57014.10],
                                               100: [43083.80, 44160.80, 36258.50, 39928.20]},
        # Valkey has no mlogx8 measurement under Pool = TRUE.
    },
}


def grouped_bars(fig_name, title, ops, colors):
    fig, axes = plt.subplots(2, 2, figsize=(14, 9), sharex=True)
    x = np.arange(len(batches))
    n = len(ops)
    w = 0.8 / n
    for r, vl in enumerate(vallens):
        for c, sys in enumerate(systems):
            ax = axes[r][c]
            present = [op for op in ops if op in data[sys]]
            for i, op in enumerate(present):
                offset = (i - (len(present) - 1) / 2) * w
                vals = [v / 1000.0 for v in data[sys][op][vl]]  # -> Mops/sec
                bars = ax.bar(x + offset, vals, w, label=op, color=colors[op])
                for b, v in zip(bars, vals):
                    ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.2f}",
                            ha="center", va="bottom", fontsize=6)
            ax.set_title(f"{sys}  |  value length = {vl} B", fontsize=11)
            ax.set_xticks(x)
            ax.set_xticklabels(batches)
            ax.grid(axis="y", ls="--", alpha=0.4)
            if c == 0:
                ax.set_ylabel("Throughput (Mops/sec)")
            if r == 1:
                ax.set_xlabel("Batch size")
    handles = [plt.Rectangle((0, 0), 1, 1, color=colors[op]) for op in ops]
    fig.legend(handles, ops, loc="upper center", ncol=len(ops), fontsize=10,
               bbox_to_anchor=(0.5, 0.965))
    fig.suptitle(f"{title}\n{CONFIG}", fontsize=14, y=1.02)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    fig.savefig(fig_name, dpi=150, bbox_inches="tight")
    print(f"Saved {fig_name}")


# Relabel the raw data keys with replica-read annotations for the legends.
RELABEL = {
    "SET (singlelog)": "SET (singlelog, 50% replica read)",
    "SET (singlelog) - 0% replica reads": "SET (singlelog, 0% replica read)",
    "SET (mlogx8)": "SET (mlogx8, 0% replica read)",
}
for sys in data:
    for old, new in RELABEL.items():
        if old in data[sys]:
            data[sys][new] = data[sys].pop(old)

# Figure 1: GET only, Garnet vs Valkey
def get_systems_compare(fig_name):
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    x = np.arange(len(batches))
    w = 0.38
    colors = {"Garnet": "#4C72B0", "Valkey": "#55A868"}
    for c, vl in enumerate(vallens):
        ax = axes[c]
        for i, sys in enumerate(systems):
            vals = [v / 1000.0 for v in data[sys]["GET"][vl]]  # -> Mops/sec
            bars = ax.bar(x + (i - 0.5) * w, vals, w, label=sys, color=colors[sys])
            for b, v in zip(bars, vals):
                ax.text(b.get_x() + b.get_width() / 2, v, f"{v:.2f}",
                        ha="center", va="bottom", fontsize=8)
        ax.set_title(f"GET  |  value length = {vl} B", fontsize=12)
        ax.set_yscale("log")
        ax.set_xticks(x)
        ax.set_xticklabels(batches)
        ax.grid(axis="y", ls="--", alpha=0.4, which="both")
        ax.set_xlabel("Batch size")
        if c == 0:
            ax.set_ylabel("Throughput (Mops/sec, log scale)")
    handles = [plt.Rectangle((0, 0), 1, 1, color=colors[s]) for s in systems]
    fig.legend(handles, systems, loc="upper center", ncol=2, fontsize=11,
               bbox_to_anchor=(0.5, 0.965))
    fig.suptitle(f"GET Throughput: Garnet vs Valkey (Large Cluster)\n{CONFIG}",
                 fontsize=14, y=1.04)
    fig.tight_layout(rect=[0, 0, 1, 0.92])
    fig.savefig(fig_name, dpi=150, bbox_inches="tight")
    print(f"Saved {fig_name}")


get_systems_compare("pool_true_summary.png")

# Figure 2: SET variants (mlogx8 is 0% replica read)
grouped_bars(
    "pool_true_set_variants.png",
    "SET Variants Throughput (Large Cluster)",
    ["SET (singlelog, 50% replica read)",
     "SET (singlelog, 0% replica read)",
     "SET (mlogx8, 0% replica read)"],
    {"SET (singlelog, 50% replica read)": "#C44E52",
     "SET (singlelog, 0% replica read)": "#DD8452",
     "SET (mlogx8, 0% replica read)": "#55A868"},
)
