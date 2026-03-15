#!/bin/bash
# ============================================================
# Phase 2: 노드 간 SSH 무비밀번호 설정
# ============================================================
# "마스터 노드" (node-0) 1대에서만 실행합니다.
#
# ★ CloudLab 듀얼 네트워크 구조 ★
#   - SSH 로그인/SCP: hostname (control network, 128.105.x.x) 사용
#   - MPI 실행 시: experiment IP (10.10.1.x)로 SSH → 이것도 설정 필요!
#
#   MPI가 hosts.mpi의 10.10.1.x IP로 프로세스를 spawn하므로,
#   모든 노드가 10.10.1.x IP로도 SSH 접속 가능해야 합니다.
#
# 사용법: bash phase2_ssh_setup.sh
# ============================================================

set -euo pipefail

# ★★★ 수정 필요: 4개 노드의 hostname + experiment IP ★★★
# hostname: SSH/SCP 접속용 (control network 경유)
# experiment IP: MPI가 사용하는 주소 (known_hosts에 등록 필요)
NODE_HOSTNAMES=(
    "node-0"
    "node-1"
    "node-2"
    "node-3"
)

NODE_EXP_IPS=(
    "10.10.1.2"    # node-0 (ens2f0np0)
    "10.10.1.1"    # node-1 (ens2f0np0)
    "10.10.1.3"    # node-2 (ens2f0np0)
    "10.10.1.4"    # node-3 (ens2f1np1)
)

SSH_USER="${USER}"

echo "=========================================="
echo " SSH Passwordless Setup (CloudLab)"
echo " User: $SSH_USER"
echo " Hostnames (SSH): ${NODE_HOSTNAMES[*]}"
echo " Experiment IPs (MPI): ${NODE_EXP_IPS[*]}"
echo "=========================================="
echo ""

# ============================================================
# Step 0: CloudLab 자동 SSH 설정 확인 (hostname으로 접속)
# ============================================================
echo "[0/5] Checking existing SSH access via hostnames..."
ALREADY_OK=true
for node in "${NODE_HOSTNAMES[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" "hostname" 2>/dev/null; then
        echo "  ✓ $node → accessible"
    else
        echo "  ✗ $node → needs setup"
        ALREADY_OK=false
    fi
done
echo ""

if [ "$ALREADY_OK" = true ]; then
    echo "  모든 노드에 이미 SSH 접근 가능합니다! (hostname 경유)"
    echo ""
fi

# ============================================================
# Step 1: SSH 키 생성 (없으면)
# ============================================================
if [ ! -f ~/.ssh/id_rsa ]; then
    echo "[1/5] Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
    echo "  → Key generated: ~/.ssh/id_rsa"
else
    echo "[1/5] SSH key already exists: ~/.ssh/id_rsa"
fi
echo ""

# ============================================================
# Step 2: 모든 노드에 공개키 복사 (hostname 사용)
# ============================================================
echo "[2/5] Copying public key to all nodes (via hostname)..."
for node in "${NODE_HOSTNAMES[@]}"; do
    echo "  → $node ..."
    ssh-copy-id -o StrictHostKeyChecking=no "${SSH_USER}@${node}" 2>/dev/null || \
        echo "    (already set or failed)"
done
echo ""

# ============================================================
# Step 3: hostname 기반 SSH 검증
# ============================================================
echo "[3/5] Verifying passwordless SSH (via hostname)..."
ALL_OK=true
for node in "${NODE_HOSTNAMES[@]}"; do
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
    echo "  수동 설정: ssh-copy-id ${SSH_USER}@<node>"
    exit 1
fi

# ============================================================
# Step 4: 노드 간 상호 SSH 설정 (MPI에 필요)
# ============================================================
echo "[4/5] Setting up cross-node SSH..."
echo "  키를 모든 노드에 동기화하고, experiment IP를 known_hosts에 등록합니다."
echo "  (MPI가 10.10.1.x IP로 프로세스를 spawn하기 때문)"
echo ""

for i in "${!NODE_HOSTNAMES[@]}"; do
    node="${NODE_HOSTNAMES[$i]}"
    echo "  → Syncing keys to $node ..."

    # 키 복사
    scp -o StrictHostKeyChecking=no ~/.ssh/id_rsa ~/.ssh/id_rsa.pub \
        "${SSH_USER}@${node}:~/.ssh/" 2>/dev/null || true
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${node}" \
        "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && \
         sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && \
         chmod 600 ~/.ssh/authorized_keys && \
         chmod 700 ~/.ssh && \
         chmod 600 ~/.ssh/id_rsa" 2>/dev/null || true

    # known_hosts에 hostname + experiment IP 모두 등록
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${node}" bash -s <<'REMOTE_SCRIPT' "${NODE_HOSTNAMES[*]}" "${NODE_EXP_IPS[*]}"
        HOSTNAMES=($1)
        EXP_IPS=($2)
        # hostname 등록
        for h in "${HOSTNAMES[@]}"; do
            ssh-keyscan -H "$h" >> ~/.ssh/known_hosts 2>/dev/null
        done
        # experiment IP 등록 (MPI가 이 IP로 SSH)
        for ip in "${EXP_IPS[@]}"; do
            ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>/dev/null
        done
        # 중복 제거
        sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts 2>/dev/null || true
REMOTE_SCRIPT
done
echo ""

# ============================================================
# Step 5: 크로스 노드 SSH 검증 (hostname + experiment IP)
# ============================================================
echo "[5/5] Verifying cross-node SSH..."

echo ""
echo "  --- hostname 기반 (SSH/SCP용) ---"
CROSS_OK=true
for src in "${NODE_HOSTNAMES[@]}"; do
    for dst in "${NODE_HOSTNAMES[@]}"; do
        if [ "$src" != "$dst" ]; then
            result=$(ssh -o StrictHostKeyChecking=no "${SSH_USER}@${src}" \
                "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 ${dst} hostname 2>/dev/null" 2>/dev/null)
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
echo "  --- experiment IP 기반 (MPI용) ---"
MPI_SSH_OK=true
for i in "${!NODE_HOSTNAMES[@]}"; do
    src="${NODE_HOSTNAMES[$i]}"
    for j in "${!NODE_EXP_IPS[@]}"; do
        dst_ip="${NODE_EXP_IPS[$j]}"
        if [ "$i" != "$j" ]; then
            result=$(ssh -o StrictHostKeyChecking=no "${SSH_USER}@${src}" \
                "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3 ${dst_ip} hostname 2>/dev/null" 2>/dev/null)
            if [ $? -eq 0 ]; then
                echo "    ✓ $src → $dst_ip ($result)"
            else
                echo "    ✗ $src → $dst_ip FAILED"
                MPI_SSH_OK=false
            fi
        fi
    done
done

echo ""
echo "=========================================="
if [ "$CROSS_OK" = true ] && [ "$MPI_SSH_OK" = true ]; then
    echo " ✓ All cross-node SSH working!"
    echo "   - hostname (SSH/SCP): OK"
    echo "   - experiment IP (MPI): OK"
elif [ "$CROSS_OK" = true ] && [ "$MPI_SSH_OK" != true ]; then
    echo " ⚠️ hostname SSH OK, but experiment IP SSH FAILED"
    echo ""
    echo " MPI는 hosts.mpi의 10.10.1.x IP로 SSH하므로 이 문제를 해결해야 합니다."
    echo " 확인: 각 노드에서 'ssh 10.10.1.x hostname' 테스트"
    echo ""
    echo " 원인 후보:"
    echo "   1) sshd가 experiment NIC에서 listen하지 않음"
    echo "      → 각 노드: sudo netstat -tlnp | grep :22"
    echo "   2) 방화벽이 10.10.1.x:22를 차단"
    echo "      → 각 노드: sudo iptables -L -n | grep 22"
    echo "   3) /etc/hosts에 10.10.1.x가 등록되지 않음"
    echo "      → 각 노드: cat /etc/hosts | grep 10.10"
else
    echo " ⚠️ Some cross-node SSH failed."
fi
echo "=========================================="

echo ""
echo " 다음 단계: bash run_on_all_nodes.sh phase3_install_rdma.sh"
echo "=========================================="
