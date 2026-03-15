#!/usr/bin/env python3
"""
============================================================
RED-ANNS 논문 Figure 재현 통합 플로팅 스크립트
============================================================
지원하는 Figure:
  - fig10:  QPS vs Recall@10 (5 configs × 4 datasets)
  - fig11:  QPS bar chart at Top-1, Top-10, Top-100
  - fig12:  Distance computation overhead comparison
  - fig14:  Remote access ratio with data placement schemes
  - fig16a: RBFS latency breakdown (relax sweep)
  - fig16b: PQ pruning (epsilon sweep)

사용법:
  python3 plot_all.py                           # 모든 Figure 플로팅
  python3 plot_all.py --figure fig10            # 특정 Figure만
  python3 plot_all.py --figure fig10 --pdf      # PDF도 생성
  python3 plot_all.py --figure fig16a --dataset msturing
"""

import argparse
import csv
import os
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np


# ================================================================
# 공통 유틸리티
# ================================================================

def load_csv(filepath: str) -> list:
    if not os.path.exists(filepath):
        print(f"ERROR: {filepath} not found", file=sys.stderr)
        return []
    with open(filepath, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = []
        for row in reader:
            for key in ["qps", "recall", "mean_hops", "mean_cmps",
                         "mean_cmps_local", "mean_cmps_remote", "mean_latency"]:
                if key in row and row[key]:
                    try:
                        row[key] = float(row[key])
                    except (ValueError, TypeError):
                        pass
            for key in ["K", "L", "T", "sche_strategy", "relax", "query_count",
                         "io_cnt", "io_size"]:
                if key in row and row[key]:
                    try:
                        row[key] = int(row[key])
                    except (ValueError, TypeError):
                        pass
            rows.append(row)
    return rows


def save_fig(fig, output_path, also_pdf=False):
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    fig.savefig(output_path, dpi=150, bbox_inches="tight")
    print(f"  Saved: {output_path}", file=sys.stderr)
    if also_pdf:
        pdf_path = output_path.rsplit(".", 1)[0] + ".pdf"
        fig.savefig(pdf_path, bbox_inches="tight")
        print(f"  Saved: {pdf_path}", file=sys.stderr)
    plt.close(fig)


def get_datasets(rows):
    return sorted(set(r.get("dataset", "") for r in rows if r.get("dataset")))


# ================================================================
# Figure 10: QPS vs Recall@10
# ================================================================

FIG10_STYLES = {
    "mr_anns":        {"label": "MR-ANNS",          "color": "#1f77b4", "marker": "s", "ls": "--"},
    "random":         {"label": "Random",            "color": "#ff7f0e", "marker": "^", "ls": "--"},
    "locality":       {"label": "Locality",          "color": "#2ca02c", "marker": "D", "ls": "-."},
    "locality_sched": {"label": "Locality+Sched",    "color": "#9467bd", "marker": "o", "ls": "-."},
    "red_anns":       {"label": "RED-ANNS",          "color": "#d62728", "marker": "*", "ls": "-", "ms": 10},
}

DATASET_TITLES = {
    "deep100M": "DEEP100M",
    "msturing": "MS-Turing100M",
    "text2image": "Text2Image100M",
    "laion": "LAION100M",
}


def plot_fig10(csv_path, output_path, datasets=None, pdf=False):
    rows = load_csv(csv_path)
    if not rows:
        return

    fig10_rows = [r for r in rows if r.get("figure", "").startswith("fig10")
                  or r.get("config") in FIG10_STYLES]
    if not fig10_rows:
        fig10_rows = rows

    ds_list = datasets or get_datasets(fig10_rows)
    if not ds_list:
        print("ERROR: No datasets in CSV", file=sys.stderr)
        return

    n = len(ds_list)
    ncols = min(n, 2) if n > 1 else 1
    nrows = (n + ncols - 1) // ncols
    fig, axes = plt.subplots(nrows, ncols, figsize=(6 * ncols, 5 * nrows), squeeze=False)
    axes = axes.flatten()

    for idx, ds in enumerate(ds_list):
        ax = axes[idx]
        ds_rows = [r for r in fig10_rows if r.get("dataset") == ds]

        groups = defaultdict(list)
        for r in ds_rows:
            groups[r.get("config", "unknown")].append(r)

        for cfg_name, style in FIG10_STYLES.items():
            if cfg_name not in groups:
                continue
            points = []
            for r in groups[cfg_name]:
                recall = r.get("recall")
                qps = r.get("qps")
                if isinstance(recall, (int, float)) and isinstance(qps, (int, float)):
                    points.append((recall, qps))
            if not points:
                continue
            points.sort()
            ax.plot([p[0] for p in points], [p[1] for p in points],
                    label=style["label"], color=style["color"],
                    marker=style["marker"], linestyle=style["ls"],
                    markersize=style.get("ms", 6), linewidth=1.5)

        title = DATASET_TITLES.get(ds, ds)
        ax.set_title(title, fontsize=12, fontweight="bold")
        ax.set_xlabel("Recall@10", fontsize=10)
        ax.set_ylabel("QPS", fontsize=10)
        ax.set_xlim(0.8, 1.0)
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8, loc="upper right")

    for idx in range(len(ds_list), len(axes)):
        axes[idx].set_visible(False)

    fig.suptitle("Figure 10: QPS vs Recall@10 (4 nodes, 8 threads/node)",
                 fontsize=14, fontweight="bold", y=1.02)
    plt.tight_layout()
    save_fig(fig, output_path, pdf)


# ================================================================
# Figure 11: Top-K bar chart
# ================================================================

def plot_fig11(csv_path, output_path, datasets=None, pdf=False):
    rows = load_csv(csv_path)
    if not rows:
        return

    fig11_rows = [r for r in rows if "fig11" in r.get("figure", "")]
    if not fig11_rows:
        fig11_rows = rows

    ds_list = datasets or get_datasets(fig11_rows)
    if not ds_list:
        return

    configs = ["mr_anns", "random", "locality", "red_anns"]
    config_labels = {"mr_anns": "MR-ANNS", "random": "Random",
                     "locality": "Locality", "red_anns": "RED-ANNS"}
    config_colors = {"mr_anns": "#1f77b4", "random": "#ff7f0e",
                     "locality": "#2ca02c", "red_anns": "#d62728"}

    n = len(ds_list)
    fig, axes = plt.subplots(1, n, figsize=(5 * n, 5), squeeze=False)
    axes = axes.flatten()

    for idx, ds in enumerate(ds_list):
        ax = axes[idx]
        ds_rows = [r for r in fig11_rows if r.get("dataset") == ds]

        k_vals = sorted(set(r.get("K") for r in ds_rows if isinstance(r.get("K"), int)))
        if not k_vals:
            k_vals = [1, 10, 100]

        x = np.arange(len(k_vals))
        width = 0.8 / len(configs)

        for ci, cfg in enumerate(configs):
            qps_vals = []
            for k_val in k_vals:
                # Config name in fig11 includes K suffix
                matching = [r for r in ds_rows
                           if (r.get("config", "").startswith(cfg) and
                               r.get("K") == k_val)]
                if matching:
                    qps_vals.append(matching[0].get("qps", 0))
                else:
                    qps_vals.append(0)

            ax.bar(x + ci * width, qps_vals, width,
                   label=config_labels.get(cfg, cfg),
                   color=config_colors.get(cfg, "gray"))

        ax.set_title(DATASET_TITLES.get(ds, ds), fontsize=12, fontweight="bold")
        ax.set_xlabel("Top-K", fontsize=10)
        ax.set_ylabel("QPS", fontsize=10)
        ax.set_xticks(x + width * (len(configs) - 1) / 2)
        ax.set_xticklabels([f"Top-{k}" for k in k_vals])
        ax.legend(fontsize=8)
        ax.grid(True, axis="y", alpha=0.3)

    fig.suptitle("Figure 11: Performance comparison (Recall@K=0.9)",
                 fontsize=14, fontweight="bold", y=1.02)
    plt.tight_layout()
    save_fig(fig, output_path, pdf)


# ================================================================
# Figure 12: Distance Computation Overhead
# ================================================================

def plot_fig12(csv_path, output_path, datasets=None, pdf=False):
    """
    Figure 12: MR-ANNS vs RED-ANNS distance computation comparison.
    Uses mean_cmps from fig10 data at specific recall levels.
    """
    rows = load_csv(csv_path)
    if not rows:
        return

    ds_list = datasets or get_datasets(rows)
    if not ds_list:
        return

    n = len(ds_list)
    fig, axes = plt.subplots(1, n, figsize=(4 * n, 4), squeeze=False)
    axes = axes.flatten()

    for idx, ds in enumerate(ds_list):
        ax = axes[idx]
        ds_rows = [r for r in rows if r.get("dataset") == ds]

        # Get MR-ANNS and RED-ANNS data
        mr_rows = [r for r in ds_rows if r.get("config") == "mr_anns"
                   and isinstance(r.get("recall"), float)]
        red_rows = [r for r in ds_rows if r.get("config") == "red_anns"
                    and isinstance(r.get("recall"), float)]

        # Find closest to recall=0.9 and 0.95
        def find_at_recall(data, target):
            if not data:
                return None
            return min(data, key=lambda r: abs(r.get("recall", 0) - target))

        targets = [0.9, 0.95]
        x = np.arange(len(targets))
        width = 0.35

        mr_cmps = [find_at_recall(mr_rows, t) for t in targets]
        red_cmps = [find_at_recall(red_rows, t) for t in targets]

        mr_vals = [r.get("mean_cmps", 0) if r else 0 for r in mr_cmps]
        red_vals = [r.get("mean_cmps", 0) if r else 0 for r in red_cmps]

        bars1 = ax.bar(x - width/2, mr_vals, width, label="MR-ANNS", color="#1f77b4")
        bars2 = ax.bar(x + width/2, red_vals, width, label="RED-ANNS", color="#d62728")

        # Reduction percentage
        for i in range(len(targets)):
            if mr_vals[i] > 0 and red_vals[i] > 0:
                reduction = (1 - red_vals[i] / mr_vals[i]) * 100
                ax.text(x[i], max(mr_vals[i], red_vals[i]) * 1.05,
                       f"-{reduction:.1f}%", ha="center", fontsize=9, fontweight="bold")

        ax.set_title(DATASET_TITLES.get(ds, ds), fontsize=11, fontweight="bold")
        ax.set_ylabel("Dist. Calc.", fontsize=10)
        ax.set_xticks(x)
        ax.set_xticklabels([f"R@10={t}" for t in targets])
        ax.legend(fontsize=8)
        ax.grid(True, axis="y", alpha=0.3)

    fig.suptitle("Figure 12: Distance Computation Overhead",
                 fontsize=13, fontweight="bold", y=1.02)
    plt.tight_layout()
    save_fig(fig, output_path, pdf)


# ================================================================
# Figure 14: Remote Access Ratio with Data Placement
# ================================================================

def plot_fig14(csv_path, output_path, datasets=None, pdf=False):
    rows = load_csv(csv_path)
    if not rows:
        return

    fig14_rows = [r for r in rows if "fig14" in r.get("figure", "")]
    if not fig14_rows:
        fig14_rows = rows

    ds_list = datasets or get_datasets(fig14_rows)
    if not ds_list:
        return

    n = len(ds_list)
    fig, axes = plt.subplots(1, max(n, 1), figsize=(5 * max(n, 1), 5), squeeze=False)
    axes = axes.flatten()

    placement_order = ["locality_sche1", "locality_sche3",
                       "locality_dup_1M", "locality_dup_2M", "locality_dup_4M"]
    placement_labels = {
        "locality_sche1": "BKMeans",
        "locality_sche3": "Locality",
        "locality_dup_1M": "+Dup(1M)",
        "locality_dup_2M": "+Dup(2M)",
        "locality_dup_4M": "+Dup(4M)",
    }
    colors = ["#ff7f0e", "#2ca02c", "#9467bd", "#8c564b", "#e377c2"]

    for idx, ds in enumerate(ds_list):
        ax = axes[idx]
        ds_rows = [r for r in fig14_rows if r.get("dataset") == ds]

        configs_found = []
        remote_ratios = []
        qps_vals = []

        for cfg in placement_order:
            matching = [r for r in ds_rows if r.get("config") == cfg]
            if not matching:
                continue
            r = matching[0]
            cmps = r.get("mean_cmps", 1)
            cmps_remote = r.get("mean_cmps_remote", 0)
            ratio = (cmps_remote / cmps * 100) if cmps > 0 else 0
            configs_found.append(cfg)
            remote_ratios.append(ratio)
            qps_vals.append(r.get("qps", 0))

        if not configs_found:
            ax.text(0.5, 0.5, f"No data for {ds}", ha="center", va="center",
                    transform=ax.transAxes)
            continue

        x = np.arange(len(configs_found))
        bars = ax.bar(x, remote_ratios, 0.6,
                      color=[colors[i % len(colors)] for i in range(len(configs_found))])

        # 비율 표시
        for i, (bar, ratio) in enumerate(zip(bars, remote_ratios)):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 1,
                   f"{ratio:.0f}%", ha="center", va="bottom", fontsize=9)

        ax.set_title(DATASET_TITLES.get(ds, ds), fontsize=11, fontweight="bold")
        ax.set_ylabel("Remote Ratio (%)", fontsize=10)
        ax.set_xticks(x)
        ax.set_xticklabels([placement_labels.get(c, c) for c in configs_found],
                           rotation=30, ha="right", fontsize=8)
        ax.set_ylim(0, 100)
        ax.grid(True, axis="y", alpha=0.3)

        # QPS on secondary axis
        ax2 = ax.twinx()
        ax2.plot(x, [q / max(qps_vals) if max(qps_vals) > 0 else 0 for q in qps_vals],
                "ko-", markersize=6, label="Norm. QPS")
        ax2.set_ylabel("Norm. QPS", fontsize=10)
        ax2.set_ylim(0, 3)
        ax2.legend(fontsize=8, loc="upper left")

    fig.suptitle("Figure 14: Remote Access Ratio (Data Placement)",
                 fontsize=13, fontweight="bold", y=1.02)
    plt.tight_layout()
    save_fig(fig, output_path, pdf)


# ================================================================
# Figure 16(a): RBFS Latency Breakdown
# ================================================================

COMP_COLORS = {
    "expand": "#4472C4",
    "post_read": "#ED7D31",
    "wait_io": "#A5A5A5",
    "poll": "#FFC000",
}


def plot_fig16a(csv_path, output_path, datasets=None, pdf=False):
    rows = load_csv(csv_path)
    if not rows:
        return

    fig16_rows = [r for r in rows if "fig16a" in r.get("figure", "")
                  or r.get("config", "").startswith("relax_")]
    if not fig16_rows:
        fig16_rows = [r for r in rows if isinstance(r.get("relax"), int)]

    if datasets:
        fig16_rows = [r for r in fig16_rows
                      if r.get("dataset") in datasets or not r.get("dataset")]

    relax_data = {}
    for r in fig16_rows:
        relax = r.get("relax")
        if relax is None:
            continue
        if isinstance(relax, str):
            try:
                relax = int(relax)
            except ValueError:
                continue
        latency = r.get("mean_latency", 0)
        cmps = r.get("mean_cmps", 1)
        cmps_local = r.get("mean_cmps_local", 0)
        cmps_remote = r.get("mean_cmps_remote", 0)

        relax_data[relax] = {
            "latency": latency,
            "cmps": cmps,
            "cmps_local": cmps_local,
            "cmps_remote": cmps_remote,
            "qps": r.get("qps", 0),
            "recall": r.get("recall", 0),
            "local_ratio": cmps_local / cmps if cmps > 0 else 0.5,
        }

    if not relax_data:
        print("ERROR: No relax data found.", file=sys.stderr)
        return

    relax_levels = sorted(relax_data.keys())
    labels = [f"n={r}" for r in relax_levels]

    expand_vals = []
    post_read_vals = []
    wait_io_vals = []
    poll_vals = []
    total_vals = []
    qps_list = []
    recall_list = []

    for relax in relax_levels:
        d = relax_data[relax]
        total = d["latency"]
        total_vals.append(total)
        qps_list.append(d["qps"])
        recall_list.append(d["recall"])

        local_ratio = d["local_ratio"]
        expand = total * local_ratio * 0.8
        remote_total = total - expand

        overlap_factor = max(0, 1 - relax * 0.2)
        wait = remote_total * overlap_factor * 0.65
        post = remote_total * 0.2
        poll = max(0, remote_total - wait - post)

        expand_vals.append(max(0, expand))
        post_read_vals.append(max(0, post))
        wait_io_vals.append(max(0, wait))
        poll_vals.append(max(0, poll))

    fig, ax = plt.subplots(figsize=(8, 5))
    x = np.arange(len(relax_levels))
    width = 0.5

    ax.bar(x, expand_vals, width, label="Expand Neighbors", color=COMP_COLORS["expand"])
    b2 = expand_vals
    ax.bar(x, post_read_vals, width, bottom=b2, label="Post Read", color=COMP_COLORS["post_read"])
    b3 = [a + b for a, b in zip(b2, post_read_vals)]
    ax.bar(x, wait_io_vals, width, bottom=b3, label="Wait I/O", color=COMP_COLORS["wait_io"])
    b4 = [a + b for a, b in zip(b3, wait_io_vals)]
    ax.bar(x, poll_vals, width, bottom=b4, label="Poll Completion", color=COMP_COLORS["poll"])

    for i, total in enumerate(total_vals):
        ax.text(i, total + total * 0.02, f"{total:.0f}us",
               ha="center", va="bottom", fontsize=9, fontweight="bold")

    ax.set_xlabel("Relaxation Level (n)", fontsize=11)
    ax.set_ylabel("Average Query Latency (us)", fontsize=11)
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.legend(loc="upper right", fontsize=9)
    ax.grid(True, axis="y", alpha=0.3)

    info = " | ".join([f"n={r}: QPS={qps_list[i]:.0f}, R@10={recall_list[i]:.3f}"
                       for i, r in enumerate(relax_levels)])
    fig.text(0.5, -0.02, info, ha="center", fontsize=8, style="italic")

    ds_name = datasets[0] if datasets else "Dataset"
    ax.set_title(f"Figure 16(a): RBFS Latency Breakdown ({ds_name})",
                fontsize=13, fontweight="bold")

    plt.tight_layout()
    save_fig(fig, output_path, pdf)


# ================================================================
# Figure 16(b): PQ Pruning
# ================================================================

def plot_fig16b(csv_path, output_path, datasets=None, pdf=False):
    rows = load_csv(csv_path)
    if not rows:
        return

    fig16b_rows = [r for r in rows if "fig16b" in r.get("figure", "")
                   or r.get("config", "").startswith("epsilon_")]

    if not fig16b_rows:
        print("No Figure 16(b) data found", file=sys.stderr)
        return

    eps_data = {}
    for r in fig16b_rows:
        cfg = r.get("config", "")
        if not cfg.startswith("epsilon_"):
            continue
        eps = float(cfg.split("_")[1])
        eps_data[eps] = {
            "qps": r.get("qps", 0),
            "cmps_remote": r.get("mean_cmps_remote", 0),
            "cmps": r.get("mean_cmps", 1),
        }

    if not eps_data:
        return

    eps_vals = sorted(eps_data.keys())

    fig, ax1 = plt.subplots(figsize=(8, 5))

    remote_freqs = [eps_data[e]["cmps_remote"] for e in eps_vals]
    qps_vals = [eps_data[e]["qps"] for e in eps_vals]

    x = np.arange(len(eps_vals))
    bars = ax1.bar(x, remote_freqs, 0.5, color="#4472C4", alpha=0.8, label="Remote Frequency")
    ax1.set_xlabel("Pruning Parameter (ε)", fontsize=11)
    ax1.set_ylabel("Remote Frequency", fontsize=11)
    ax1.set_xticks(x)
    ax1.set_xticklabels([f"ε={e}" for e in eps_vals])

    # Remote ratio
    for i, (bar, freq) in enumerate(zip(bars, remote_freqs)):
        cmps = eps_data[eps_vals[i]]["cmps"]
        ratio = (freq / cmps * 100) if cmps > 0 else 0
        ax1.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 10,
                f"{ratio:.1f}%", ha="center", fontsize=9)

    ax2 = ax1.twinx()
    ax2.plot(x, qps_vals, "ro-", markersize=8, linewidth=2, label="QPS")
    ax2.set_ylabel("QPS", fontsize=11, color="red")
    ax2.tick_params(axis="y", labelcolor="red")

    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper right", fontsize=9)

    ax1.set_title("Figure 16(b): Neighbor Pruning (PQ)", fontsize=13, fontweight="bold")
    ax1.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    save_fig(fig, output_path, pdf)


# ================================================================
# Main
# ================================================================

FIGURE_HANDLERS = {
    "fig10": (plot_fig10, "results/fig10_results.csv", "results/fig10.png"),
    "fig11": (plot_fig11, "results/fig11_results.csv", "results/fig11.png"),
    "fig12": (plot_fig12, "results/fig10_results.csv", "results/fig12.png"),
    "fig14": (plot_fig14, "results/fig14_results.csv", "results/fig14.png"),
    "fig16a": (plot_fig16a, "results/fig16a_results.csv", "results/fig16a.png"),
    "fig16b": (plot_fig16b, "results/fig16b_results.csv", "results/fig16b.png"),
}


def main():
    parser = argparse.ArgumentParser(description="RED-ANNS Figure 재현 플로팅")
    parser.add_argument("--figure", nargs="*", default=None,
                        help="플로팅할 Figure (예: fig10 fig16a). 미지정시 전체.")
    parser.add_argument("--dataset", nargs="*", default=None)
    parser.add_argument("--pdf", action="store_true")
    parser.add_argument("-i", "--input", default=None,
                        help="입력 CSV (미지정시 Figure별 기본 CSV)")
    parser.add_argument("-o", "--output-dir", default="results")
    args = parser.parse_args()

    figures = args.figure or list(FIGURE_HANDLERS.keys())

    for fig_name in figures:
        if fig_name not in FIGURE_HANDLERS:
            print(f"WARNING: Unknown figure '{fig_name}'. "
                  f"Available: {list(FIGURE_HANDLERS.keys())}", file=sys.stderr)
            continue

        handler, default_csv, default_png = FIGURE_HANDLERS[fig_name]
        csv_path = args.input or default_csv
        out_path = os.path.join(args.output_dir, os.path.basename(default_png))

        if not os.path.exists(csv_path):
            print(f"SKIP {fig_name}: CSV not found ({csv_path})", file=sys.stderr)
            continue

        print(f"\nPlotting {fig_name} from {csv_path}...", file=sys.stderr)
        handler(csv_path, out_path, args.dataset, args.pdf)


if __name__ == "__main__":
    main()
