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
# 이 설정은 모든 실험 트래픽이 experiment network (10.10.1.x)를
# 통해서만 흐르도록 구성되어 있습니다.
# - hosts 파일: 10.10.1.x IP만 사용
# - MPI: btl_tcp_if_include + oob_tcp_if_include로 NIC 지정
# - RDMA: experiment NIC (mlx5_0/ens2f0np0)의 dev_id=0 사용
#
# ★★★ 수정이 필요한 항목은 ★ 표시 ★★★
# ============================================================

# ---- 클러스터 설정 ----
HOSTFILE="../hosts.mpi"
HOSTS_FILE="../hosts"

# ★ RDMA NIC 인터페이스명 (experiment network) ★
# 반드시 10.10.1.x 주소가 할당된 NIC를 사용해야 합니다.
# ibdev2netdev로 확인: mlx5_0 port 1 ==> ens2f0np0 (Up)
#
# ⚠️ 절대 control network NIC (128.105.x.x, ens1f0np0 등)을
#    사용하지 마세요. CloudLab 정책 위반입니다.
NIC_INTERFACE="ens2f0np0"

# ---- NUMA 바인딩 ----
# Xeon Silver 4314 (2소켓):
#   NUMA node0: CPU 0-15,32-47   (소켓 0)
#   NUMA node1: CPU 16-31,48-63  (소켓 1)
#
# NIC NUMA affinity 확인:
#   cat /sys/class/net/ens2f0np0/device/numa_node
# → NIC가 NUMA 0이면 cpunodebind=0, NUMA 1이면 cpunodebind=1
NUMA_OPTS="numactl --cpunodebind=0 --membind=0"

# ---- 바이너리 경로 ----
BIN_DISTRIBUTED="../build/tests/test_search_distributed"
BIN_MAP_REDUCE="../build/tests/test_map_reduce"

# ---- 데이터셋 설정 ----
# 형식: "이름:JSON경로"
#
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
    #   --mca btl_tcp_if_include: MPI 데이터 전송을 experiment NIC로 제한
    #   --mca oob_tcp_if_include: MPI OOB(out-of-band) 통신도 experiment NIC로 제한
    #   --mca btl_tcp_if_exclude: control network NIC 명시적 차단 (이중 안전)
    #
    # 이 설정이 없으면 MPI가 control network (128.105.x.x)를 사용할 수 있어
    # CloudLab 정책 위반이 됩니다.
    mpiexec -hostfile "$HOSTFILE" -n "$num_servers" \
        --mca btl_tcp_if_include "$NIC_INTERFACE" \
        --mca oob_tcp_if_include "$NIC_INTERFACE" \
        --mca btl_tcp_if_exclude lo,ens1f0np0,ens1f1np1,enp177s0f0np0,enp177s0f1np1 \
        $NUMA_OPTS \
        "$binary" config "$HOSTS_FILE" "$@"
}

timestamp() {
    date "+%Y-%m-%d_%H-%M-%S"
}

log_separator() {
    echo "============================================"
}
