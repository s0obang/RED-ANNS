#!/bin/bash
# ============================================================
# Figure 16(b) 재현: PQ Pruning epsilon sweep
# ============================================================
# 논문 Figure 16(b): 다양한 epsilon 값에 따른
# remote access frequency 및 QPS.
#
# ⚠️ IMPORTANT: epsilon은 현재 index.cpp에 하드코딩되어 있음.
# 재현을 위해 코드 수정이 필요합니다:
#
# 1) index.cpp에서 epsilon을 외부 파라미터로 받도록 수정:
#    - main()에서 argv[10]으로 epsilon 전달
#    - search 함수에서 하드코딩된 1.1 대신 파라미터 사용
#
# 2) 또는 각 epsilon 값마다 코드를 수정하고 재빌드
#
# 이 스크립트는 코드 수정 후 사용하기 위한 템플릿입니다.
# 현재는 SKIP 처리됩니다.
#
# 사용법:
#   cd experiments
#   bash run_fig16b.sh [dataset_name]
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
TARGET_DATASET="${1:-}"

log_separator
echo " RED-ANNS Figure 16(b) Reproduction"
echo " Start: $(timestamp)"
echo ""
echo " ⚠️  WARNING: epsilon parameter is hardcoded in index.cpp"
echo "     Code modification required before running this experiment."
echo "     See experiments/README_SETUP.md for instructions."
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
    LOG_PREFIX="$LOG_DIR/fig16b_${ds_name}_${TS}"
    L="$L_FOR_RELAX"

    for eps in "${EPSILON_VALUES[@]}"; do
        CONFIG_NAME="epsilon_${eps}"
        LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

        echo "[epsilon=$eps] sche=3, relax=3, L=$L, T=$T ..."
        echo "# config=$CONFIG_NAME dataset=$ds_name K=$K L=$L T=$T sche=3 relax=3 epsilon=$eps cache=0 figure=fig16b" > "$LOG_FILE"
        echo "--- RUN: epsilon=$eps ---" >> "$LOG_FILE"

        # TODO: Uncomment after code modification to accept epsilon parameter
        # run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 3 0 "$eps" 2>&1 | tee -a "$LOG_FILE" || true
        echo "SKIPPED: epsilon 파라미터 외부화 코드 수정 필요" | tee -a "$LOG_FILE"

        echo "--- END: epsilon=$eps ---" >> "$LOG_FILE"
        sleep 1
    done

    echo "====== Dataset $ds_name complete ======"
done

echo ""
log_separator
echo " Figure 16(b) finished: $(timestamp)"
log_separator
