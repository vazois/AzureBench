import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

batches = [64, 256, 1024, 4096]

# Kops/sec. data[system][pool][op][valuelen] = [b64, b256, b1024, b4096]
data = {
    "Garnet": {
        "Pool":   {
            "GET":       {8:[849806.9,1808601.9,2850508.0,4158201.8], 100:[692743.6,992639.8,1198472.3,1202047.4]},
            "SET":       {8:[363126.9,508029.4,1298600.5,644975.8],   100:[280190.4,516025.3,780204.3,549646.5]},
            "SET0rep":   {8:[334365.7,311212.1,555374.1,583480.7],    100:[192800.7,296966.7,299419.2,340710.2]},
            "SETmlogx8": {8:[174023.7,295279.6,599972.3,687137.5],    100:[146587.6,300698.3,534060.4,604071.9]},
        },
        "NoPool": {
            "GET":       {8:[2018391.5,4308267.0,6216495.1,8673690.0], 100:[1326370.7,1907062.7,2016449.4,2041419.1]},
            "SET":       {8:[1075695.8,1426677.5,1797209.4,4137555.6], 100:[965052.2,1229100.9,1422336.2,2366457.5]},
            "SET0rep":   {8:[562148.5,749797.8,1110913.1,1813301.9],   100:[540607.3,780338.5,971853.0,1363145.5]},
            "SETmlogx8": {8:[711619.1,981613.6,1372895.5,2491411.6],   100:[599232.8,835537.2,1120715.0,1581248.78]},
        },
    },
    "Valkey": {
        "Pool":   {
            "GET":     {8:[203440.7,281310.3,256209.5,205481.0], 100:[144843.3,306520.7,203769.4,171773.4]},
            "SET":     {8:[63764.4,70135.5,65745.2,64040.4],     100:[75330.2,73100.9,57343.0,43524.2]},
            "SET0rep": {8:[43537.6,48804.7,47470.5,57014.1],     100:[43083.8,44160.8,36258.5,39928.2]},
        },
        "NoPool": {
            "GET":     {8:[429358.8,892702.0,1367059.7,1661024.9], 100:[399656.1,752576.5,1067487.2,1209536.4]},
            "SET":     {8:[228006.9,465309.7,747606.8,840607.0],   100:[244863.6,372141.7,459808.8,577008.0]},
            "SET0rep": {8:[155568.9,283259.4,373957.5,463441.6],   100:[138400.2,196392.3,224502.6,225620.8]},
        },
    },
}

M = 1e6  # convert Kops/sec -> Mops/sec for readability

styles = {
    ("Garnet","NoPool"): dict(color="#1a7f37", marker="o", ls="-",  lw=2.2),
    ("Garnet","Pool"):   dict(color="#4ac26b", marker="o", ls="--", lw=1.8),
    ("Valkey","NoPool"): dict(color="#8250df", marker="s", ls="-",  lw=2.2),
    ("Valkey","Pool"):   dict(color="#bc8cff", marker="s", ls="--", lw=1.8),
}
label = {("Garnet","NoPool"):"Garnet (no-pool, 37k)",
         ("Garnet","Pool"):"Garnet (pool, 16k)",
         ("Valkey","NoPool"):"Valkey (no-pool, 37k)",
         ("Valkey","Pool"):"Valkey (pool, 16k)"}

fig = plt.figure(figsize=(15, 11))
gs = fig.add_gridspec(3, 2, height_ratios=[1,1,1.05], hspace=0.42, wspace=0.22)

panels = [
    ("GET", 8,   "GET  \u00b7  value=8 B"),
    ("GET", 100, "GET  \u00b7  value=100 B"),
    ("SET", 8,   "SET (single-log)  \u00b7  value=8 B"),
    ("SET", 100, "SET (single-log)  \u00b7  value=100 B"),
]

x = np.arange(len(batches))
for i,(op,vl,title) in enumerate(panels):
    ax = fig.add_subplot(gs[i//2, i%2])
    for sys in ("Garnet","Valkey"):
        for pool in ("NoPool","Pool"):
            y = [v/M for v in data[sys][pool][op][vl]]
            ax.plot(x, y, label=label[(sys,pool)], **styles[(sys,pool)])
    ax.set_title(title, fontweight="bold")
    ax.set_xticks(x); ax.set_xticklabels(batches)
    ax.set_xlabel("Batch (pipeline) size")
    ax.set_ylabel("Throughput (Mops/sec)")
    ax.grid(True, alpha=0.3)
    if i == 0: ax.legend(fontsize=8, loc="upper left")

# Bottom: peak throughput bar chart (best batch, value=8) per system/config/op
axb = fig.add_subplot(gs[2, :])
ops = ["GET","SET","SET0rep","SETmlogx8"]
op_lbl = ["GET","SET\n(singlelog)","SET\n(0% rep-read)","SET\n(mlog x8)"]
configs = [("Garnet","NoPool"),("Garnet","Pool"),("Valkey","NoPool"),("Valkey","Pool")]
bw = 0.2
xb = np.arange(len(ops))
for j,(sys,pool) in enumerate(configs):
    peaks = []
    for op in ops:
        d = data[sys][pool].get(op)
        peaks.append(max(d[8])/M if d else 0)
    bars = axb.bar(xb + (j-1.5)*bw, peaks, bw, label=label[(sys,pool)],
                   color=styles[(sys,pool)]["color"])
    for b,p in zip(bars,peaks):
        if p>0:
            axb.text(b.get_x()+b.get_width()/2, p, f"{p:.1f}", ha="center", va="bottom", fontsize=7)
axb.set_title("Peak throughput per operation  (value=8 B, best batch size)", fontweight="bold")
axb.set_xticks(xb); axb.set_xticklabels(op_lbl)
axb.set_ylabel("Peak throughput (Mops/sec)")
axb.grid(True, axis="y", alpha=0.3)
axb.legend(fontsize=8, ncol=4, loc="upper right")

fig.suptitle("Large Cluster \u2014 Garnet vs Valkey  (250 clients, ~1M keys, 37 shards)\n"
             "Garnet: 37 primary + 37 replica  |  Valkey: 74 primary + 74 replica",
             fontsize=13, fontweight="bold")
out = r"C:\Dev\Github\AzureBench\benchmark\results-summary.png"
fig.savefig(out, dpi=130, bbox_inches="tight")
print("saved", out)

# print headline peak numbers
print("\nPeak Mops/sec (value=8, best batch):")
for op in ops:
    row=[op]
    for sys,pool in configs:
        d=data[sys][pool].get(op)
        row.append(f"{max(d[8])/M:5.2f}" if d else "  -  ")
    print("  {:10s} Gnp={} Gp={} Vnp={} Vp={}".format(*row))
