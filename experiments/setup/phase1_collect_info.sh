#!/bin/bash
# ============================================================
# Phase 1: 노드 정보 수집
# ============================================================
# 각 노드에서 실행하여 하드웨어/소프트웨어 정보를 수집합니다.
# 출력을 공유하면 이후 Phase 스크립트를 환경에 맞게 설정합니다.
#
# 사용법: bash phase1_collect_info.sh
# ============================================================

echo "=========================================="
echo " RED-ANNS Node Information Collector"
echo "=========================================="
echo ""

echo "=== [1] Hostname & OS ==="
hostname -f 2>/dev/null || hostname
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
ip -4 addr show | grep -E "inet " | awk '{print $NF, $2}'
echo ""

echo "=== [5] Mellanox NIC / RDMA ==="
echo "--- PCIe devices ---"
lspci | grep -iE "mellanox|connectx|nvidia.*network" || echo "(not found)"
echo ""

echo "--- RDMA kernel modules ---"
lsmod | grep -iE "rdma|mlx|ib_" | head -15 || echo "(none)"
echo ""

echo "--- ibstat ---"
ibstat 2>/dev/null | head -30 || echo "(ibstat not available - rdma-core 미설치)"
echo ""

echo "--- ibdev2netdev ---"
ibdev2netdev 2>/dev/null || echo "(ibdev2netdev not available)"
echo ""

echo "--- rdma link ---"
rdma link 2>/dev/null | head -10 || echo "(rdma tool not available)"
echo ""

echo "--- NIC NUMA affinity ---"
for iface in $(ls /sys/class/net/ 2>/dev/null); do
    numa=$(cat /sys/class/net/$iface/device/numa_node 2>/dev/null)
    if [ -n "$numa" ] && [ "$numa" != "-1" ]; then
        echo "  $iface → NUMA node $numa"
    fi
done
echo ""

echo "=== [6] OFED / RDMA 드라이버 ==="
ofed_info -s 2>/dev/null || echo "(OFED not installed - inbox driver)"
dpkg -l 2>/dev/null | grep -iE "rdma-core|ibverbs" | head -5 || echo "(no rdma packages)"
echo ""

echo "=== [7] Software ==="
echo "  CMake: $(cmake --version 2>/dev/null | head -1 || echo 'NOT INSTALLED')"
echo "  MPI:   $(mpiexec --version 2>/dev/null | head -1 || echo 'NOT INSTALLED')"
echo "  GCC:   $(gcc --version 2>/dev/null | head -1 || echo 'NOT INSTALLED')"
echo "  Python: $(python3 --version 2>/dev/null || echo 'NOT INSTALLED')"
echo "  Boost:"
dpkg -l 2>/dev/null | grep libboost | head -3 || echo "    (not found via dpkg)"
if [ -f /usr/local/include/boost/version.hpp ]; then
    echo "    /usr/local: $(grep BOOST_LIB_VERSION /usr/local/include/boost/version.hpp | head -1)"
fi
echo ""

echo "=== [8] ulimit (locked memory) ==="
echo "  ulimit -l: $(ulimit -l)"
echo ""

echo "=== [9] Disk Space ==="
df -h / | tail -1
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | head -10
echo ""

echo "=========================================="
echo " Done! 이 출력 전체를 복사해서 공유해주세요."
echo "=========================================="
