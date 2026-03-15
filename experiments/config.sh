#!/bin/bash
# ============================================================
# RED-ANNS Experiment Configuration
# ============================================================
# CloudLab Wisconsin 환경에 맞게 설정됨.
#
# ★★★ 수정이 필요한 항목은 ★ 표시 ★★★
#
# Phase 1 수집 결과:
#   - NIC: ConnectX-6 Dx/Lx, 활성 포트: mlx5_0 (ens2f0np0)
#   - 내부 서브넷: 10.10.1.x/24
#   - CPU: 2× Xeon Silver 4314 (16C/32T each)
#   - NUMA: node0=CPU 0-15,32-47  node1=CPU 16-31,48-63
#   - Memory: 251 Gi per node
#   - Disk: ~57 Gi free (100M 데이터셋에 부족할 수 있음)
# ============================================================

# ---- 클러스터 설정 ----
HOSTFILE="../hosts.mpi"
HOSTS_FILE="../hosts"

# ★ RDMA NIC 인터페이스명 ★
# ibdev2netdev로 확인: mlx5_0 port 1 ==> ens2f0np0 (Up)
# MPI --mca btl_tcp_if_include에 사용
NIC_INTERFACE="ens2f0np0"

# ---- NUMA 바인딩 ----
# Xeon Silver 4314 (2소켓):
#   NUMA node0: CPU 0-15,32-47   (소켓 0)
#   NUMA node1: CPU 16-31,48-63  (소켓 1)
#
# NIC가 어느 NUMA 노드에 연결되어 있는지 확인:
#   cat /sys/class/net/ens2f0np0/device/numa_node
# → NIC가 NUMA 0이면 cpunodebind=0, NUMA 1이면 cpunodebind=1
#
# ★ 기본값: NUMA node 0 (NIC numa_node 확인 후 변경 가능) ★
NUMA_OPTS="numactl --cpunodebind=0 --membind=0"

# ---- 바이너리 경로 ----
BIN_DISTRIBUTED="../build/tests/test_search_distributed"
BIN_MAP_REDUCE="../build/tests/test_map_reduce"

# ---- 데이터셋 설정 ----
# 형식: "이름:JSON경로"
# 먼저 1개 데이터셋으로 테스트 후, 나머지를 주석 해제
#
# ⚠️ 주의: 디스크 공간이 ~57Gi로 제한적임
#   - deep100M: base ~38GB + index ~10GB = ~48GB (타이트)
#   - 작은 데이터셋(deep10M)으로 먼저 테스트 권장
DATASETS=(
    "deep100M:../app/deep100M_K4.json"
    # "msturing:../app/msturing100M_K4.json"
    # "text2image:../app/text2image100M_K4.json"
    # "laion:../app/laion100M-512D_K4.json"
)

# ---- 공통 실험 파라미터 ----
K=10                                     # Top-K (논문 기본값)
T=8                                      # Threads per node (논문: 8)
                                         # CloudLab에선 16C/32T 가능하지만
                                         # 논문 재현을 위해 8 유지

# ---- Figure 10: QPS vs Recall@10 ----
L_VALUES=(15 20 30 40 50 60 70 80 90 100 120 140 160 200)

# ---- Figure 11: Top-K sweep ----
K_VALUES=(1 10 100)
L_FOR_RECALL09=100                       # Recall@K≈0.9이 되는 L 값

# ---- Figure 14/15: Remote access analysis ----
CACHE_NODE_VALUES=(0)                    # 0=no duplication

# ---- Figure 16(a): RBFS relax sweep ----
RELAX_VALUES=(0 1 2 3)
L_FOR_RELAX=100

# ---- Figure 16(b): PQ pruning ----
# NOTE: epsilon은 index.cpp에 하드코딩 → 외부 파라미터로 수정 후 사용
EPSILON_VALUES=(0.8 0.9 1.0 1.1 1.2)

# sche_strategy: 1=Random, 2=IVF, 3=Graph(Affinity)

# ---- 출력 설정 ----
RESULTS_DIR="./results"
LOG_DIR="./logs"
SLEEP_BETWEEN_RUNS=3                     # 실험 간 대기(초)

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
