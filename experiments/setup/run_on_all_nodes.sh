#!/bin/bash
# ============================================================
# 마스터 노드에서 모든 노드에 스크립트 일괄 실행
# ============================================================
# Phase 2 (SSH 설정) 완료 후 사용.
#
# 사용법:
#   bash run_on_all_nodes.sh phase3_install_rdma.sh
#   bash run_on_all_nodes.sh phase4_install_deps.sh
#
# ★ CloudLab 듀얼 네트워크 구조 ★
#   - SSH/SCP: hostname (control network) 사용 → 정상, 허용됨
#   - MPI/RDMA: 10.10.1.x (experiment network) → 실험 트래픽 전용
#   이 스크립트는 SSH/SCP만 하므로 hostname 사용
# ============================================================

set -euo pipefail

SCRIPT="${1:?Usage: bash run_on_all_nodes.sh <script.sh>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ★★★ SSH/SCP는 hostname (control network) 사용 ★★★
# CloudLab에서 SSH는 control network를 통해 동작합니다.
# 10.10.1.x (experiment network)로는 SCP/SSH 불가!
NODE_HOSTNAMES=(
    "node-0"    # → 10.10.1.2 (experiment IP)
    "node-1"    # → 10.10.1.1 (experiment IP)
    "node-2"    # → 10.10.1.3 (experiment IP)
    "node-3"    # → 10.10.1.4 (experiment IP)
)
SSH_USER="${USER}"

if [ ! -f "$SCRIPT_DIR/$SCRIPT" ]; then
    echo "ERROR: $SCRIPT_DIR/$SCRIPT not found"
    exit 1
fi

echo "=========================================="
echo " Running $SCRIPT on all ${#NODE_HOSTNAMES[@]} nodes"
echo " Nodes: ${NODE_HOSTNAMES[*]}"
echo " (SSH via control network / hostnames)"
echo "=========================================="

FAILED_NODES=()

for node in "${NODE_HOSTNAMES[@]}"; do
    echo ""
    echo "====== $node ======"
    # 스크립트를 원격 노드에 복사 후 실행 (hostname으로 SCP)
    scp -o StrictHostKeyChecking=no "$SCRIPT_DIR/$SCRIPT" \
        "${SSH_USER}@${node}:/tmp/${SCRIPT}" 2>/dev/null || {
        echo "  ERROR: Cannot copy script to $node"
        echo "  SSH가 안 되면 phase2_ssh_setup.sh를 먼저 실행하세요."
        FAILED_NODES+=("$node")
        continue
    }
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${node}" \
        "sudo bash /tmp/${SCRIPT}" 2>&1 | tail -40 || {
        echo "  WARNING: Script returned error on $node"
        FAILED_NODES+=("$node")
    }
    echo "====== $node done ======"
done

echo ""
echo "=========================================="
if [ ${#FAILED_NODES[@]} -eq 0 ]; then
    echo " ✓ All ${#NODE_HOSTNAMES[@]} nodes complete!"
else
    echo " ⚠️ Failed on: ${FAILED_NODES[*]}"
    echo " 해당 노드에 직접 접속하여 실행하세요:"
    for fn in "${FAILED_NODES[@]}"; do
        echo "   ssh ${SSH_USER}@${fn} 'sudo bash /tmp/${SCRIPT}'"
    done
fi
echo "=========================================="
