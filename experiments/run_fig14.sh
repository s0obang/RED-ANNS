#!/bin/bash
# ============================================================
# Figure 14 재현: Remote Access Ratio with Data Placement
# ============================================================
# 논문 Figure 14: 데이터 배치 방식별 remote access 비율 + QPS
#   - Random placement (sche=1)
#   - BKMeans partition (sche=1) 
#   - Locality (sche=3)
#   - Locality + Dup(1M/2M/4M) (sche=3, cache_node=1M/2M/4M)
#
# 이 실험의 핵심 메트릭: mean_cmps_remote / mean_cmps (remote ratio)
#
# NOTE: Random placement는 random partition된 데이터 필요.
#   현재 코드는 JSON의 bkmeans partition을 항상 사용하므로
#   별도 random partition JSON이 필요.
#
# 사용법:
#   cd experiments
#   bash run_fig14.sh [dataset_name]
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
TARGET_DATASET="${1:-}"

log_separator
echo " RED-ANNS Figure 14 Reproduction"
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
    LOG_PREFIX="$LOG_DIR/fig14_${ds_name}_${TS}"
    L="$L_FOR_RELAX"

    # ----------------------------------------------------------------
    # Locality-aware placement (default) + Random scheduling
    # ----------------------------------------------------------------
    CONFIG_NAME="locality_sche1"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"
    echo "# config=$CONFIG_NAME dataset=$ds_name K=$K L=$L T=$T sche=1 relax=0 cache=0 figure=fig14" > "$LOG_FILE"
    echo "[Locality + Random Scheduling] ..."
    echo "--- RUN: placement=locality sche=1 ---" >> "$LOG_FILE"
    run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 1 0 0 2>&1 | tee -a "$LOG_FILE" || true
    echo "--- END: placement=locality sche=1 ---" >> "$LOG_FILE"
    sleep "$SLEEP_BETWEEN_RUNS"

    # ----------------------------------------------------------------
    # Locality + Affinity scheduling (sche=3)
    # ----------------------------------------------------------------
    CONFIG_NAME="locality_sche3"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"
    echo "# config=$CONFIG_NAME dataset=$ds_name K=$K L=$L T=$T sche=3 relax=0 cache=0 figure=fig14" > "$LOG_FILE"
    echo "[Locality + Affinity Scheduling] ..."
    echo "--- RUN: placement=locality sche=3 ---" >> "$LOG_FILE"
    run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 0 0 2>&1 | tee -a "$LOG_FILE" || true
    echo "--- END: placement=locality sche=3 ---" >> "$LOG_FILE"
    sleep "$SLEEP_BETWEEN_RUNS"

    # ----------------------------------------------------------------
    # Locality + Duplication (cache_node sweep)
    # ----------------------------------------------------------------
    for cache_val in 1000000 2000000 4000000; do
        cache_label=$((cache_val / 1000000))M
        CONFIG_NAME="locality_dup_${cache_label}"
        LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"
        echo "# config=$CONFIG_NAME dataset=$ds_name K=$K L=$L T=$T sche=3 relax=0 cache=$cache_val figure=fig14" > "$LOG_FILE"
        echo "[Locality + Dup(${cache_label})] ..."
        echo "--- RUN: placement=locality sche=3 cache=$cache_val ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 0 "$cache_val" 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: placement=locality sche=3 cache=$cache_val ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done

    echo ""
    echo "====== Dataset $ds_name complete ======"
done

echo ""
log_separator
echo " Figure 14 finished: $(timestamp)"
log_separator
