#!/bin/bash
# ============================================================
# Phase 5: RED-ANNS 빌드 + 클러스터 설정
# ============================================================
# 마스터 노드에서 실행.
# global.hpp 수정 → 빌드 → hosts 설정 → 전체 노드에 sync
#
# 사용법: bash phase5_build_and_setup.sh
#
# 실행 전:
#   1) 이 파일의 NODE_IPS를 수정
#   2) RED-ANNS 소스코드 경로를 확인 (REDANNS_DIR)
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

# RED-ANNS 소스 경로 (git clone 위치)
REDANNS_DIR="$HOME/RED-ANNS"

echo "=========================================="
echo " RED-ANNS Build & Cluster Setup"
echo "=========================================="
echo ""

# ---- Step 1: 소스코드 확인 ----
echo "=== [1/5] Source code ==="
if [ ! -d "$REDANNS_DIR" ]; then
    echo "  Cloning from GitHub..."
    cd "$HOME"
    git clone https://github.com/s0obang/RED-ANNS.git
fi

cd "$REDANNS_DIR"
echo "  Directory: $(pwd)"
echo "  Git status: $(git log --oneline -1)"
echo ""

# ---- Step 2: global.hpp 설정 확인 ----
echo "=== [2/5] global.hpp configuration ==="
GLOBAL_HPP="$REDANNS_DIR/include/global.hpp"

if [ -f "$GLOBAL_HPP" ]; then
    echo "  Current settings:"
    grep -E "num_servers|num_threads|memstore_size_gb|rdma_buf_size_mb" "$GLOBAL_HPP" | \
        grep -v "//" | head -10

    echo ""
    echo "  ★ 확인하세요:"
    echo "    num_servers = 4          (노드 수)"
    echo "    num_threads = 16         (코어 수에 맞게)"
    echo "    memstore_size_gb = 20    (노드 메모리에 맞게)"
    echo "    rdma_buf_size_mb = 64"
    echo ""
    read -p "  설정이 맞습니까? 계속 진행? (y/n): " PROCEED
    if [ "$PROCEED" != "y" ]; then
        echo "  vim $GLOBAL_HPP 으로 수정 후 다시 실행하세요."
        exit 0
    fi
else
    echo "  ERROR: $GLOBAL_HPP not found"
    exit 1
fi
echo ""

# ---- Step 3: hosts 파일 생성 ----
echo "=== [3/5] Generating hosts files ==="

# 각 노드의 실제 IP 수집
echo "  Collecting IP addresses from nodes..."
HOSTS_FILE="$REDANNS_DIR/hosts"
HOSTS_MPI="$REDANNS_DIR/hosts.mpi"

> "$HOSTS_FILE"
> "$HOSTS_MPI"

for node in "${NODE_IPS[@]}"; do
    # 노드의 내부 IP 가져오기 (첫 번째 non-loopback)
    NODE_IP=$(ssh "${SSH_USER}@${node}" "ip -4 addr show | grep inet | grep -v 127.0.0.1 | head -1 | awk '{print \$2}' | cut -d/ -f1" 2>/dev/null)

    if [ -n "$NODE_IP" ]; then
        echo "$NODE_IP" >> "$HOSTS_FILE"
        echo "$NODE_IP slots=1" >> "$HOSTS_MPI"
        echo "  $node → $NODE_IP"
    else
        echo "  WARNING: Could not get IP for $node, using hostname"
        echo "$node" >> "$HOSTS_FILE"
        echo "$node slots=1" >> "$HOSTS_MPI"
    fi
done

echo ""
echo "  hosts:"
cat "$HOSTS_FILE"
echo ""
echo "  hosts.mpi:"
cat "$HOSTS_MPI"
echo ""

# ---- Step 4: 빌드 ----
echo "=== [4/5] Building RED-ANNS ==="
cd "$REDANNS_DIR"

# MKL 환경 로드 (있으면)
if [ -f /opt/intel/oneapi/setvars.sh ]; then
    source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true
fi

bash build.sh 2>&1 | tail -20

# 바이너리 확인
echo ""
echo "  Built binaries:"
ls -la build/tests/test_search_distributed 2>/dev/null || echo "  ERROR: test_search_distributed not found"
ls -la build/tests/test_map_reduce 2>/dev/null || echo "  WARNING: test_map_reduce not found"
echo ""

# ---- Step 5: 모든 노드에 동기화 ----
echo "=== [5/5] Syncing to all nodes ==="

# sync.sh 수정 (WUKONG_ROOT 설정)
export WUKONG_ROOT="$REDANNS_DIR"

bash sync.sh 2>&1 | tail -10
echo ""

echo "=========================================="
echo " Build & Setup Complete!"
echo ""
echo " 테스트 실행:"
echo "   cd $REDANNS_DIR"
echo "   mpiexec -hostfile hosts.mpi -n 4 \\"
echo "     --mca btl_tcp_if_include <NIC> \\"
echo "     numactl --cpunodebind=0 --membind=0 \\"
echo "     build/tests/test_search_distributed \\"
echo "     config hosts <json> 10 100 8 3 3 0"
echo "=========================================="
