#!/bin/bash
# ============================================================
# RED-ANNS Experiment Configuration
# ============================================================
# 이 파일을 환경에 맞게 수정한 후 실험 스크립트를 실행하세요.
#
# 수정 필요 항목:
#   1. NIC_INTERFACE: RDMA NIC 인터페이스명 (ibdev2netdev 또는 ibstat으로 확인)
#   2. NUMA_OPTS: 노드의 NUMA topology에 맞게 설정
#   3. DATASETS: 재현할 데이터셋 선택
#   4. global.hpp의 num_servers를 4로 설정 후 빌드
# ============================================================

# ---- 클러스터 설정 ----
HOSTFILE="../hosts.mpi"
HOSTS_FILE="../hosts"
NIC_INTERFACE="eno1"                    # RDMA NIC 인터페이스명

# ---- NUMA 바인딩 ----
# sm110p (single socket): --cpunodebind=0 --membind=0
# sm220u (dual socket):   --cpunodebind=1 --membind=1
# 이종 노드 혼합 시 각 노드에 맞는 바인딩이 필요하지만,
# mpiexec는 동일한 옵션을 모든 노드에 적용하므로
# 안전한 기본값 사용:
NUMA_OPTS="numactl --cpunodebind=0 --membind=0"

# ---- 바이너리 경로 ----
BIN_DISTRIBUTED="../build/tests/test_search_distributed"
BIN_MAP_REDUCE="../build/tests/test_map_reduce"

# ---- 데이터셋 설정 ----
# 재현할 데이터셋의 JSON 설정 파일 경로
# 사용 가능한 데이터셋 (주석 해제하여 사용):
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
# L을 변화시켜 recall 조절 (L이 클수록 recall↑, QPS↓)
L_VALUES=(15 20 30 40 50 60 70 80 90 100 120 140 160 200)

# ---- Figure 11: Top-K sweep ----
K_VALUES=(1 10 100)
L_FOR_RECALL09=100                       # Recall@K~0.9이 되는 L 값

# ---- Figure 14/15: Remote access analysis ----
# cache_node 값 (duplication 규모)
CACHE_NODE_VALUES=(0)                    # 0=no duplication

# ---- Figure 16(a): RBFS relax sweep ----
RELAX_VALUES=(0 1 2 3)
L_FOR_RELAX=100

# ---- Figure 16(b): PQ pruning ----
# NOTE: epsilon은 현재 코드에 하드코딩 (index.cpp line ~1182)
# 외부 파라미터로 수정 후 사용
EPSILON_VALUES=(0.8 0.9 1.0 1.1 1.2)

# sche_strategy: 1=Random, 2=IVF, 3=Graph(Affinity)

# ---- 출력 설정 ----
RESULTS_DIR="./results"
LOG_DIR="./logs"
SLEEP_BETWEEN_RUNS=3                     # 실험 간 대기 시간(초)

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
    mpiexec -hostfile "$HOSTFILE" -n "$num_servers" \
        --mca btl_tcp_if_include "$NIC_INTERFACE" \
        $NUMA_OPTS \
        "$binary" config "$HOSTS_FILE" "$@"
}

timestamp() {
    date "+%Y-%m-%d_%H-%M-%S"
}

log_separator() {
    echo "============================================"
}
