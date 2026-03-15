#!/usr/bin/env python3
"""
============================================================
RED-ANNS 더미 로그 생성기
============================================================
실제 RDMA 클러스터 없이 전체 파이프라인(파싱→CSV→플로팅)을 
테스트하기 위한 더미 로그를 생성합니다.

논문의 실제 수치를 참고하여 현실적인 더미 데이터를 생성합니다.

사용법:
  python3 generate_dummy_logs.py              # 기본 (deep100M)
  python3 generate_dummy_logs.py --all        # 4개 데이터셋 전부
"""

import argparse
import os
import random
import math
from datetime import datetime

LOG_DIR = "logs"
TIMESTAMP = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")


# ================================================================
# 논문 수치 기반 데이터 모델
# ================================================================
# 논문 Figure 10: QPS vs Recall@10
# 각 config별 대략적 QPS 범위 (recall=0.9 기준, 4 nodes, 8 threads)

DATASET_PARAMS = {
    "deep100M": {
        "dim": 96,
        "max_qps": {"red_anns": 38000, "locality_sched": 30000, "locality": 22000,
                     "random": 15000, "mr_anns": 20000},
        "base_cmps": 2000,  # distance computations at recall=0.9
        "remote_ratio": {"random": 0.75, "locality": 0.16, "red_anns": 0.10},
    },
    "msturing": {
        "dim": 100,
        "max_qps": {"red_anns": 22000, "locality_sched": 17000, "locality": 12000,
                     "random": 8000, "mr_anns": 10000},
        "base_cmps": 5000,
        "remote_ratio": {"random": 0.75, "locality": 0.38, "red_anns": 0.31},
    },
    "text2image": {
        "dim": 200,
        "max_qps": {"red_anns": 6500, "locality_sched": 5000, "locality": 3500,
                     "random": 2500, "mr_anns": 3200},
        "base_cmps": 10000,
        "remote_ratio": {"random": 0.75, "locality": 0.25, "red_anns": 0.16},
    },
    "laion": {
        "dim": 512,
        "max_qps": {"red_anns": 3500, "locality_sched": 2500, "locality": 1800,
                     "random": 1200, "mr_anns": 1700},
        "base_cmps": 25000,
        "remote_ratio": {"random": 0.75, "locality": 0.24, "red_anns": 0.16},
    },
}

L_VALUES = [15, 20, 30, 40, 50, 60, 70, 80, 90, 100, 120, 140, 160, 200]


def recall_from_L(L, k=10):
    """L값에서 recall을 계산 (로지스틱 모델)"""
    # L=15 → ~0.82, L=50 → ~0.90, L=100 → ~0.95, L=200 → ~0.98
    x = (L - 60) / 30
    return 0.82 + 0.17 / (1 + math.exp(-x))


def qps_from_recall(recall, max_qps):
    """recall에서 QPS를 계산 (높은 recall → 낮은 QPS)"""
    # recall이 0.82→1.0으로 갈 때 QPS가 max → max*0.15로 감소
    factor = max(0.15, 1.0 - (recall - 0.82) ** 1.5 * 8)
    noise = random.uniform(0.95, 1.05)
    return max_qps * factor * noise


def cmps_from_L(L, base_cmps, remote_ratio):
    """L에서 distance computation 수 계산"""
    total = base_cmps * (L / 100) ** 0.8 * random.uniform(0.95, 1.05)
    remote = total * remote_ratio * random.uniform(0.9, 1.1)
    local = total - remote
    return total, local, remote


def write_log_entry(f, K, L, T, sche, relax, qps, recall, cmps, cmps_local, cmps_remote,
                    mean_latency, para_path="./app/test.json"):
    """하나의 실행 결과를 로그 형식으로 기록"""
    hops = L * 0.15 * random.uniform(0.9, 1.1)
    f.write(f"--- RUN: L={L} ---\n")
    f.write(f"DSM-ANNS run para_path: {para_path}\n")
    f.write(f"K: {K}\n")
    f.write(f"L: {L}\n")
    f.write(f"T: {T}\n")
    f.write(f"sche_strategy: {sche}\n")
    f.write(f"relax: {relax}\n")
    f.write(f"qps: {qps:.2f}\n")
    f.write(f"recall: {recall:.4f}\n")
    f.write(f"query_count: 10000\n")
    f.write(f"mean_hops: {hops:.2f}\n")
    f.write(f"mean_cmps: {cmps:.2f}\n")
    f.write(f"mean_cmps_local: {cmps_local:.2f}\n")
    f.write(f"mean_cmps_remote: {cmps_remote:.2f}\n")
    f.write(f"mean_latency: {mean_latency:.2f}\n")
    f.write(f"--- END: L={L} ---\n\n")


# ================================================================
# Figure 10: QPS vs Recall
# ================================================================

def generate_fig10_logs(ds_name, ds_params):
    """Figure 10 더미 로그 생성"""
    configs = {
        "mr_anns":        (1, 0, 0.50),   # (sche, relax, remote_ratio)
        "random":         (1, 0, 0.75),
        "locality":       (1, 0, ds_params["remote_ratio"].get("locality", 0.25)),
        "locality_sched": (3, 0, ds_params["remote_ratio"].get("locality", 0.25) * 0.8),
        "red_anns":       (3, 3, ds_params["remote_ratio"].get("red_anns", 0.15)),
    }

    for cfg_name, (sche, relax, rr) in configs.items():
        log_path = os.path.join(LOG_DIR, f"fig10_{ds_name}_{TIMESTAMP}_{cfg_name}.log")
        max_qps = ds_params["max_qps"].get(cfg_name, 10000)

        with open(log_path, "w") as f:
            f.write(f"# config={cfg_name} dataset={ds_name} K=10 T=8 "
                   f"sche={sche} relax={relax} cache=0 figure=fig10\n")
            for L in L_VALUES:
                recall = recall_from_L(L)
                qps = qps_from_recall(recall, max_qps)
                cmps, cmps_local, cmps_remote = cmps_from_L(
                    L, ds_params["base_cmps"], rr)
                latency = 1_000_000 / qps if qps > 0 else 9999
                write_log_entry(f, 10, L, 8, sche, relax, qps, recall,
                               cmps, cmps_local, cmps_remote, latency)


# ================================================================
# Figure 11: Top-K sweep
# ================================================================

def generate_fig11_logs(ds_name, ds_params):
    """Figure 11 더미 로그 생성"""
    K_vals = [1, 10, 100]
    L = 100
    recall_base = recall_from_L(L)

    configs = {
        "mr_anns":   (1, 0, 0.50),
        "random":    (1, 0, 0.75),
        "locality":  (3, 0, ds_params["remote_ratio"].get("locality", 0.25)),
        "red_anns":  (3, 3, ds_params["remote_ratio"].get("red_anns", 0.15)),
    }

    for cfg_name, (sche, relax, rr) in configs.items():
        for K_val in K_vals:
            log_path = os.path.join(
                LOG_DIR, f"fig11_{ds_name}_{TIMESTAMP}_{cfg_name}_K{K_val}.log")
            max_qps = ds_params["max_qps"].get(cfg_name, 10000)

            # QPS decreases slightly with higher K
            k_factor = 1.0 / (1 + 0.1 * math.log2(max(K_val, 1)))

            with open(log_path, "w") as f:
                f.write(f"# config={cfg_name} dataset={ds_name} K={K_val} "
                       f"L={L} T=8 sche={sche} relax={relax} cache=0 figure=fig11\n")
                qps = max_qps * k_factor * recall_base * random.uniform(0.9, 1.1)
                cmps, cmps_local, cmps_remote = cmps_from_L(
                    L, ds_params["base_cmps"], rr)
                latency = 1_000_000 / qps if qps > 0 else 9999
                write_log_entry(f, K_val, L, 8, sche, relax, qps, recall_base,
                               cmps, cmps_local, cmps_remote, latency)


# ================================================================
# Figure 14: Remote access ratio
# ================================================================

def generate_fig14_logs(ds_name, ds_params):
    """Figure 14 더미 로그 생성"""
    L = 100
    recall = recall_from_L(L)

    placements = {
        "locality_sche1": (1, 0, 0, ds_params["remote_ratio"].get("locality", 0.25)),
        "locality_sche3": (3, 0, 0, ds_params["remote_ratio"].get("locality", 0.25) * 0.7),
        "locality_dup_1M": (3, 0, 1000000, ds_params["remote_ratio"].get("red_anns", 0.15) * 1.3),
        "locality_dup_2M": (3, 0, 2000000, ds_params["remote_ratio"].get("red_anns", 0.15) * 1.1),
        "locality_dup_4M": (3, 0, 4000000, ds_params["remote_ratio"].get("red_anns", 0.15)),
    }

    for cfg_name, (sche, relax, cache, rr) in placements.items():
        log_path = os.path.join(LOG_DIR, f"fig14_{ds_name}_{TIMESTAMP}_{cfg_name}.log")
        max_qps = ds_params["max_qps"]["red_anns"] * (1 - rr * 0.5)

        with open(log_path, "w") as f:
            f.write(f"# config={cfg_name} dataset={ds_name} K=10 L={L} T=8 "
                   f"sche={sche} relax={relax} cache={cache} figure=fig14\n")
            qps = max_qps * random.uniform(0.9, 1.1)
            cmps, cmps_local, cmps_remote = cmps_from_L(
                L, ds_params["base_cmps"], rr)
            latency = 1_000_000 / qps if qps > 0 else 9999
            write_log_entry(f, 10, L, 8, sche, relax, qps, recall,
                           cmps, cmps_local, cmps_remote, latency)


# ================================================================
# Figure 16(a): RBFS relax sweep
# ================================================================

def generate_fig16a_logs(ds_name, ds_params):
    """Figure 16(a) 더미 로그 생성"""
    L = 100
    relax_vals = [0, 1, 2, 3, 8]
    base_latency = 1600  # us (BFS baseline)

    for relax in relax_vals:
        log_path = os.path.join(LOG_DIR, f"fig16a_{ds_name}_{TIMESTAMP}_relax_{relax}.log")

        # Latency model (논문 Figure 16a 참고):
        # relax=0: 1450us (reorder만), relax=1: 1200us, relax=2: 1000us (최적)
        # relax=3: 1050us, relax=8: 1100us (오히려 증가)
        if relax == 0:
            latency = base_latency * 0.9
        elif relax == 1:
            latency = base_latency * 0.75
        elif relax == 2:
            latency = base_latency * 0.63
        elif relax <= 3:
            latency = base_latency * 0.65
        else:
            latency = base_latency * 0.70  # degradation at high relax

        latency *= random.uniform(0.95, 1.05)
        qps = 1_000_000 / latency * 8  # 8 threads
        recall = recall_from_L(L) * random.uniform(0.99, 1.01)

        rr = ds_params["remote_ratio"].get("red_anns", 0.15) * (1 + relax * 0.02)
        cmps, cmps_local, cmps_remote = cmps_from_L(L, ds_params["base_cmps"], rr)

        with open(log_path, "w") as f:
            f.write(f"# config=relax_{relax} dataset={ds_name} K=10 L={L} T=8 "
                   f"sche=3 relax={relax} cache=0 figure=fig16a\n")
            write_log_entry(f, 10, L, 8, 3, relax, qps, recall,
                           cmps, cmps_local, cmps_remote, latency)


# ================================================================
# Main
# ================================================================

def main():
    parser = argparse.ArgumentParser(description="더미 로그 생성")
    parser.add_argument("--all", action="store_true",
                        help="4개 데이터셋 전부 생성 (기본: deep100M만)")
    parser.add_argument("--dataset", nargs="*", default=None)
    args = parser.parse_args()

    os.makedirs(LOG_DIR, exist_ok=True)

    if args.dataset:
        ds_list = args.dataset
    elif args.all:
        ds_list = list(DATASET_PARAMS.keys())
    else:
        ds_list = ["deep100M"]

    for ds_name in ds_list:
        if ds_name not in DATASET_PARAMS:
            print(f"WARNING: Unknown dataset '{ds_name}', skipping")
            continue

        print(f"Generating logs for {ds_name}...")
        ds_params = DATASET_PARAMS[ds_name]
        generate_fig10_logs(ds_name, ds_params)
        generate_fig11_logs(ds_name, ds_params)
        generate_fig14_logs(ds_name, ds_params)
        generate_fig16a_logs(ds_name, ds_params)

    # 생성된 파일 목록
    log_files = sorted(os.listdir(LOG_DIR))
    print(f"\nGenerated {len(log_files)} log files in {LOG_DIR}/")
    for f in log_files[:10]:
        print(f"  {f}")
    if len(log_files) > 10:
        print(f"  ... and {len(log_files) - 10} more")


if __name__ == "__main__":
    main()
