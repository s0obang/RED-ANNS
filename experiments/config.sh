#!/bin/bash
# ============================================================
# RED-ANNS Experiment Configuration
# ============================================================
# CloudLab Wisconsin 환경에 맞게 설정됨.
#
# ⚠️ CloudLab CONTROL NETWORK 경고 ⚠️
# CloudLab은 control network (routable IP, 128.x.x.x)와
# experiment network (private IP, 10.x.x.x)를 엄격히 분리합니다.
# control network의 과도한 사용은 계정 정지/실험 종료를 초래합니다.
#
# 네트워크 매핑 (Phase 1 확인):
#   node-0: ens2f0np0 = 10.10.1.2
#   node-1: ens2f0np0 = 10.10.1.1
#   node-2: ens2f0np0 = 10.10.1.3
#   node-3: ens2f1np1 = 10.10.1.4  ← NIC 이름이 다름!
#
# 노드마다 NIC 이름이 다를 수 있으므로, MPI 설정은
# NIC 이름 대신 서브넷(10.10.1.0/24)으로 제한합니다.
#
# ★★★ 수정이 필요한 항목은 ★ 표시 ★★★
# ============================================================

# ---- 클러스터 설정 ----
HOSTFILE="../hosts.mpi"
HOSTS_FILE="../hosts"

# ★ Experiment network 서브넷 ★
# 노드별 NIC 이름이 다르므로 (node-3: ens2f1np1) 서브넷으로 지정
EXPERIMENT_SUBNET="10.10.1.0/24"

# ---- NUMA 바인딩 ----
# Xeon Silver 4314 (2소켓):
#   NUMA node0: CPU 0-15,32-47
#   NUMA node1: CPU 16-31,48-63
NUMA_OPTS="numactl --cpunodebind=0 --membind=0"

# ---- 바이너리 경로 ----
BIN_DISTRIBUTED="../build/tests/test_search_distributed"
BIN_MAP_REDUCE="../build/tests/test_map_reduce"

# ---- 데이터셋 설정 ----
# ⚠️ 디스크 공간 ~57Gi 제한. 추가 스토리지 마운트 권장.
DATASETS=(
    "deep100M:../app/deep100M_K4.json"
    # "msturing:../app/msturing100M_K4.json"
    # "text2image:../app/text2image100M_K4.json"
    # "laion:../app/laion100M-512D_K4.json"
)

# ---- 공통 실험 파라미터 ----
K=10                                     # Top-K (논문 기본값)
T=8                                      # Threads per node (논문: 8)

# ---- Figure 10: QPS vs Recall@10 ----
L_VALUES=(15 20 30 40 50 60 70 80 90 100 120 140 160 200)

# ---- Figure 11: Top-K sweep ----
K_VALUES=(1 10 100)
L_FOR_RECALL09=100

# ---- Figure 14/15: Remote access analysis ----
CACHE_NODE_VALUES=(0)

# ---- Figure 16(a): RBFS relax sweep ----
RELAX_VALUES=(0 1 2 3)
L_FOR_RELAX=100

# ---- Figure 16(b): PQ pruning ----
EPSILON_VALUES=(0.8 0.9 1.0 1.1 1.2)

# sche_strategy: 1=Random, 2=IVF, 3=Graph(Affinity)

# ---- 출력 설정 ----
RESULTS_DIR="./results"
LOG_DIR="./logs"
SLEEP_BETWEEN_RUNS=3

# ---- 헬퍼 함수 ----
get_num_servers() {
    local count=0
    while IFS= read -r line; do
        [[ -n "$line" ]] && count=$((count + 1))
    done < "$HOSTFILE"
    echo "$count"
}

run_mpi() {
    local binary="$1"
    shift
    local num_servers
    num_servers=$(get_num_servers)

    # ⚠️ CloudLab 네트워크 안전 설정:
    #
    # 노드별 NIC 이름이 다를 수 있으므로 (node-3: ens2f1np1 vs 나머지: ens2f0np0)
    # NIC 이름 대신 서브넷으로 MPI 트래픽을 제한합니다.
    #
    #   btl_tcp_if_include: experiment 서브넷만 허용
    #   oob_tcp_if_include: OOB 통신도 experiment 서브넷으로 제한
    #
    # 이 설정이 없으면 MPI가 control network (128.105.x.x)를 사용하여
    # CloudLab 정책 위반이 됩니다.
    mpiexec -hostfile "$HOSTFILE" -n "$num_servers" \
        --mca btl_tcp_if_include "$EXPERIMENT_SUBNET" \
        --mca oob_tcp_if_include "$EXPERIMENT_SUBNET" \
        $NUMA_OPTS \
        "$binary" config "$HOSTS_FILE" "$@"
}

timestamp() {
    date "+%Y-%m-%d_%H-%M-%S"
}

log_separator() {
    echo "============================================"
}
