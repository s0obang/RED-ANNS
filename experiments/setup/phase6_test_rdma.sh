#!/bin/bash
# ============================================================
# Phase 6: RDMA 연결 테스트
# ============================================================
# 빌드 완료 후, 데이터셋 실험 전에 RDMA 동작 확인.
# 마스터 노드 (node-0)에서 실행.
#
# ⚠️ CloudLab Control Network 주의:
#   모든 테스트 트래픽이 experiment network (10.10.1.x, ens2f0np0)를
#   통해서만 흘러야 합니다. control network (128.105.x.x) 사용 금지.
#
# 사전 조건: Phase 2~5 완료
# 사용법: bash phase6_test_rdma.sh
# ============================================================

set -euo pipefail

# ★★★ 수정 필요: experiment network IP (10.10.1.x) 사용 ★★★
# ⚠️ 절대 control network IP (128.105.x.x)를 넣지 마세요!
NODE_IPS=(
    "10.10.1.2"    # node-0
    "10.10.1.3"    # node-1
    "10.10.1.4"    # node-2
    "10.10.1.5"    # node-3
)
SSH_USER="${USER}"
REDANNS_DIR="$HOME/RED-ANNS"

# RDMA 디바이스 (experiment network NIC)
# ibdev2netdev에서 확인: mlx5_0 → ens2f0np0 (10.10.1.x)
# ⚠️ mlx5_4 (ens1f0np0, 128.105.x.x)는 control network이므로 사용 금지!
RDMA_DEV="mlx5_0"

# Experiment network NIC
EXP_NIC="ens2f0np0"

echo "=========================================="
echo " RDMA Connectivity Test"
echo " (experiment network only: 10.10.1.x)"
echo "=========================================="
echo ""

# ---- Pre-check: experiment network 확인 ----
echo "=== [Pre-check] Network interface verification ==="
echo "  Expected: RDMA dev=$RDMA_DEV → NIC=$EXP_NIC → 10.10.1.x"
echo ""

# 로컬 노드에서 확인
LOCAL_DEV_NIC=$(ibdev2netdev 2>/dev/null | grep "$RDMA_DEV" | awk '{print $5}' || echo "unknown")
LOCAL_NIC_IP=$(ip -4 addr show "$EXP_NIC" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 || echo "unknown")

echo "  Local: $RDMA_DEV → $LOCAL_DEV_NIC (IP: $LOCAL_NIC_IP)"

if [[ "$LOCAL_NIC_IP" == 10.* ]]; then
    echo "  ✓ Experiment network IP confirmed (10.x.x.x)"
else
    echo "  ✗ WARNING: IP is not 10.x.x.x! RDMA 트래픽이 control network를 탈 수 있습니다!"
    echo "  RDMA_DEV를 확인하세요: ibdev2netdev"
    exit 1
fi
echo ""

# ---- Test 1: ibv_devinfo on all nodes ----
echo "=== [1/5] ibv_devinfo on all nodes ==="
for node in "${NODE_IPS[@]}"; do
    echo "--- $node ---"
    ssh "${SSH_USER}@${node}" \
        "ibv_devinfo -d $RDMA_DEV 2>/dev/null | head -20" 2>/dev/null || \
        echo "  FAILED"
    echo ""
done

# ---- Test 2: ibdev2netdev → experiment NIC 매핑 확인 ----
echo "=== [2/5] ibdev2netdev (NIC mapping) ==="
for node in "${NODE_IPS[@]}"; do
    result=$(ssh "${SSH_USER}@${node}" "ibdev2netdev 2>/dev/null | grep '$RDMA_DEV'" 2>/dev/null)
    echo "  $node: $result"
    # 경고: mlx5_0이 experiment NIC가 아닌 경우
    if ! echo "$result" | grep -q "$EXP_NIC"; then
        echo "    ⚠️ WARNING: $RDMA_DEV is NOT mapped to $EXP_NIC on this node!"
    fi
done
echo ""

# ---- Test 3: MPI hostname test (experiment network only) ----
echo "=== [3/5] MPI basic test ==="
cd "$REDANNS_DIR" 2>/dev/null || { echo "ERROR: $REDANNS_DIR not found"; exit 1; }

echo "  Running: mpiexec -hostfile hosts.mpi -n 4 hostname"
echo "  (btl+oob restricted to $EXP_NIC)"
mpiexec -hostfile hosts.mpi -n 4 \
    --mca btl_tcp_if_include "$EXP_NIC" \
    --mca oob_tcp_if_include "$EXP_NIC" \
    hostname 2>&1 || {
    echo "  FAILED!"
    echo "  확인사항:"
    echo "    1) hosts.mpi에 10.10.1.x IP가 있는지 (FQDN 사용 금지!)"
    echo "    2) 노드 간 SSH 접속 (phase2)"
    echo "    3) OpenMPI가 모든 노드에 설치됨 (phase4)"
}
echo ""

# ---- Test 4: RDMA bandwidth test ----
echo "=== [4/5] RDMA bandwidth test ==="
echo "  ($RDMA_DEV only, experiment network)"
echo ""

SERVER="${NODE_IPS[0]}"
CLIENT="${NODE_IPS[1]}"

# 이전 perftest 프로세스 정리
ssh "${SSH_USER}@${SERVER}" "killall ib_write_bw 2>/dev/null" || true
sleep 1

# ib_write_bw에 -d 옵션으로 experiment NIC 디바이스 지정
# 그리고 --source_ip로 experiment network IP 지정 (handshake도 experiment net 사용)
echo "  Starting server on $SERVER (device=$RDMA_DEV)..."
ssh "${SSH_USER}@${SERVER}" \
    "nohup ib_write_bw -d $RDMA_DEV --report_gbits -D 3 > /tmp/ib_bw_server.log 2>&1 &" || \
    echo "  WARNING: ib_write_bw not available"

sleep 2

echo "  Running client on $CLIENT → $SERVER ..."
ssh "${SSH_USER}@${CLIENT}" \
    "ib_write_bw -d $RDMA_DEV --report_gbits -D 3 $SERVER 2>&1" || \
    echo "  WARNING: bandwidth test failed"

echo ""
echo "  ★ 정상 결과: ~90-100 Gbps (ConnectX-6 100G NIC)"
echo ""

# ---- Test 5: RDMA latency test ----
echo "=== [5/5] RDMA latency test ==="

ssh "${SSH_USER}@${SERVER}" "killall ib_read_lat 2>/dev/null" || true
sleep 1

echo "  Starting server on $SERVER (device=$RDMA_DEV)..."
ssh "${SSH_USER}@${SERVER}" \
    "nohup ib_read_lat -d $RDMA_DEV -D 3 > /tmp/ib_lat_server.log 2>&1 &" || true

sleep 2

echo "  Running client on $CLIENT → $SERVER ..."
ssh "${SSH_USER}@${CLIENT}" \
    "ib_read_lat -d $RDMA_DEV -D 3 $SERVER 2>&1" || \
    echo "  WARNING: latency test failed"

echo ""
echo "  ★ 정상 결과: ~1-3 us (ConnectX-6)"
echo ""

# 정리
ssh "${SSH_USER}@${SERVER}" "killall ib_write_bw ib_read_lat 2>/dev/null" || true

# ---- Control network traffic 확인 ----
echo "=== [Bonus] Control network traffic check ==="
echo "  아래 명령으로 control network 트래픽이 없는지 확인하세요:"
echo "  (SSH 제외, 실험 트래픽이 보이면 안 됨)"
echo ""
echo "    sudo tcpdump -c 50 -n -i ens1f0np0 not port ssh and not arp"
echo ""
echo "  CloudLab 웹 UI → Experiment → Graphs → Control Traffic도 확인"
echo ""

echo "=========================================="
echo " RDMA Test Summary"
echo "=========================================="
echo ""
echo " RDMA device: $RDMA_DEV → $EXP_NIC (experiment network)"
echo " Bandwidth: ~90+ Gbps = OK"
echo " Latency: ~1-3 us = OK"
echo ""
echo " 모든 테스트 통과 → 데이터셋 준비 후 실험 실행"
echo "   cd $REDANNS_DIR/experiments"
echo "   bash run_all.sh"
echo "=========================================="
