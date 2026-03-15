#!/bin/bash
# ============================================================
# Figure 10 재현: QPS vs Recall@10 (4개 데이터셋, 4노드 8스레드)
# ============================================================
# 논문 Figure 10에서 비교하는 configuration:
#   1) MR-ANNS        : MapReduce 방식 (test_map_reduce 바이너리)
#   2) Random          : full-GPS + random scheduling (sche=1, relax=0)
#   3) Locality        : full-GPS + locality placement + random scheduling
#   4) Locality+Sched  : full-GPS + locality + affinity scheduling (sche=3)
#   5) RED-ANNS        : full-GPS + locality + affinity + RBFS (sche=3, relax=3)
#
# NOTE: Random vs Locality의 차이는 "데이터 배치(partition)"에 있음.
#   - Random 배치: bkmeans 없이 랜덤 파티션된 데이터 사용
#   - Locality 배치: bkmeans centroids 기반 파티션 (JSON 기본값)
#   현재 코드는 JSON의 bkmeans_centroids를 항상 로드하므로
#   Random 배치를 위해서는 별도의 random-partition JSON이 필요.
#   이 스크립트에서는 Locality 배치를 기본으로 하고
#   sche=1(random scheduling)로 차이를 줌.
#
# 사용법:
#   cd experiments
#   bash run_fig10.sh [dataset_name]
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
TARGET_DATASET="${1:-}"

log_separator
echo " RED-ANNS Figure 10 Reproduction"
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
    LOG_PREFIX="$LOG_DIR/fig10_${ds_name}_${TS}"

    # ----------------------------------------------------------------
    # [1/5] MR-ANNS (MapReduce baseline)
    # ----------------------------------------------------------------
    echo "[1/5] MR-ANNS (MapReduce)..."
    CONFIG_NAME="mr_anns"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    echo "# config=$CONFIG_NAME dataset=$ds_name K=$K T=$T" > "$LOG_FILE"
    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        TMP_JSON="/tmp/fig10_${ds_name}_L${L}.json"
        python3 "$SCRIPT_DIR/make_tmp_json.py" "$ds_json" "$TMP_JSON" \
            --K "$K" --L "$L" --T "$T" 2>/dev/null || \
            cp "$ds_json" "$TMP_JSON"

        run_mpi "$BIN_MAP_REDUCE" "$TMP_JSON" 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    # ----------------------------------------------------------------
    # [2/5] Random (full-GPS, random scheduling, no relax)
    # ----------------------------------------------------------------
    echo "[2/5] Random (sche=1, relax=0)..."
    CONFIG_NAME="random"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    echo "# config=$CONFIG_NAME dataset=$ds_name K=$K T=$T sche=1 relax=0 cache=0" > "$LOG_FILE"
    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 1 0 0 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    # ----------------------------------------------------------------
    # [3/5] Locality (locality-aware placement + random scheduling)
    # NOTE: sche=1이지만 bkmeans partition이 적용된 데이터 사용
    # ----------------------------------------------------------------
    echo "[3/5] Locality (sche=1, relax=0, locality data)..."
    CONFIG_NAME="locality"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    echo "# config=$CONFIG_NAME dataset=$ds_name K=$K T=$T sche=1 relax=0 cache=0" > "$LOG_FILE"
    echo "# NOTE: locality-aware placement (bkmeans partition)" >> "$LOG_FILE"
    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 1 0 0 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    # ----------------------------------------------------------------
    # [4/5] Locality + Scheduling (affinity scheduling, no RBFS)
    # ----------------------------------------------------------------
    echo "[4/5] Locality+Sched (sche=3, relax=0)..."
    CONFIG_NAME="locality_sched"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    echo "# config=$CONFIG_NAME dataset=$ds_name K=$K T=$T sche=3 relax=0 cache=0" > "$LOG_FILE"
    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 0 0 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    # ----------------------------------------------------------------
    # [5/5] RED-ANNS (Locality + Scheduling + RBFS)
    # ----------------------------------------------------------------
    echo "[5/5] RED-ANNS (sche=3, relax=3)..."
    CONFIG_NAME="red_anns"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    echo "# config=$CONFIG_NAME dataset=$ds_name K=$K T=$T sche=3 relax=3 cache=0" > "$LOG_FILE"
    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 3 0 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    echo ""
    echo "====== Dataset $ds_name complete ======"
done

echo ""
log_separator
echo " Figure 10 finished: $(timestamp)"
echo " Logs: $LOG_DIR/fig10_*"
echo " Next: python3 parse_logs.py --figure fig10 && python3 plot_all.py --figure fig10"
log_separator
