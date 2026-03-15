#!/bin/bash
# ============================================================
# Phase 6: RDMA 연결 테스트
# ============================================================
# 빌드 완료 후, 데이터셋 실험 전에 RDMA 동작 확인.
# 마스터 노드 (node-0)에서 실행.
#
# ★ CloudLab 듀얼 네트워크 구조 ★
#   - SSH 접속 (테스트 명령 전달): hostname (control network)
#   - MPI 실행: experiment IP (10.10.1.x, 서브넷 제한)
#   - RDMA: experiment NIC의 mlx5 디바이스 (자동 감지)
#   - ib_write_bw/ib_read_lat: experiment IP로 서버 지정
#
# 사전 조건: Phase 2~5 완료
# 사용법: bash phase6_test_rdma.sh
# ============================================================

set -euo pipefail

# ★★★ 듀얼 주소 설정 ★★★
# hostname: SSH 접속용
NODE_HOSTNAMES=(
    "node-0"
    "node-1"
    "node-2"
    "node-3"
)

# experiment IP: MPI/RDMA 트래픽용
NODE_EXP_IPS=(
    "10.10.1.2"    # node-0
    "10.10.1.1"    # node-1
    "10.10.1.3"    # node-2
    "10.10.1.4"    # node-3
)

SSH_USER="${USER}"
REDANNS_DIR="$HOME/RED-ANNS"

# Experiment network 서브넷
EXP_SUBNET="10.10.1.0/24"

echo "=========================================="
echo " RDMA Connectivity Test"
echo " (SSH via hostname, RDMA via 10.10.1.x)"
echo "=========================================="
echo ""

# ---- Pre-check: 각 노드의 experiment NIC + RDMA 디바이스 자동 감지 ----
echo "=== [Pre-check] Per-node experiment NIC & RDMA device ==="
declare -A NODE_RDMA_DEV  # node hostname → mlx5_X 디바이스

for i in "${!NODE_HOSTNAMES[@]}"; do
    node="${NODE_HOSTNAMES[$i]}"
    exp_ip="${NODE_EXP_IPS[$i]}"

    # SSH로 접속하여 experiment IP가 할당된 NIC 이름 + RDMA 디바이스 확인
    NODE_NIC=$(ssh -o StrictHostKeyChecking=no "${SSH_USER}@${node}" \
        "ip -4 addr show | grep '${exp_ip}/' | awk '{print \$NF}'" 2>/dev/null || echo "")
    NODE_RDEV=$(ssh -o StrictHostKeyChecking=no "${SSH_USER}@${node}" \
        "ibdev2netdev 2>/dev/null | grep '${NODE_NIC}' | awk '{print \$1}'" 2>/dev/null || echo "")

    if [[ -z "$NODE_NIC" ]]; then
        echo "  $node ($exp_ip): ✗ WARNING: NIC not found for $exp_ip"
    elif [[ -z "$NODE_RDEV" ]]; then
        echo "  $node ($exp_ip): NIC=$NODE_NIC  RDMA_DEV=unknown (ibdev2netdev 확인)"
    else
        echo "  $node ($exp_ip): NIC=$NODE_NIC  RDMA_DEV=$NODE_RDEV"
        NODE_RDMA_DEV[$node]="$NODE_RDEV"
    fi
done

# 기본 RDMA 디바이스 (대부분의 노드에서 사용)
DEFAULT_RDMA_DEV="${NODE_RDMA_DEV[${NODE_HOSTNAMES[0]}]:-mlx5_0}"
echo ""
echo "  Default RDMA device: $DEFAULT_RDMA_DEV"
echo ""

# ---- Test 1: ibv_devinfo on all nodes (SSH via hostname) ----
echo "=== [1/5] ibv_devinfo on all nodes ==="
for i in "${!NODE_HOSTNAMES[@]}"; do
    node="${NODE_HOSTNAMES[$i]}"
    rdev="${NODE_RDMA_DEV[$node]:-$DEFAULT_RDMA_DEV}"
    echo "--- $node (device: $rdev) ---"
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${node}" \
        "ibv_devinfo -d $rdev 2>/dev/null | head -20" 2>/dev/null || \
        echo "  FAILED (ibv_devinfo 미설치? phase3 확인)"
    echo ""
done

# ---- Test 2: ibdev2netdev → experiment NIC 매핑 확인 ----
echo "=== [2/5] ibdev2netdev (NIC mapping) ==="
for node in "${NODE_HOSTNAMES[@]}"; do
    result=$(ssh -o StrictHostKeyChecking=no "${SSH_USER}@${node}" \
        "ibdev2netdev 2>/dev/null | grep Up" 2>/dev/null || echo "FAILED")
    echo "  $node: $result"
done
echo ""

# ---- Test 3: MPI hostname test (experiment network, 서브넷 제한) ----
echo "=== [3/5] MPI basic test ==="
cd "$REDANNS_DIR" 2>/dev/null || { echo "ERROR: $REDANNS_DIR not found"; exit 1; }

if [ ! -f hosts.mpi ]; then
    echo "  ERROR: hosts.mpi not found! phase5_build_and_setup.sh를 먼저 실행하세요."
    exit 1
fi

echo "  hosts.mpi 내용:"
cat hosts.mpi
echo ""
echo "  Running: mpiexec -hostfile hosts.mpi -n 4 hostname"
echo "  (btl+oob restricted to subnet $EXP_SUBNET)"
mpiexec -hostfile hosts.mpi -n 4 \
    --mca btl_tcp_if_include "$EXP_SUBNET" \
    --mca oob_tcp_if_include "$EXP_SUBNET" \
    hostname 2>&1 || {
    echo "  FAILED!"
    echo ""
    echo "  확인사항:"
    echo "    1) hosts.mpi에 10.10.1.x IP만 있는지 확인 (FQDN/128.x.x.x 사용 금지!)"
    echo "    2) 모든 노드 간 experiment IP SSH 가능한지:"
    echo "       ssh 10.10.1.1 hostname"
    echo "       ssh 10.10.1.2 hostname"
    echo "       (phase2에서 설정됨)"
    echo "    3) OpenMPI가 모든 노드에 설치되었는지 (phase4)"
}
echo ""

# ---- Test 4: RDMA bandwidth test ----
echo "=== [4/5] RDMA bandwidth test ==="

# SSH는 hostname으로 접속, ib_write_bw의 서버 주소는 experiment IP 사용
SERVER_HOST="${NODE_HOSTNAMES[0]}"
CLIENT_HOST="${NODE_HOSTNAMES[1]}"
SERVER_EXP_IP="${NODE_EXP_IPS[0]}"
SERVER_RDEV="${NODE_RDMA_DEV[$SERVER_HOST]:-$DEFAULT_RDMA_DEV}"
CLIENT_RDEV="${NODE_RDMA_DEV[$CLIENT_HOST]:-$DEFAULT_RDMA_DEV}"

echo "  Server: $SERVER_HOST ($SERVER_EXP_IP, device=$SERVER_RDEV)"
echo "  Client: $CLIENT_HOST (device=$CLIENT_RDEV)"
echo ""

# 이전 perftest 프로세스 정리 (SSH via hostname)
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_HOST}" \
    "killall ib_write_bw 2>/dev/null" || true
sleep 1

# 서버 시작 (SSH via hostname, RDMA device 지정)
echo "  Starting ib_write_bw server on $SERVER_HOST..."
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_HOST}" \
    "nohup ib_write_bw -d $SERVER_RDEV --report_gbits -D 3 \
     > /tmp/ib_bw_server.log 2>&1 &" || \
    echo "  WARNING: ib_write_bw not available (perftest 패키지 확인)"

sleep 2

# 클라이언트: SSH는 hostname으로 접속하되, ib_write_bw의 대상은 experiment IP
echo "  Running ib_write_bw client on $CLIENT_HOST → $SERVER_EXP_IP..."
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
    "ib_write_bw -d $CLIENT_RDEV --report_gbits -D 3 $SERVER_EXP_IP 2>&1" || \
    echo "  WARNING: bandwidth test failed"

echo ""
echo "  ★ 정상 결과: ~90-100 Gbps (ConnectX-6 100G NIC)"
echo ""

# ---- Test 5: RDMA latency test ----
echo "=== [5/5] RDMA latency test ==="

ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_HOST}" \
    "killall ib_read_lat 2>/dev/null" || true
sleep 1

echo "  Starting ib_read_lat server on $SERVER_HOST..."
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_HOST}" \
    "nohup ib_read_lat -d $SERVER_RDEV -D 3 \
     > /tmp/ib_lat_server.log 2>&1 &" || true

sleep 2

echo "  Running ib_read_lat client on $CLIENT_HOST → $SERVER_EXP_IP..."
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
    "ib_read_lat -d $CLIENT_RDEV -D 3 $SERVER_EXP_IP 2>&1" || \
    echo "  WARNING: latency test failed"

echo ""
echo "  ★ 정상 결과: ~1-3 us (ConnectX-6)"
echo ""

# 정리
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_HOST}" \
    "killall ib_write_bw ib_read_lat 2>/dev/null" || true

# ---- Control network traffic 확인 안내 ----
echo "=== [Bonus] Control network traffic check ==="
echo "  아래 명령으로 control network 트래픽이 없는지 확인하세요:"
echo "  (SSH 제외, 실험 트래픽이 보이면 안 됨)"
echo ""
echo "    sudo tcpdump -c 50 -n -i ens1f0np0 not port 22 and not arp"
echo ""
echo "  CloudLab 웹 UI → Experiment → Graphs → Control Traffic도 확인"
echo ""

echo "=========================================="
echo " RDMA Test Summary"
echo "=========================================="
echo ""
echo " Network architecture:"
echo "   SSH commands: hostname → control network"
echo "   MPI/RDMA:    10.10.1.x → experiment network"
echo ""
echo " Default RDMA device: $DEFAULT_RDMA_DEV"
echo " Expected bandwidth: ~90-100 Gbps"
echo " Expected latency: ~1-3 us"
echo ""
echo " 모든 테스트 통과 → 데이터셋 준비 후 실험 실행"
echo "   cd $REDANNS_DIR/experiments"
echo "   bash run_all.sh"
echo "=========================================="
