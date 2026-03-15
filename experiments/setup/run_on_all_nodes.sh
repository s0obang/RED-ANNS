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
# CloudLab 환경: 10.10.1.x 내부 IP 사용
# ============================================================

set -euo pipefail

SCRIPT="${1:?Usage: bash run_on_all_nodes.sh <script.sh>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ★★★ 수정 필요: phase2_ssh_setup.sh와 동일한 EXPERIMENT NETWORK IP ★★★
# ⚠️ 반드시 10.10.1.x IP 사용! FQDN/128.x.x.x 사용 금지!
NODE_IPS=(
    "10.10.1.2"    # node-0
    "10.10.1.3"    # node-1
    "10.10.1.4"    # node-2
    "10.10.1.5"    # node-3
)
SSH_USER="${USER}"

if [ ! -f "$SCRIPT_DIR/$SCRIPT" ]; then
    echo "ERROR: $SCRIPT_DIR/$SCRIPT not found"
    exit 1
fi

echo "=========================================="
echo " Running $SCRIPT on all ${#NODE_IPS[@]} nodes"
echo " Nodes: ${NODE_IPS[*]}"
echo "=========================================="

FAILED_NODES=()

for node in "${NODE_IPS[@]}"; do
    echo ""
    echo "====== $node ======"
    # 스크립트를 원격 노드에 복사 후 실행
    scp -o StrictHostKeyChecking=no "$SCRIPT_DIR/$SCRIPT" \
        "${SSH_USER}@${node}:/tmp/${SCRIPT}" 2>/dev/null || {
        echo "  ERROR: Cannot copy script to $node"
        FAILED_NODES+=("$node")
        continue
    }
    ssh "${SSH_USER}@${node}" "sudo bash /tmp/${SCRIPT}" 2>&1 | tail -40 || {
        echo "  WARNING: Script returned error on $node"
        FAILED_NODES+=("$node")
    }
    echo "====== $node done ======"
done

echo ""
echo "=========================================="
if [ ${#FAILED_NODES[@]} -eq 0 ]; then
    echo " ✓ All ${#NODE_IPS[@]} nodes complete!"
else
    echo " ⚠️ Failed on: ${FAILED_NODES[*]}"
    echo " 해당 노드에 직접 접속하여 확인하세요:"
    for fn in "${FAILED_NODES[@]}"; do
        echo "   ssh ${SSH_USER}@${fn} 'sudo bash /tmp/${SCRIPT}'"
    done
fi
echo "=========================================="
