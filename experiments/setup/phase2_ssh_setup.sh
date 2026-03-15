#!/bin/bash
# ============================================================
# Phase 2: 노드 간 SSH 무비밀번호 설정
# ============================================================
# "마스터 노드" 1대에서만 실행합니다.
# 나머지 3개 노드의 IP를 아래에 입력하세요.
#
# 사용법:
#   1) 아래 NODE_IPS 배열을 수정
#   2) 마스터 노드에서: bash phase2_ssh_setup.sh
#   3) 각 노드 비밀번호를 물어보면 입력
# ============================================================

set -euo pipefail

# ★★★ 수정 필요: 4개 노드의 IP (또는 hostname) ★★★
# CloudLab에서는 보통 node0, node1, node2, node3 또는 내부 IP 사용
NODE_IPS=(
    "node0"
    "node1"
    "node2"
    "node3"
)

# CloudLab 사용자명 (보통 CloudLab username)
SSH_USER="${USER}"

echo "=========================================="
echo " SSH Passwordless Setup"
echo " User: $SSH_USER"
echo " Nodes: ${NODE_IPS[*]}"
echo "=========================================="
echo ""

# Step 1: SSH 키 생성 (없으면)
if [ ! -f ~/.ssh/id_rsa ]; then
    echo "[1/3] Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    echo "  → Key generated: ~/.ssh/id_rsa"
else
    echo "[1/3] SSH key already exists: ~/.ssh/id_rsa"
fi
echo ""

# Step 2: 모든 노드에 공개키 복사
echo "[2/3] Copying public key to all nodes..."
echo "  (각 노드의 비밀번호를 물어볼 수 있습니다)"
echo ""

for node in "${NODE_IPS[@]}"; do
    echo "  → $node ..."
    ssh-copy-id -o StrictHostKeyChecking=no "${SSH_USER}@${node}" 2>/dev/null || \
    ssh-copy-id "${SSH_USER}@${node}" || \
    echo "    WARNING: Failed for $node (수동으로 설정 필요)"
done
echo ""

# Step 3: 검증
echo "[3/3] Verifying passwordless SSH..."
ALL_OK=true
for node in "${NODE_IPS[@]}"; do
    result=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" "hostname" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "  ✓ $node → $result"
    else
        echo "  ✗ $node → FAILED"
        ALL_OK=false
    fi
done
echo ""

if [ "$ALL_OK" = true ]; then
    echo "=========================================="
    echo " ✓ All nodes accessible!"
    echo "=========================================="
else
    echo "=========================================="
    echo " ✗ Some nodes failed. 수동 확인 필요:"
    echo "   ssh ${SSH_USER}@<failed_node>"
    echo "=========================================="
fi

# Step 4: 노드 간 상호 접속도 설정 (MPI에 필요)
echo ""
echo "[추가] 노드 간 상호 SSH 설정..."
echo "  각 노드에서도 같은 키를 공유해야 MPI가 동작합니다."
echo ""

read -p "  모든 노드에 SSH 키를 동기화하시겠습니까? (y/n): " SYNC_KEYS
if [ "$SYNC_KEYS" = "y" ]; then
    for node in "${NODE_IPS[@]}"; do
        echo "  → Syncing keys to $node ..."
        # 키 복사
        scp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub "${SSH_USER}@${node}:~/.ssh/" 2>/dev/null || true
        # authorized_keys에 추가
        ssh "${SSH_USER}@${node}" "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null || true
        # known_hosts 갱신 (모든 노드를 알도록)
        for other in "${NODE_IPS[@]}"; do
            ssh "${SSH_USER}@${node}" "ssh-keyscan -H $other >> ~/.ssh/known_hosts 2>/dev/null" || true
        done
    done
    echo ""

    # 검증: node0 → node1 등
    echo "  Verifying cross-node SSH..."
    for src in "${NODE_IPS[@]}"; do
        for dst in "${NODE_IPS[@]}"; do
            if [ "$src" != "$dst" ]; then
                result=$(ssh "${SSH_USER}@${src}" "ssh -o BatchMode=yes -o ConnectTimeout=3 ${dst} hostname 2>/dev/null")
                if [ $? -eq 0 ]; then
                    echo "    ✓ $src → $dst ($result)"
                else
                    echo "    ✗ $src → $dst FAILED"
                fi
            fi
        done
    done
fi

echo ""
echo "=========================================="
echo " Done! 다음 단계: bash phase3_install_rdma.sh"
echo "=========================================="
