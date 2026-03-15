#!/bin/bash
# ============================================================
# Phase 2: 노드 간 SSH 무비밀번호 설정
# ============================================================
# "마스터 노드" (node-0) 1대에서만 실행합니다.
#
# CloudLab Wisconsin 환경:
#   - 노드명 형식: node-{0,1,2,3}.red-anns.ebpfnetworking-pg0.wisc.cloudlab.us
#   - 내부 IP: 10.10.1.{2,3,4,5}/24 (ens2f0np0)
#   - CloudLab은 실험 생성 시 SSH 키를 자동 배포하므로
#     이미 무비밀번호 접속이 가능할 수 있습니다.
#
# 사용법:
#   1) 아래 NODE_IPS 배열을 실제 IP로 수정
#   2) 마스터 노드 (node-0)에서: bash phase2_ssh_setup.sh
# ============================================================

set -euo pipefail

# ★★★ 수정 필요: 4개 노드의 EXPERIMENT NETWORK IP ★★★
# ⚠️ 반드시 10.10.1.x (experiment network) IP를 사용하세요!
# ⚠️ FQDN이나 128.105.x.x (control network) IP 사용 금지!
#    FQDN은 CloudLab DNS에서 control network IP로 해석됩니다.
# 확인: 각 노드에서 ip -4 addr show ens2f0np0
NODE_IPS=(
    "10.10.1.2"    # node-0 (ens2f0np0)
    "10.10.1.1"    # node-1 (ens2f0np0)
    "10.10.1.3"    # node-2 (ens2f0np0)
    "10.10.1.4"    # node-3 (ens2f1np1 ← NIC 이름 다름!)
)

# CloudLab 사용자명
SSH_USER="${USER}"

echo "=========================================="
echo " SSH Passwordless Setup (CloudLab)"
echo " User: $SSH_USER"
echo " Nodes: ${NODE_IPS[*]}"
echo "=========================================="
echo ""

# Step 0: CloudLab 자동 SSH 설정 확인
echo "[0/4] Checking if CloudLab already set up SSH..."
ALREADY_OK=true
for node in "${NODE_IPS[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" "hostname" 2>/dev/null; then
        echo "  ✓ $node → already accessible"
    else
        echo "  ✗ $node → needs setup"
        ALREADY_OK=false
    fi
done

if [ "$ALREADY_OK" = true ]; then
    echo ""
    echo "  모든 노드에 이미 SSH 접근 가능합니다!"
    echo "  CloudLab이 자동으로 SSH 키를 배포한 것 같습니다."
    echo ""
    # 그래도 노드 간 상호 SSH가 되는지 확인
else
    echo ""
    echo "  일부 노드에 SSH 설정이 필요합니다."
fi
echo ""

# Step 1: SSH 키 생성 (없으면)
if [ ! -f ~/.ssh/id_rsa ]; then
    echo "[1/4] Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    echo "  → Key generated: ~/.ssh/id_rsa"
else
    echo "[1/4] SSH key already exists: ~/.ssh/id_rsa"
fi
echo ""

# Step 2: 모든 노드에 공개키 복사
echo "[2/4] Copying public key to all nodes..."
echo "  (CloudLab이 이미 설정했으면 skipped)"
echo ""

for node in "${NODE_IPS[@]}"; do
    echo "  → $node ..."
    ssh-copy-id -o StrictHostKeyChecking=no "${SSH_USER}@${node}" 2>/dev/null || \
        echo "    (already set or failed - CloudLab auto-setup일 수 있음)"
done
echo ""

# Step 3: 검증
echo "[3/4] Verifying passwordless SSH..."
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

if [ "$ALL_OK" != true ]; then
    echo "  ✗ 일부 노드 접근 실패."
    echo "  CloudLab 웹 UI에서 SSH 키가 등록되어 있는지 확인하세요."
    echo "  수동 설정: ssh-copy-id ${SSH_USER}@<node-ip>"
    exit 1
fi

# Step 4: 노드 간 상호 SSH 설정 (MPI에 필요)
echo "[4/4] Setting up cross-node SSH..."
echo "  MPI는 모든 노드에서 다른 모든 노드로 SSH가 가능해야 합니다."
echo ""

for node in "${NODE_IPS[@]}"; do
    echo "  → Syncing keys to $node ..."
    # 마스터의 키를 각 노드에 복사
    scp -o StrictHostKeyChecking=no ~/.ssh/id_rsa ~/.ssh/id_rsa.pub \
        "${SSH_USER}@${node}:~/.ssh/" 2>/dev/null || true
    # authorized_keys에 추가
    ssh "${SSH_USER}@${node}" \
        "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && \
         sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys" 2>/dev/null || true
    # 모든 노드를 known_hosts에 추가
    for other in "${NODE_IPS[@]}"; do
        ssh "${SSH_USER}@${node}" \
            "ssh-keyscan -H $other >> ~/.ssh/known_hosts 2>/dev/null" 2>/dev/null || true
    done
done
echo ""

# 크로스 노드 SSH 검증
echo "  Verifying cross-node SSH..."
CROSS_OK=true
for src in "${NODE_IPS[@]}"; do
    for dst in "${NODE_IPS[@]}"; do
        if [ "$src" != "$dst" ]; then
            result=$(ssh "${SSH_USER}@${src}" \
                "ssh -o BatchMode=yes -o ConnectTimeout=3 ${dst} hostname 2>/dev/null" 2>/dev/null)
            if [ $? -eq 0 ]; then
                echo "    ✓ $src → $dst ($result)"
            else
                echo "    ✗ $src → $dst FAILED"
                CROSS_OK=false
            fi
        fi
    done
done

echo ""
if [ "$CROSS_OK" = true ]; then
    echo "=========================================="
    echo " ✓ All cross-node SSH working!"
    echo "=========================================="
else
    echo "=========================================="
    echo " ⚠️ Some cross-node SSH failed."
    echo " MPI 실행 시 문제가 생길 수 있습니다."
    echo " 실패한 노드를 수동으로 설정하세요:"
    echo "   ssh <node> 'ssh <other-node> hostname'"
    echo "=========================================="
fi

echo ""
echo " 다음 단계: sudo bash phase3_install_rdma.sh"
echo "   (또는 bash run_on_all_nodes.sh phase3_install_rdma.sh)"
echo "=========================================="
