#!/bin/bash
# ============================================================
# Phase 1: 노드 정보 수집
# ============================================================
# 이 스크립트를 4개 노드 각각에서 실행하고 출력을 공유해주세요.
#
# 사용법: bash phase1_collect_info.sh
# ============================================================

echo "=========================================="
echo " RED-ANNS Node Information Collector"
echo "=========================================="
echo ""

echo "=== [1] Hostname & OS ==="
hostname
cat /etc/os-release | grep -E "^(NAME|VERSION)="
uname -r
echo ""

echo "=== [2] CPU ==="
lscpu | grep -E "^(Architecture|CPU\(s\)|Thread|Core|Socket|Model name|NUMA)"
echo ""

echo "=== [3] Memory ==="
free -h | head -2
echo ""

echo "=== [4] Network Interfaces ==="
ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | tr -d ':'
echo ""

echo "=== [5] RDMA / Mellanox NIC 확인 ==="
# PCIe에서 Mellanox/NVIDIA NIC 검색
echo "--- lspci (Mellanox/NVIDIA network) ---"
lspci | grep -iE "mellanox|connectx|nvidia.*network|infiniband" || echo "(not found)"
echo ""

# RDMA 커널 모듈 확인
echo "--- RDMA kernel modules ---"
lsmod | grep -iE "rdma|mlx|ib_" | head -10 || echo "(no RDMA modules loaded)"
echo ""

# ibstat / ibdev2netdev (있으면)
echo "--- ibstat ---"
ibstat 2>/dev/null || echo "(ibstat not available)"
echo ""
echo "--- ibdev2netdev ---"
ibdev2netdev 2>/dev/null || echo "(ibdev2netdev not available)"
echo ""

# rdma 도구
echo "--- rdma link ---"
rdma link 2>/dev/null || echo "(rdma tool not available)"
echo ""

echo "=== [6] OFED / RDMA 드라이버 ==="
ofed_info -s 2>/dev/null || echo "(OFED not installed)"
dpkg -l | grep -iE "mlnx-ofed|rdma-core|ibverbs" 2>/dev/null | head -5 || echo "(no RDMA packages)"
echo ""

echo "=== [7] 기존 소프트웨어 ==="
echo "--- CMake ---"
cmake --version 2>/dev/null | head -1 || echo "(not installed)"
echo "--- MPI ---"
mpiexec --version 2>/dev/null | head -2 || echo "(not installed)"
mpirun --version 2>/dev/null | head -2 || echo "(not installed)"
echo "--- Boost ---"
dpkg -l | grep libboost | head -3 || echo "(not found)"
echo "--- GCC ---"
gcc --version 2>/dev/null | head -1 || echo "(not installed)"
echo "--- Python ---"
python3 --version 2>/dev/null || echo "(not installed)"
echo "--- numactl ---"
numactl --hardware 2>/dev/null | head -5 || echo "(not installed)"
echo ""

echo "=== [8] ulimit (locked memory) ==="
ulimit -l
echo ""

echo "=== [9] Disk Space ==="
df -h / | tail -1
df -h /tmp 2>/dev/null | tail -1
echo ""

echo "=== [10] IP Addresses ==="
ip -4 addr show | grep inet | grep -v "127.0.0.1" | awk '{print $NF, $2}'
echo ""

echo "=========================================="
echo " Done! 이 출력을 전체 복사해서 공유해주세요."
echo "=========================================="
