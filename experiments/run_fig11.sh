#!/bin/bash
# ============================================================
# Figure 11 재현: Top-K sweep (K=1,10,100 at Recall@K=0.9)
# ============================================================
# 논문 Figure 11: 7가지 시스템을 Top-1, Top-10, Top-100에서 비교.
# 여기서는 MR-ANNS와 RED-ANNS 변형들만 재현.
# (Milvus, Vearch, Elasticsearch는 별도 시스템 필요)
#
# 사용법:
#   cd experiments
#   bash run_fig11.sh [dataset_name]
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
TARGET_DATASET="${1:-}"

log_separator
echo " RED-ANNS Figure 11 Reproduction"
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
    LOG_PREFIX="$LOG_DIR/fig11_${ds_name}_${TS}"

    L="$L_FOR_RECALL09"

    for K_VAL in "${K_VALUES[@]}"; do
        echo ""
        echo "--- K=$K_VAL ---"

        # MR-ANNS
        CONFIG_NAME="mr_anns_K${K_VAL}"
        LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"
        echo "# config=mr_anns dataset=$ds_name K=$K_VAL L=$L T=$T figure=fig11" > "$LOG_FILE"
        echo "  [MR-ANNS] K=$K_VAL ..."
        echo "--- RUN: K=$K_VAL ---" >> "$LOG_FILE"
        TMP_JSON="/tmp/fig11_${ds_name}_K${K_VAL}.json"
        python3 "$SCRIPT_DIR/make_tmp_json.py" "$ds_json" "$TMP_JSON" \
            --K "$K_VAL" --L "$L" --T "$T" 2>/dev/null || cp "$ds_json" "$TMP_JSON"
        run_mpi "$BIN_MAP_REDUCE" "$TMP_JSON" 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: K=$K_VAL ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"

        # Random (sche=1, relax=0)
        CONFIG_NAME="random_K${K_VAL}"
        LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"
        echo "# config=random dataset=$ds_name K=$K_VAL L=$L T=$T sche=1 relax=0 cache=0 figure=fig11" > "$LOG_FILE"
        echo "  [Random] K=$K_VAL ..."
        echo "--- RUN: K=$K_VAL ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K_VAL" "$L" "$T" 1 0 0 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: K=$K_VAL ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"

        # Locality (sche=3, relax=0)
        CONFIG_NAME="locality_K${K_VAL}"
        LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"
        echo "# config=locality dataset=$ds_name K=$K_VAL L=$L T=$T sche=3 relax=0 cache=0 figure=fig11" > "$LOG_FILE"
        echo "  [Locality] K=$K_VAL ..."
        echo "--- RUN: K=$K_VAL ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K_VAL" "$L" "$T" 3 0 0 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: K=$K_VAL ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"

        # RED-ANNS (sche=3, relax=3)
        CONFIG_NAME="red_anns_K${K_VAL}"
        LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"
        echo "# config=red_anns dataset=$ds_name K=$K_VAL L=$L T=$T sche=3 relax=3 cache=0 figure=fig11" > "$LOG_FILE"
        echo "  [RED-ANNS] K=$K_VAL ..."
        echo "--- RUN: K=$K_VAL ---" >> "$LOG_FILE"
        run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K_VAL" "$L" "$T" 3 3 0 2>&1 | tee -a "$LOG_FILE" || true
        echo "--- END: K=$K_VAL ---" >> "$LOG_FILE"
        sleep "$SLEEP_BETWEEN_RUNS"
    done

    echo ""
    echo "====== Dataset $ds_name complete ======"
done

echo ""
log_separator
echo " Figure 11 finished: $(timestamp)"
log_separator
