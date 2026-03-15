#!/bin/bash
# ============================================================
# 마스터 노드에서 모든 노드에 Phase 3, 4를 일괄 실행
# ============================================================
# Phase 2 (SSH 설정) 완료 후 사용.
#
# 사용법: bash run_on_all_nodes.sh <script.sh>
#   예: bash run_on_all_nodes.sh phase3_install_rdma.sh
#       bash run_on_all_nodes.sh phase4_install_deps.sh
# ============================================================

set -euo pipefail

SCRIPT="${1:?Usage: bash run_on_all_nodes.sh <script.sh>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ★★★ 수정 필요: phase2_ssh_setup.sh와 동일하게 ★★★
NODE_IPS=(
    "node0"
    "node1"
    "node2"
    "node3"
)
SSH_USER="${USER}"

if [ ! -f "$SCRIPT_DIR/$SCRIPT" ]; then
    echo "ERROR: $SCRIPT_DIR/$SCRIPT not found"
    exit 1
fi

echo "=========================================="
echo " Running $SCRIPT on all nodes"
echo " Nodes: ${NODE_IPS[*]}"
echo "=========================================="

for node in "${NODE_IPS[@]}"; do
    echo ""
    echo "====== $node ======"
    # 스크립트를 원격 노드에 복사 후 실행
    scp "$SCRIPT_DIR/$SCRIPT" "${SSH_USER}@${node}:/tmp/${SCRIPT}" 2>/dev/null
    ssh "${SSH_USER}@${node}" "sudo bash /tmp/${SCRIPT}" 2>&1 | tail -30
    echo "====== $node done ======"
done

echo ""
echo "=========================================="
echo " All nodes complete!"
echo "=========================================="
