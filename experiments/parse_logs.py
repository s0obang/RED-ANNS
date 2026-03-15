#!/usr/bin/env python3
"""
============================================================
RED-ANNS 실험 로그 → CSV 파서
============================================================
test_search_distributed 및 test_map_reduce의 stdout 로그를 파싱하여 CSV로 변환.

파싱 대상 로그 형식 (rank 0의 LOG_EMPH 출력):
  DSM-ANNS run para_path: ...
  K: 10
  L: 100
  T: 8
  sche_strategy: 3
  relax: 3
  qps: 1234.56
  recall: 0.92
  query_count: 10000
  mean_hops: 15.30
  mean_cmps: 245.60
  mean_cmps_local: 180.20
  mean_cmps_remote: 65.40
  mean_latency: 812.50

사용법:
  python3 parse_logs.py                               # logs/ 전체 파싱
  python3 parse_logs.py logs/fig10_deep*.log           # 특정 파일만
  python3 parse_logs.py -o results/my.csv              # 출력 파일 지정
  python3 parse_logs.py --figure fig10                 # Figure별 파싱
  python3 parse_logs.py --figure fig16a                # Figure 16a만
"""

import argparse
import csv
import glob
import os
import re
import sys
from pathlib import Path


# ---- 파싱할 필드 정의 ----
FIELDS_TO_PARSE = [
    "para_path", "K", "L", "T", "sche_strategy", "relax",
    "qps", "recall", "query_count",
    "mean_hops", "mean_cmps", "mean_cmps_local", "mean_cmps_remote",
    "mean_latency",
]

NUMERIC_FIELDS = {
    "K": int, "L": int, "T": int,
    "sche_strategy": int, "relax": int, "query_count": int,
    "qps": float, "recall": float,
    "mean_hops": float, "mean_cmps": float,
    "mean_cmps_local": float, "mean_cmps_remote": float,
    "mean_latency": float,
}

# 로그 파일명 패턴: fig10_deep100M_2026-03-15_12-00-00_random.log
LOG_FILENAME_PATTERN = re.compile(
    r"(fig\w+)_(\w+?)_\d{4}-\d{2}-\d{2}_[\d-]+_(.+)\.log"
)


def parse_config_from_comment(line: str) -> dict:
    """로그 첫 줄의 # config=... 주석에서 메타데이터 추출"""
    meta = {}
    for match in re.finditer(r"(\w+)=(\S+)", line):
        meta[match.group(1)] = match.group(2)
    return meta


def parse_log_file(filepath: str) -> list:
    """하나의 로그 파일을 파싱하여 실행 결과 리스트 반환"""
    results = []
    current_run = {}
    file_meta = {}

    fname = os.path.basename(filepath)
    m = LOG_FILENAME_PATTERN.match(fname)
    if m:
        file_meta["figure"] = m.group(1)
        file_meta["dataset"] = m.group(2)
        file_meta["config"] = m.group(3)

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            # ANSI color codes 제거
            line = re.sub(r"\x1b\[[0-9;]*m", "", line)

            # 주석 줄
            if line.startswith("#") and ":" not in line.split("#", 1)[-1][:20]:
                comment_meta = parse_config_from_comment(line)
                file_meta.update(comment_meta)
                continue
            if line.startswith("# config=") or line.startswith("# NOTE:"):
                comment_meta = parse_config_from_comment(line)
                file_meta.update(comment_meta)
                continue

            # "--- RUN:" 구분자
            if line.startswith("--- RUN:"):
                current_run = dict(file_meta)
                for match in re.finditer(r"(\w+)=(\S+)", line):
                    key, val = match.group(1), match.group(2)
                    if key not in current_run:
                        current_run[key] = val
                continue

            # "--- END:" 구분자
            if line.startswith("--- END:"):
                if current_run and "qps" in current_run:
                    results.append(current_run)
                current_run = dict(file_meta)
                continue

            # DSM-ANNS 결과 블록
            if "DSM-ANNS run para_path:" in line:
                val = line.split("DSM-ANNS run para_path:")[-1].strip()
                current_run["para_path"] = val
                continue

            # "key: value" 패턴 (LOG_EMPH 출력)
            for field in FIELDS_TO_PARSE:
                pattern = rf"(?:^|\s){re.escape(field)}:\s+(\S+)"
                match = re.search(pattern, line)
                if match:
                    val = match.group(1)
                    if field in NUMERIC_FIELDS:
                        try:
                            val = NUMERIC_FIELDS[field](val)
                        except (ValueError, TypeError):
                            pass
                    current_run[field] = val
                    break

            # MR-ANNS 결과 형식
            if "final qps:" in line:
                m2 = re.search(r"final qps:\s+(\S+)", line)
                if m2:
                    try:
                        current_run["qps"] = float(m2.group(1))
                    except ValueError:
                        pass
            if "final recall:" in line or "final Recall@" in line:
                m2 = re.search(r"(?:final recall|final Recall@\d+):\s+(\S+)", line)
                if m2:
                    try:
                        current_run["recall"] = float(m2.group(1))
                    except ValueError:
                        pass

            # 개별 노드 qps
            if line.startswith("#") and "qps:" in line:
                m2 = re.search(r"#(\d+)\s+qps:\s+(\S+)", line)
                if m2:
                    current_run[f"node{m2.group(1)}_qps"] = float(m2.group(2))

            # Recall@K
            recall_match = re.match(r"Recall@(\d+):\s+(\S+)", line)
            if recall_match:
                k_val = recall_match.group(1)
                recall_val = float(recall_match.group(2))
                current_run[f"recall_at_{k_val}"] = recall_val
                if "recall" not in current_run:
                    current_run["recall"] = recall_val

            # IO 통계
            if "IO Cnt:" in line:
                m2 = re.search(r"IO Cnt:\s+(\d+)", line)
                if m2:
                    current_run["io_cnt"] = int(m2.group(1))
            if "IO Size:" in line:
                m2 = re.search(r"IO Size:\s+(\d+)", line)
                if m2:
                    current_run["io_size"] = int(m2.group(1))

    # 파일 끝의 마지막 실행
    if current_run and "qps" in current_run:
        results.append(current_run)

    return results


def parse_multiple_files(file_patterns: list) -> list:
    """여러 파일 패턴을 받아 모든 결과 합침"""
    all_results = []
    files_parsed = 0

    for pattern in file_patterns:
        matched_files = sorted(glob.glob(pattern))
        if not matched_files:
            print(f"  WARNING: no files matched '{pattern}'", file=sys.stderr)
            continue
        for fpath in matched_files:
            results = parse_log_file(fpath)
            for r in results:
                r["source_file"] = os.path.basename(fpath)
            all_results.extend(results)
            files_parsed += 1
            print(f"  Parsed {fpath}: {len(results)} runs", file=sys.stderr)

    print(f"  Total: {files_parsed} files, {len(all_results)} runs", file=sys.stderr)
    return all_results


def results_to_csv(results: list, output_path: str):
    """결과 리스트를 CSV로 저장"""
    if not results:
        print("No results to write.", file=sys.stderr)
        return

    ordered_columns = [
        "source_file", "figure", "dataset", "config",
        "para_path", "K", "L", "T", "sche_strategy", "relax",
        "qps", "recall", "query_count",
        "mean_hops", "mean_cmps", "mean_cmps_local", "mean_cmps_remote",
        "mean_latency", "io_cnt", "io_size",
    ]
    all_keys = set()
    for r in results:
        all_keys.update(r.keys())
    extra_keys = sorted(all_keys - set(ordered_columns))
    columns = [c for c in ordered_columns if c in all_keys] + extra_keys

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for r in results:
            writer.writerow(r)

    print(f"  CSV: {output_path} ({len(results)} rows, {len(columns)} cols)", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="RED-ANNS 로그 → CSV")
    parser.add_argument("log_files", nargs="*", default=["logs/*.log"])
    parser.add_argument("-o", "--output", default="results/all_results.csv")
    parser.add_argument("--figure", default=None,
                        help="Figure별 파싱 (예: fig10, fig16a)")
    args = parser.parse_args()

    if args.figure:
        args.log_files = [f"logs/{args.figure}_*.log"]
        if args.output == "results/all_results.csv":
            args.output = f"results/{args.figure}_results.csv"

    print(f"Parsing: {args.log_files}", file=sys.stderr)
    results = parse_multiple_files(args.log_files)
    results_to_csv(results, args.output)


if __name__ == "__main__":
    main()
