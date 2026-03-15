#!/bin/bash
# ============================================================
# Phase 3: RDMA 유저스페이스 도구 설치
# ============================================================
# ★ 4개 노드 각각에서 실행 ★
# 또는 마스터에서: bash run_on_all_nodes.sh phase3_install_rdma.sh
#
# CloudLab Wisconsin 환경:
#   - NIC: Mellanox ConnectX-6 Dx (4개) + ConnectX-6 Lx (2개)
#   - 커널 드라이버: mlx5_core, mlx5_ib 이미 로드됨
#   - 필요: rdma-core 유저스페이스 도구 (ibstat, ibv_devinfo 등)
#   - OFED 별도 설치 불필요 (inbox 드라이버 사용)
#
# 사용법: sudo bash phase3_install_rdma.sh
# ============================================================

set -euo pipefail

echo "=========================================="
echo " RDMA User-Space Tools Installation"
echo " (ConnectX-6 Dx/Lx, Ubuntu 22.04)"
echo "=========================================="
echo ""

# root 권한 확인
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: root 권한이 필요합니다."
    echo "  sudo bash phase3_install_rdma.sh"
    exit 1
fi

# ---- Step 1: 기존 RDMA 상태 확인 ----
echo "=== [1/6] Current RDMA kernel status ==="
echo "--- Mellanox NIC (PCIe) ---"
lspci | grep -iE "mellanox|connectx" || echo "(not found)"
echo ""

echo "--- Loaded RDMA modules ---"
lsmod | grep -iE "mlx|ib_|rdma" | head -15 || echo "(no modules)"
echo ""

echo "--- Active RDMA links ---"
for dev in /sys/class/infiniband/*/; do
    if [ -d "$dev" ]; then
        devname=$(basename "$dev")
        for port in "$dev"/ports/*/; do
            portnum=$(basename "$port")
            state=$(cat "$port/state" 2>/dev/null || echo "unknown")
            phys=$(cat "$port/phys_state" 2>/dev/null || echo "unknown")
            echo "  $devname port $portnum: state=$state phys=$phys"
        done
    fi
done
echo ""

# ---- Step 2: rdma-core 유저스페이스 패키지 설치 ----
echo "=== [2/6] Installing rdma-core packages ==="
apt-get update -qq

apt-get install -y \
    rdma-core \
    libibverbs-dev \
    libibverbs1 \
    ibverbs-utils \
    ibverbs-providers \
    librdmacm-dev \
    librdmacm1 \
    rdmacm-utils \
    infiniband-diags \
    perftest \
    2>/dev/null

echo "  → rdma-core packages installed"
echo ""

# ---- Step 3: 커널 모듈 확인/로드 ----
echo "=== [3/6] Verifying kernel modules ==="

MODULES=("mlx5_core" "mlx5_ib" "ib_uverbs" "ib_core" "ib_cm" "iw_cm" "rdma_ucm")
for mod in "${MODULES[@]}"; do
    if lsmod | grep -q "^$mod"; then
        echo "  ✓ $mod (already loaded)"
    else
        modprobe "$mod" 2>/dev/null && echo "  → $mod loaded" || echo "  ✗ $mod (not available)"
    fi
done
echo ""

# ---- Step 4: RoCE GID 테이블 확인 (ConnectX-6 특화) ----
echo "=== [4/6] RoCE GID table (ConnectX-6) ==="
echo "  ConnectX-6는 RoCEv2를 기본 지원합니다."
echo ""

# mlx5 장치별 GID 확인
for dev in /sys/class/infiniband/mlx5_*/; do
    if [ -d "$dev" ]; then
        devname=$(basename "$dev")
        netdev=$(cat "$dev/device/net/"*/name 2>/dev/null | head -1 || echo "unknown")
        echo "  $devname → $netdev"
        # GID 타입 확인 (RoCEv2 = 3)
        for gid in "$dev"/ports/1/gids/*/; do
            gidnum=$(basename "$gid" 2>/dev/null || continue)
            gidval=$(cat "$dev/ports/1/gids/$gidnum" 2>/dev/null || continue)
            gidtype=$(cat "$dev/ports/1/gid_attrs/types/$gidnum" 2>/dev/null || echo "unknown")
            if [ "$gidval" != "0000:0000:0000:0000:0000:0000:0000:0000" ] && \
               [ "$gidval" != "fe80:0000:0000:0000:0000:0000:0000:0000" ]; then
                echo "    GID[$gidnum] = $gidval (type: $gidtype)"
            fi
        done 2>/dev/null || true
    fi
done
echo ""

# ---- Step 5: ulimit 설정 (RDMA에 필수) ----
echo "=== [5/6] Configuring memlock ulimit ==="

if ! grep -q "memlock unlimited" /etc/security/limits.conf 2>/dev/null; then
    echo "* soft memlock unlimited" >> /etc/security/limits.conf
    echo "* hard memlock unlimited" >> /etc/security/limits.conf
    echo "  → Added memlock unlimited to limits.conf"
else
    echo "  → memlock already configured"
fi

ulimit -l unlimited 2>/dev/null || true
echo "  Current ulimit -l: $(ulimit -l)"
echo ""

# ---- Step 6: 종합 검증 ----
echo "=== [6/6] Verification ==="

echo "--- ibstat ---"
ibstat 2>/dev/null | head -30 || echo "(ibstat failed)"
echo ""

echo "--- ibdev2netdev ---"
ibdev2netdev 2>/dev/null || echo "(ibdev2netdev failed)"
echo ""

echo "--- ibv_devinfo (핵심) ---"
ibv_devinfo 2>/dev/null | head -40 || echo "(ibv_devinfo failed)"
echo ""

echo "--- RDMA link status ---"
rdma link 2>/dev/null || echo "(rdma link failed)"
echo ""

echo "--- perftest 도구 확인 ---"
which ib_write_bw 2>/dev/null && echo "  ✓ ib_write_bw available" || echo "  ✗ ib_write_bw not found"
which ib_read_lat 2>/dev/null && echo "  ✓ ib_read_lat available" || echo "  ✗ ib_read_lat not found"
echo ""

# 활성 포트 요약
echo "=========================================="
echo " Installation Summary"
echo ""
echo " Active RDMA ports:"
ibdev2netdev 2>/dev/null | grep "Up" || echo "  (none found - check NIC wiring)"
echo ""
echo " ★ 실험에 사용할 NIC를 확인하세요:"
echo "   - 내부 클러스터 통신: 10.10.1.x 서브넷의 NIC (예: ens2f0np0)"
echo "   - ibdev2netdev에서 해당 NIC의 mlx5_X 장치 번호 확인"
echo ""
echo " 다음 단계: sudo bash phase4_install_deps.sh"
echo "=========================================="
