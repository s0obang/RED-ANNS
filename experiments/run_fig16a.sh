#!/bin/bash
# ============================================================
# Figure 16(a) 재현: RBFS Latency with Relax Sweep
# ============================================================
# 논문 Figure 16(a): MS-Turing 데이터셋에서 Recall@10=0.9 고정,
# relax={BFS, 0, 1, 2, 8}에 따른 평균 쿼리 latency.
#
# BFS = conventional best-first search (코드에서는 relax가 없는 별도 코드패스)
# RBFS n=0: reorder만 적용, dependency relaxation 없음
# RBFS n=1,2,8: dependency relaxation 적용
#
# NOTE: 논문에서 BFS와 RBFS:n=0의 차이는 "distance computation 순서 재정렬"
#   코드에서 BFS→RBFS 전환은 search 함수 내부에서 처리됨.
#   relax=0은 RBFS:n=0에 해당.
#
# 사용법:
#   cd experiments
#   bash run_fig16a.sh [dataset_name]
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
TARGET_DATASET="${1:-}"

# 논문에서 사용한 relax 값: BFS(별도), 0, 1, 2, 8
RELAX_SWEEP=(0 1 2 3 8)

log_separator
echo " RED-ANNS Figure 16(a) Reproduction"
echo " Start: $(timestamp)"
log_separator

for ds_entry in "${DATASETS[@]}"; do
    ds_name="${ds_entry%%:*}"
    ds_json="${ds_entry##*:}"

    if [[ -n "$TARGET_DATASET" && "$ds_name" != "$TARGET_DATASET" ]]; then
        continue
    fi

    echo ""
    echo "====== Dataset: $ds_name ($ds_json) ======"

    TS="$(timestamp)"
    LOG_PREFIX="$LOG_DIR/fig16a_${ds_name}_${TS}"
    L="$L_FOR_RELAX"

    for relax in "${RELAX_SWEEP[@]}"; do
        CONFIG_NAME="relax_${relax}"
        LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

        echo "[relax=$relax] sche=3, L=$L, T=$T ..."
        echo "# config=$CONFIG_NAME dataset=$ds_name K=$K L=$L T=$T sche=3 relax=$relax cache=0 figure=fig16a" > "$LOG_FILE"
        echo "--- RUN: relax=$relax ---" >> "$LOG_FILE"

        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 "$relax" 0 2>&1 | tee -a "$LOG_FILE" || true

        echo "--- END: relax=$relax ---" >> "$LOG_FILE"
        echo "  → Log: $LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done

    echo ""
    echo "====== Dataset $ds_name complete ======"
done

echo ""
log_separator
echo " Figure 16(a) finished: $(timestamp)"
log_separator
