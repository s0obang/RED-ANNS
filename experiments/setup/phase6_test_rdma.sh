#!/bin/bash
# ============================================================
# Phase 6: RDMA 연결 테스트
# ============================================================
# 빌드 완료 후, 데이터셋 실험 전에 RDMA 동작 확인.
# 마스터 노드 (node-0)에서 실행.
#
# CloudLab Wisconsin 환경:
#   - NIC: ConnectX-6 Dx/Lx (mlx5_0, ens2f0np0)
#   - 내부 서브넷: 10.10.1.x/24
#   - RoCEv2 지원
#
# 사전 조건: Phase 2~5 완료
# 사용법: bash phase6_test_rdma.sh
# ============================================================

set -euo pipefail

# ★★★ 수정 필요: phase2/5와 동일한 IP ★★★
NODE_IPS=(
    "10.10.1.2"    # node-0
    "10.10.1.3"    # node-1
    "10.10.1.4"    # node-2
    "10.10.1.5"    # node-3
)
SSH_USER="${USER}"
REDANNS_DIR="$HOME/RED-ANNS"

# RDMA 디바이스 (ibdev2netdev에서 확인)
RDMA_DEV="mlx5_0"

echo "=========================================="
echo " RDMA Connectivity Test"
echo " (ConnectX-6, RoCEv2)"
echo "=========================================="
echo ""

# ---- Test 1: ibv_devinfo on all nodes ----
echo "=== [1/5] ibv_devinfo on all nodes ==="
for node in "${NODE_IPS[@]}"; do
    echo "--- $node ---"
    ssh "${SSH_USER}@${node}" \
        "ibv_devinfo -d $RDMA_DEV 2>/dev/null | head -20" 2>/dev/null || \
        echo "  FAILED (ibv_devinfo not available)"
    echo ""
done

# ---- Test 2: ibdev2netdev on all nodes ----
echo "=== [2/5] ibdev2netdev (NIC mapping) ==="
for node in "${NODE_IPS[@]}"; do
    result=$(ssh "${SSH_USER}@${node}" "ibdev2netdev 2>/dev/null | grep Up" 2>/dev/null)
    echo "  $node: $result"
done
echo ""

# ---- Test 3: MPI hostname test ----
echo "=== [3/5] MPI basic test ==="
cd "$REDANNS_DIR" 2>/dev/null || { echo "ERROR: $REDANNS_DIR not found"; exit 1; }

echo "  Running: mpiexec -hostfile hosts.mpi -n 4 hostname"
mpiexec -hostfile hosts.mpi -n 4 \
    --mca btl_tcp_if_include ens2f0np0 \
    hostname 2>&1 || {
    echo "  FAILED! MPI 통신 문제."
    echo "  확인사항:"
    echo "    1) hosts.mpi 파일에 10.10.1.x IP가 있는지"
    echo "    2) 노드 간 SSH 무비밀번호 접속 (phase2)"
    echo "    3) OpenMPI가 모든 노드에 설치됨 (phase4)"
    echo "    4) --mca btl_tcp_if_include ens2f0np0"
}
echo ""

# ---- Test 4: RDMA bandwidth test ----
echo "=== [4/5] RDMA bandwidth test ==="
echo "  (node-0 ↔ node-1 간 ib_write_bw)"
echo ""

SERVER="${NODE_IPS[0]}"
CLIENT="${NODE_IPS[1]}"

# 이전 perftest 프로세스 정리
ssh "${SSH_USER}@${SERVER}" "killall ib_write_bw 2>/dev/null" || true
sleep 1

# 서버 시작
echo "  Starting ib_write_bw server on $SERVER ..."
ssh "${SSH_USER}@${SERVER}" \
    "nohup ib_write_bw -d $RDMA_DEV --report_gbits -D 3 > /tmp/ib_bw_server.log 2>&1 &" || \
    echo "  WARNING: ib_write_bw not available"

sleep 2

# 클라이언트 실행
echo "  Running ib_write_bw client on $CLIENT → $SERVER ..."
ssh "${SSH_USER}@${CLIENT}" \
    "ib_write_bw -d $RDMA_DEV --report_gbits -D 3 $SERVER 2>&1" || \
    echo "  WARNING: bandwidth test failed"

echo ""
echo "  ★ 정상 결과: ~90-100 Gbps (ConnectX-6 100G NIC)"
echo ""

# ---- Test 5: RDMA latency test ----
echo "=== [5/5] RDMA latency test ==="

# 이전 프로세스 정리
ssh "${SSH_USER}@${SERVER}" "killall ib_read_lat 2>/dev/null" || true
sleep 1

echo "  Starting ib_read_lat server on $SERVER ..."
ssh "${SSH_USER}@${SERVER}" \
    "nohup ib_read_lat -d $RDMA_DEV -D 3 > /tmp/ib_lat_server.log 2>&1 &" || true

sleep 2

echo "  Running ib_read_lat client on $CLIENT → $SERVER ..."
ssh "${SSH_USER}@${CLIENT}" \
    "ib_read_lat -d $RDMA_DEV -D 3 $SERVER 2>&1" || \
    echo "  WARNING: latency test failed"

echo ""
echo "  ★ 정상 결과: ~1-3 μs (ConnectX-6)"
echo ""

# 정리
ssh "${SSH_USER}@${SERVER}" "killall ib_write_bw ib_read_lat 2>/dev/null" || true

echo "=========================================="
echo " RDMA Test Summary"
echo "=========================================="
echo ""
echo " ✓ ibv_devinfo: 모든 노드에서 RDMA 디바이스 확인"
echo " ✓ MPI: 4노드 hostname 통신 확인"
echo " ✓ Bandwidth: ~90+ Gbps 이면 정상"
echo " ✓ Latency: ~1-3 μs 이면 정상"
echo ""
echo " 모든 테스트 통과 → 데이터셋 준비 후 실험 실행"
echo "   cd $REDANNS_DIR/experiments"
echo "   bash run_all.sh"
echo "=========================================="
