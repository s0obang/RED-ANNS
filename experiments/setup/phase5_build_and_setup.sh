#!/bin/bash
# ============================================================
# Phase 5: RED-ANNS 빌드 + 클러스터 설정
# ============================================================
# 마스터 노드 (node-0)에서 실행.
# global.hpp 확인 → hosts 파일 생성 → 빌드 → 전체 노드에 sync
#
# ★ CloudLab 듀얼 네트워크 구조 ★
#   - SSH/rsync: hostname (control network) 사용
#   - hosts/hosts.mpi: 10.10.1.x (experiment network) IP만 기입
#   - MPI/RDMA: experiment network만 사용
#
# CloudLab Wisconsin 환경:
#   - 4 노드, experiment IP: 10.10.1.x/24
#   - CPU: 2x Xeon Silver 4314 (16C/32T)
#   - Memory: 251 Gi per node
#
# 사전 조건: Phase 2~4 완료
# 사용법: bash phase5_build_and_setup.sh
# ============================================================

set -euo pipefail

# ★★★ 듀얼 주소 설정 ★★★
# hostname: SSH/rsync에 사용 (control network 경유)
NODE_HOSTNAMES=(
    "node-0"
    "node-1"
    "node-2"
    "node-3"
)

# experiment IP: hosts/hosts.mpi에 기입 (MPI/RDMA 트래픽 전용)
# ⚠️ 절대 128.105.x.x (control network) IP를 넣지 마세요!
NODE_EXP_IPS=(
    "10.10.1.2"    # node-0 (ens2f0np0)
    "10.10.1.1"    # node-1 (ens2f0np0)
    "10.10.1.3"    # node-2 (ens2f0np0)
    "10.10.1.4"    # node-3 (ens2f1np1 ← NIC 이름 다름!)
)

SSH_USER="${USER}"

# RED-ANNS 소스 경로
REDANNS_DIR="$HOME/RED-ANNS"

echo "=========================================="
echo " RED-ANNS Build & Cluster Setup"
echo " (CloudLab Wisconsin)"
echo ""
echo " SSH/rsync: hostnames (control net)"
echo " hosts/MPI: experiment IPs (10.10.1.x)"
echo "=========================================="
echo ""

# ---- Step 1: 소스코드 확인 ----
echo "=== [1/6] Source code ==="
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
echo "=== [2/6] global.hpp configuration ==="
GLOBAL_HPP="$REDANNS_DIR/include/global.hpp"

if [ -f "$GLOBAL_HPP" ]; then
    echo "  Current settings:"
    grep -nE "num_servers|num_threads|memstore_size_gb|rdma_buf_size" "$GLOBAL_HPP" | \
        grep -v "^.*//.*$" | head -10 || true

    echo ""
    echo "  ★ CloudLab 환경 권장값:"
    echo "    num_servers = 4          (노드 수)"
    echo "    num_threads = 8          (논문 값, 최대 32 가능)"
    echo "    memstore_size_gb = 50    (251Gi 중 50Gi 사용)"
    echo "    rdma_buf_size_mb = 64"
    echo ""
    read -p "  global.hpp 설정이 올바른가요? 계속? (y/n): " PROCEED
    if [ "$PROCEED" != "y" ]; then
        echo "  vim $GLOBAL_HPP 으로 수정 후 다시 실행하세요."
        exit 0
    fi
else
    echo "  ERROR: $GLOBAL_HPP not found"
    exit 1
fi
echo ""

# ---- Step 3: hosts 파일 생성 (experiment IP만!) ----
echo "=== [3/6] Generating hosts files ==="

HOSTS_FILE="$REDANNS_DIR/hosts"
HOSTS_MPI="$REDANNS_DIR/hosts.mpi"

> "$HOSTS_FILE"
> "$HOSTS_MPI"

echo "  Using EXPERIMENT NETWORK IPs (10.10.1.x) for hosts files:"
echo "  ⚠️ hosts 파일에 hostname/FQDN/128.x.x.x IP가 있으면 안 됩니다!"
for ip in "${NODE_EXP_IPS[@]}"; do
    if [[ ! "$ip" == 10.* ]]; then
        echo "  ✗ ERROR: $ip is NOT an experiment network IP (must be 10.x.x.x)"
        echo "  CloudLab control network 사용은 정책 위반입니다."
        exit 1
    fi
    echo "$ip" >> "$HOSTS_FILE"
    echo "$ip slots=1" >> "$HOSTS_MPI"
    echo "  $ip"
done

echo ""
echo "  hosts file:"
cat "$HOSTS_FILE"
echo ""
echo "  hosts.mpi file:"
cat "$HOSTS_MPI"
echo ""

# ---- Step 4: MKL 환경 로드 ----
echo "=== [4/6] Loading MKL environment ==="
if [ -f /opt/intel/oneapi/setvars.sh ]; then
    source /opt/intel/oneapi/setvars.sh > /dev/null 2>&1 || true
    echo "  → Intel oneAPI loaded"
elif [ -f /opt/intel/mkl/bin/mklvars.sh ]; then
    source /opt/intel/mkl/bin/mklvars.sh intel64 > /dev/null 2>&1 || true
    echo "  → MKL loaded"
else
    echo "  → MKL not found (빌드 시 문제가 생길 수 있음)"
fi
echo ""

# ---- Step 5: 빌드 ----
echo "=== [5/6] Building RED-ANNS ==="
cd "$REDANNS_DIR"

# build 디렉토리 클린 (필요시)
if [ -d build ]; then
    echo "  Cleaning existing build..."
    rm -rf build
fi

bash build.sh 2>&1 | tail -30

echo ""
echo "  Built binaries:"
ls -la build/tests/test_search_distributed 2>/dev/null && echo "  ✓ test_search_distributed" || echo "  ✗ test_search_distributed NOT FOUND"
ls -la build/tests/test_map_reduce 2>/dev/null && echo "  ✓ test_map_reduce" || echo "  ✗ test_map_reduce NOT FOUND"
echo ""

# 빌드 실패 확인
if [ ! -f build/tests/test_search_distributed ]; then
    echo "  ERROR: 빌드 실패!"
    echo "  build.sh의 출력을 확인하세요."
    echo "  일반적인 원인:"
    echo "    - Boost 버전 불일치 (1.85 필요)"
    echo "    - MKL 경로 미설정"
    echo "    - libibverbs 미설치 (phase3 확인)"
    exit 1
fi

# ---- Step 6: 모든 노드에 동기화 (hostname으로 rsync) ----
echo "=== [6/6] Syncing to all nodes (via hostname) ==="
export WUKONG_ROOT="$REDANNS_DIR"

# sync.sh가 있고 WUKONG_ROOT를 사용하면 시도
SYNC_DONE=false
if [ -f "$REDANNS_DIR/sync.sh" ] && grep -q "WUKONG_ROOT" "$REDANNS_DIR/sync.sh"; then
    echo "  Trying sync.sh..."
    bash sync.sh 2>&1 | tail -10 && SYNC_DONE=true || echo "  sync.sh failed, falling back to manual rsync"
fi

if [ "$SYNC_DONE" = false ]; then
    echo "  Manual rsync to all nodes (via hostname)..."
    for i in "${!NODE_HOSTNAMES[@]}"; do
        node="${NODE_HOSTNAMES[$i]}"
        echo "  → Syncing to $node ..."
        rsync -az --exclude='.git' --exclude='build' \
            "$REDANNS_DIR/" "${SSH_USER}@${node}:${REDANNS_DIR}/" 2>/dev/null || \
            echo "    WARNING: rsync to $node failed"
        # 빌드 바이너리 별도 복사
        rsync -az "$REDANNS_DIR/build/" "${SSH_USER}@${node}:${REDANNS_DIR}/build/" 2>/dev/null || true
    done
fi
echo ""

echo "=========================================="
echo " Build & Setup Complete!"
echo ""
echo " hosts/hosts.mpi: experiment IPs (10.10.1.x) ← MPI/RDMA용"
echo " rsync: hostname (control net) ← 파일 전송용"
echo ""
echo " 다음 단계: RDMA 연결 테스트"
echo "   bash phase6_test_rdma.sh"
echo ""
echo " 또는 바로 실험 실행:"
echo "   cd $REDANNS_DIR/experiments"
echo "   bash run_all.sh --dry-run   (파이프라인 테스트)"
echo "   bash run_fig10.sh deep100M  (실제 실험)"
echo "=========================================="
