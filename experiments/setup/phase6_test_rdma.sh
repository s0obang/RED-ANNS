#!/bin/bash
# ============================================================
# Phase 6: RDMA 연결 테스트
# ============================================================
# 빌드 완료 후, 실제 데이터셋 실험 전에 RDMA가 동작하는지 확인.
#
# 마스터 노드에서 실행.
# ============================================================

set -euo pipefail

# ★★★ 수정 필요 ★★★
NODE_IPS=(
    "node0"
    "node1"
    "node2"
    "node3"
)
SSH_USER="${USER}"

echo "=========================================="
echo " RDMA Connectivity Test"
echo "=========================================="
echo ""

# ---- Test 1: ibv_devinfo 확인 ----
echo "=== [1/4] ibv_devinfo on all nodes ==="
for node in "${NODE_IPS[@]}"; do
    echo "--- $node ---"
    ssh "${SSH_USER}@${node}" "ibv_devinfo 2>/dev/null | head -15" || echo "  FAILED"
    echo ""
done

# ---- Test 2: MPI 통신 테스트 ----
echo "=== [2/4] MPI basic test ==="
REDANNS_DIR="$HOME/RED-ANNS"
cd "$REDANNS_DIR"

echo "  Running: mpiexec -hostfile hosts.mpi -n 4 hostname"
mpiexec -hostfile hosts.mpi -n 4 hostname 2>&1 || {
    echo "  FAILED! MPI 통신 문제."
    echo "  확인사항:"
    echo "    1) 노드 간 SSH 무비밀번호 접속"
    echo "    2) hosts.mpi 파일의 IP가 정확한지"
    echo "    3) --mca btl_tcp_if_include <NIC> 옵션"
}
echo ""

# ---- Test 3: RDMA bandwidth test (ib_write_bw) ----
echo "=== [3/4] RDMA bandwidth test ==="
echo "  (node0 ↔ node1 간 ib_write_bw)"
echo ""

SERVER="${NODE_IPS[0]}"
CLIENT="${NODE_IPS[1]}"

# 서버 시작 (백그라운드)
echo "  Starting server on $SERVER..."
ssh "${SSH_USER}@${SERVER}" "ib_write_bw -d mlx5_0 --report_gbits -D 3 2>/dev/null &" || \
ssh "${SSH_USER}@${SERVER}" "ib_write_bw --report_gbits -D 3 2>/dev/null &" || \
    echo "  WARNING: ib_write_bw not available (perftest 패키지 필요)"

sleep 2

# 클라이언트 실행
SERVER_IP=$(head -1 "$REDANNS_DIR/hosts")
echo "  Running client on $CLIENT → $SERVER_IP ..."
ssh "${SSH_USER}@${CLIENT}" "ib_write_bw -d mlx5_0 --report_gbits -D 3 $SERVER_IP 2>/dev/null" || \
ssh "${SSH_USER}@${CLIENT}" "ib_write_bw --report_gbits -D 3 $SERVER_IP 2>/dev/null" || \
    echo "  WARNING: bandwidth test failed (RDMA가 아직 동작하지 않을 수 있음)"

echo ""

# ---- Test 4: RED-ANNS RDMA latency test ----
echo "=== [4/4] RED-ANNS RDMA latency test ==="
if [ -f "$REDANNS_DIR/build/tests/test_rdma_lat" ]; then
    echo "  test_rdma_lat 바이너리 존재"
    echo "  실행: mpiexec -hostfile hosts.mpi -n 2 build/tests/test_rdma_lat config hosts"
    echo ""

    # NIC 인터페이스 자동 감지 시도
    NIC=$(ibdev2netdev 2>/dev/null | head -1 | awk '{print $5}' || echo "eno1")
    echo "  Detected NIC: $NIC"

    mpiexec -hostfile hosts.mpi -n 2 \
        --mca btl_tcp_if_include "$NIC" \
        numactl --cpunodebind=0 --membind=0 \
        "$REDANNS_DIR/build/tests/test_rdma_lat" config "$REDANNS_DIR/hosts" \
        2>&1 | tail -20 || \
        echo "  WARNING: test_rdma_lat failed"
else
    echo "  test_rdma_lat not found (빌드 확인 필요)"
fi
echo ""

echo "=========================================="
echo " RDMA Test Complete!"
echo ""
echo " 모든 테스트 통과 시 → 데이터셋 준비 후 실험 실행"
echo "=========================================="
