#!/bin/bash
# ============================================================
# Phase 3: RDMA 드라이버 설치 (Mellanox OFED)
# ============================================================
# ★ 4개 노드 각각에서 실행해야 합니다 ★
# 또는 마스터에서 실행 후 phase3_install_all_nodes.sh로 일괄 실행
#
# CloudLab Wisconsin의 sm220u/sm110p는 Mellanox ConnectX NIC 장착.
# Ubuntu 22.04 + ConnectX NIC → MLNX OFED 또는 inbox 드라이버 사용.
#
# 사용법: sudo bash phase3_install_rdma.sh
# ============================================================

set -euo pipefail

echo "=========================================="
echo " RDMA Driver Installation (Ubuntu 22.04)"
echo "=========================================="
echo ""

# root 권한 확인
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: root 권한이 필요합니다."
    echo "  sudo bash phase3_install_rdma.sh"
    exit 1
fi

# ---- Step 1: 기존 RDMA 상태 확인 ----
echo "=== [1/5] Current RDMA status ==="
echo "--- Mellanox NIC ---"
lspci | grep -iE "mellanox|connectx" || echo "(not found - NIC 없으면 중단)"
echo ""

# ---- Step 2: Ubuntu inbox RDMA 패키지 설치 ----
# MLNX OFED 대신 Ubuntu 내장 rdma-core를 사용하는 방법 (더 간단)
echo "=== [2/5] Installing RDMA packages ==="
apt-get update -qq

# 핵심 RDMA 패키지
apt-get install -y \
    rdma-core \
    libibverbs-dev \
    libibverbs1 \
    ibverbs-utils \
    librdmacm-dev \
    librdmacm1 \
    rdmacm-utils \
    infiniband-diags \
    ibutils \
    perftest \
    2>/dev/null

echo "  → RDMA core packages installed"
echo ""

# ---- Step 3: Mellanox 드라이버 (mlx5) ----
echo "=== [3/5] Loading Mellanox kernel modules ==="

# mlx5_core, mlx5_ib 로드
modprobe mlx5_core 2>/dev/null || echo "  mlx5_core already loaded or not available"
modprobe mlx5_ib 2>/dev/null || echo "  mlx5_ib already loaded or not available"
modprobe ib_uverbs 2>/dev/null || echo "  ib_uverbs already loaded"
modprobe rdma_ucm 2>/dev/null || echo "  rdma_ucm already loaded"

# RoCE 관련 모듈
modprobe ib_core 2>/dev/null || true
modprobe ib_cm 2>/dev/null || true
modprobe iw_cm 2>/dev/null || true

echo "--- Loaded RDMA modules ---"
lsmod | grep -iE "mlx|ib_|rdma" | head -10
echo ""

# ---- Step 4: ulimit 설정 (locked memory) ----
echo "=== [4/5] Configuring ulimit ==="

# /etc/security/limits.conf에 추가
if ! grep -q "memlock unlimited" /etc/security/limits.conf 2>/dev/null; then
    echo "* soft memlock unlimited" >> /etc/security/limits.conf
    echo "* hard memlock unlimited" >> /etc/security/limits.conf
    echo "  → Added memlock unlimited to limits.conf"
else
    echo "  → memlock already configured"
fi

# 현재 세션에도 적용 (가능한 경우)
ulimit -l unlimited 2>/dev/null || true
echo "  Current ulimit -l: $(ulimit -l)"
echo ""

# ---- Step 5: 검증 ----
echo "=== [5/5] Verification ==="

echo "--- ibstat ---"
ibstat 2>/dev/null || echo "(ibstat not available yet - reboot may be needed)"
echo ""

echo "--- ibdev2netdev ---"
ibdev2netdev 2>/dev/null || echo "(ibdev2netdev not available yet)"
echo ""

echo "--- rdma link ---"
rdma link 2>/dev/null || echo "(no rdma links found)"
echo ""

echo "--- ibv_devinfo (핵심 확인) ---"
ibv_devinfo 2>/dev/null | head -30 || echo "(ibv_devinfo not available)"
echo ""

# RoCE 인터페이스 확인
echo "--- RoCE capable interfaces ---"
for dev in /sys/class/infiniband/*/; do
    if [ -d "$dev" ]; then
        devname=$(basename "$dev")
        echo "  Device: $devname"
        cat "$dev/node_type" 2>/dev/null && true
        cat "$dev/board_id" 2>/dev/null && true
    fi
done
echo ""

echo "=========================================="
echo " RDMA Installation Complete!"
echo ""
echo " ibv_devinfo 출력이 보이면 성공입니다."
echo " 안 보이면 reboot 후 다시 확인하세요:"
echo "   sudo reboot"
echo "   ibv_devinfo"
echo ""
echo " 다음 단계: bash phase4_install_deps.sh"
echo "=========================================="
