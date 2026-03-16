#!/bin/bash
# ============================================================
# Figure 10 재현: QPS vs Recall@10 (분산 RDMA 검색)
# ============================================================
# test_search_distributed 바이너리를 사용한 4가지 configuration 비교:
#
#   [1/4] Random         : random scheduling, no RBFS (sche=1, relax=0)
#   [2/4] Locality       : random scheduling, locality-aware partition (sche=1, relax=0)
#   [3/4] Locality+Sched : affinity scheduling, no RBFS (sche=3, relax=0)
#   [4/4] RED-ANNS       : affinity scheduling + RBFS (sche=3, relax=3)
#
# NOTE:
#   - MR-ANNS (MapReduce baseline)는 per-node JSON + random-partition 데이터 필요.
#     deep10M mapreduce 데이터가 준비되면 run_fig10_full.sh로 포함 가능.
#   - [1/4] Random vs [2/4] Locality:
#     현재 둘 다 bkmeans partition 데이터를 사용하므로 동일한 결과.
#     진정한 Random 배치 비교는 random-partition 데이터 필요.
#     여기서는 sche=1(random scheduling)의 결과를 기록.
#
# 바이너리 인자 (test_search_distributed, argc=10):
#   argv[1] = "config"
#   argv[2] = hosts_file (10.10.1.x IP 리스트)
#   argv[3] = para_path (JSON 설정 파일)
#   argv[4] = K (Top-K)
#   argv[5] = L (search list size)
#   argv[6] = T (threads per node)
#   argv[7] = sche_strategy (1=Random, 2=IVF, 3=Graph/Affinity)
#   argv[8] = relax (RBFS relax factor, 0=off)
#   argv[9] = cache_node (0=off)
#
# 사용법:
#   cd ~/RED-ANNS/experiments
#   bash run_fig10.sh [dataset_name]
#   bash run_fig10.sh deep10M
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$RESULTS_DIR" "$LOG_DIR"
TARGET_DATASET="${1:-}"

# --- 사전 검증 ---
if [[ ! -f "$BIN_DISTRIBUTED" ]]; then
    echo "ERROR: 바이너리 없음: $BIN_DISTRIBUTED"
    echo "  → bash phase5_build_and_setup.sh 로 빌드하세요."
    exit 1
fi
if [[ ! -f "$HOSTFILE" ]]; then
    echo "ERROR: hosts.mpi 없음: $HOSTFILE"
    echo "  → bash phase5_build_and_setup.sh 로 생성하세요."
    exit 1
fi

NUM_SERVERS=$(get_num_servers)
echo ""
log_separator
echo " RED-ANNS Figure 10 Reproduction"
echo " Start: $(timestamp)"
echo " Servers: $NUM_SERVERS  K=$K  T=$T  L_VALUES=(${L_VALUES[*]})"
echo " Binary: $BIN_DISTRIBUTED"
log_separator

TOTAL_RUNS=0
FAILED_RUNS=0

for ds_entry in "${DATASETS[@]}"; do
    ds_name="${ds_entry%%:*}"
    ds_json="${ds_entry##*:}"

    if [[ -n "$TARGET_DATASET" && "$ds_name" != "$TARGET_DATASET" ]]; then
        continue
    fi

    # JSON 파일 존재 확인
    if [[ ! -f "$ds_json" ]]; then
        echo "WARNING: JSON 파일 없음: $ds_json — 스킵"
        continue
    fi

    echo ""
    echo "====== Dataset: $ds_name ======"
    echo "  JSON: $ds_json"

    TS="$(timestamp)"
    LOG_PREFIX="$LOG_DIR/fig10_${ds_name}_${TS}"

    # ----------------------------------------------------------------
    # [1/4] Random scheduling (sche=1, relax=0, cache=0)
    # ----------------------------------------------------------------
    echo ""
    echo "[1/4] Random (sche=1, relax=0)..."
    CONFIG_NAME="random"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    {
        echo "# Figure 10 — $CONFIG_NAME"
        echo "# dataset=$ds_name  K=$K  T=$T  sche=1  relax=0  cache=0"
        echo "# servers=$NUM_SERVERS  json=$ds_json"
        echo "# started=$(timestamp)"
    } > "$LOG_FILE"

    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        if run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 1 0 0 2>&1 | tee -a "$LOG_FILE"; then
            :
        else
            echo "  ⚠ L=$L failed (exit=$?)" | tee -a "$LOG_FILE"
            FAILED_RUNS=$((FAILED_RUNS + 1))
        fi
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        TOTAL_RUNS=$((TOTAL_RUNS + 1))
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    # ----------------------------------------------------------------
    # [2/4] Locality+Random scheduling (sche=1, relax=0)
    # NOTE: 데이터는 bkmeans locality partition 사용.
    #       sche=1이므로 쿼리 배정은 random.
    #       [1/4]과 동일한 파라미터지만 별도 기록 (향후 random-partition 추가 시 구분).
    # ----------------------------------------------------------------
    echo ""
    echo "[2/4] Locality (sche=1, relax=0, locality data)..."
    CONFIG_NAME="locality"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    {
        echo "# Figure 10 — $CONFIG_NAME"
        echo "# dataset=$ds_name  K=$K  T=$T  sche=1  relax=0  cache=0"
        echo "# NOTE: locality-aware bkmeans partition (same as random until random-partition data ready)"
        echo "# servers=$NUM_SERVERS  json=$ds_json"
        echo "# started=$(timestamp)"
    } > "$LOG_FILE"

    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        if run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 1 0 0 2>&1 | tee -a "$LOG_FILE"; then
            :
        else
            echo "  ⚠ L=$L failed (exit=$?)" | tee -a "$LOG_FILE"
            FAILED_RUNS=$((FAILED_RUNS + 1))
        fi
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        TOTAL_RUNS=$((TOTAL_RUNS + 1))
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    # ----------------------------------------------------------------
    # [3/4] Locality + Affinity Scheduling (sche=3, relax=0)
    # ----------------------------------------------------------------
    echo ""
    echo "[3/4] Locality+Sched (sche=3, relax=0)..."
    CONFIG_NAME="locality_sched"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    {
        echo "# Figure 10 — $CONFIG_NAME"
        echo "# dataset=$ds_name  K=$K  T=$T  sche=3  relax=0  cache=0"
        echo "# servers=$NUM_SERVERS  json=$ds_json"
        echo "# started=$(timestamp)"
    } > "$LOG_FILE"

    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        if run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 0 0 2>&1 | tee -a "$LOG_FILE"; then
            :
        else
            echo "  ⚠ L=$L failed (exit=$?)" | tee -a "$LOG_FILE"
            FAILED_RUNS=$((FAILED_RUNS + 1))
        fi
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        TOTAL_RUNS=$((TOTAL_RUNS + 1))
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    # ----------------------------------------------------------------
    # [4/4] RED-ANNS (Locality + Scheduling + RBFS)
    # ----------------------------------------------------------------
    echo ""
    echo "[4/4] RED-ANNS (sche=3, relax=3)..."
    CONFIG_NAME="red_anns"
    LOG_FILE="${LOG_PREFIX}_${CONFIG_NAME}.log"

    {
        echo "# Figure 10 — $CONFIG_NAME"
        echo "# dataset=$ds_name  K=$K  T=$T  sche=3  relax=3  cache=0"
        echo "# servers=$NUM_SERVERS  json=$ds_json"
        echo "# started=$(timestamp)"
    } > "$LOG_FILE"

    for L in "${L_VALUES[@]}"; do
        echo "  L=$L ..."
        echo "--- RUN: L=$L ---" >> "$LOG_FILE"
        if run_mpi "$BIN_DISTRIBUTED" "$ds_json" "$K" "$L" "$T" 3 3 0 2>&1 | tee -a "$LOG_FILE"; then
            :
        else
            echo "  ⚠ L=$L failed (exit=$?)" | tee -a "$LOG_FILE"
            FAILED_RUNS=$((FAILED_RUNS + 1))
        fi
        echo "--- END: L=$L ---" >> "$LOG_FILE"
        TOTAL_RUNS=$((TOTAL_RUNS + 1))
        sleep "$SLEEP_BETWEEN_RUNS"
    done
    echo "  → Log: $LOG_FILE"

    echo ""
    echo "====== Dataset $ds_name complete ======"
done

echo ""
log_separator
echo " Figure 10 finished: $(timestamp)"
echo " Total runs: $TOTAL_RUNS  Failed: $FAILED_RUNS"
echo " Logs: $LOG_DIR/fig10_*"
if [[ $FAILED_RUNS -gt 0 ]]; then
    echo " ⚠ $FAILED_RUNS run(s) failed — check logs"
fi
echo " Next: python3 parse_logs.py --figure fig10 && python3 plot_all.py --figure fig10"
log_separator
