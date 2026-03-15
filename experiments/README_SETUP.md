# RED-ANNS 실험 재현 가이드

## ⚠️ CloudLab 듀얼 네트워크 구조 (필독!)

CloudLab은 **control network**와 **experiment network**를 엄격히 분리합니다.
control network의 과도한 사용은 **계정 정지** 또는 **실험 종료**를 초래합니다.

```
[Control Network]  128.105.x.x  (ens1f0np0, mlx5_4)  ← SSH 로그인, apt-get, git
[Experiment Network]  10.10.1.x  (ens2f0np0 또는 ens2f1np1)  ← MPI, RDMA, 실험 트래픽
```

### 용도별 네트워크 사용

| 용도 | 사용할 주소 | 네트워크 | 비고 |
|------|------------|---------|------|
| SSH/SCP/rsync (setup 스크립트) | **hostname** (node-0 등) | control | `run_on_all_nodes.sh`, `phase5`, `phase6` |
| MPI 프로세스 spawn | **10.10.1.x** (hosts.mpi) | experiment | MPI가 이 IP로 SSH 접속 |
| MPI 데이터 전송 | **10.10.1.0/24** (서브넷) | experiment | `btl_tcp_if_include` |
| RDMA | experiment NIC의 mlx5 | experiment | 자동 감지 |
| apt-get, git clone | control net (자동) | control | 1회성 허용 |

### 노드별 NIC 매핑

| 노드 | hostname | experiment IP | experiment NIC | RDMA device |
|------|----------|---------------|---------------|-------------|
| node-0 | node-0 | 10.10.1.2 | ens2f0np0 | mlx5_0 |
| node-1 | node-1 | 10.10.1.1 | ens2f0np0 | mlx5_0 |
| node-2 | node-2 | 10.10.1.3 | ens2f0np0 | mlx5_0 |
| node-3 | node-3 | 10.10.1.4 | **ens2f1np1** | (자동 감지) |

> **주의**: node-3의 experiment NIC 이름이 다릅니다!
> MPI 설정에서 NIC 이름 대신 **서브넷** `10.10.1.0/24`를 사용하는 이유입니다.

### SSH 경로 정리

```
외부 → node-0: ssh user@node-0.red-anns...cloudlab.us  (control net, FQDN)
node-0 → node-1: ssh node-1  (control net, hostname → /etc/hosts)
MPI → node-1: ssh 10.10.1.1  (experiment net, phase2에서 설정)
```

### 확인 방법 (실험 실행 중)
```bash
# control network 트래픽 확인 (SSH 외에 거의 0이어야 함)
sudo tcpdump -c 100 -n -i ens1f0np0 not port 22 and not arp
# CloudLab 웹 UI → Experiment → Graphs → Control Traffic
```

참고: https://docs.cloudlab.us/control-net.html

---

## CloudLab Wisconsin 환경 정보 (Phase 1 수집)

```
호스트:    node-{0,1,2,3}.red-anns.ebpfnetworking-pg0.wisc.cloudlab.us
OS:        Ubuntu 22.04.2 LTS, kernel 5.15.0-168-generic
CPU:       2x Intel Xeon Silver 4314 @ 2.40GHz (16C/32T each, 64 logical CPUs)
NUMA:      node0 = CPU 0-15,32-47  |  node1 = CPU 16-31,48-63
Memory:    251 Gi per node
Disk:      ~57 Gi free (root partition)
NIC:       ConnectX-6 Dx (4개) + ConnectX-6 Lx (2개)
RDMA:      mlx5_0 (ens2f0np0) ACTIVE, experiment IP 10.10.1.x/24
           ⚠️ node-3은 NIC 이름이 ens2f1np1로 다름!
           mlx5_4 (ens1f0np0) ACTIVE, control IP 128.105.146.x/22 ← 실험에 사용 금지!
```

## 파일 구조

```
experiments/
├── config.sh                  # 클러스터/데이터셋 설정
├── generate_dummy_logs.py     # 더미 데이터 생성 (테스트용)
├── make_tmp_json.py           # MR-ANNS용 임시 JSON 생성
├── parse_logs.py              # 로그 → CSV 파서
├── plot_all.py                # 통합 플로팅 스크립트
├── run_all.sh                 # 전체 파이프라인 통합 실행
├── run_fig10.sh               # Figure 10: QPS vs Recall
├── run_fig11.sh               # Figure 11: Top-K sweep
├── run_fig14.sh               # Figure 14: Remote access ratio
├── run_fig16a.sh              # Figure 16(a): RBFS relax sweep
├── run_fig16b.sh              # Figure 16(b): PQ pruning (코드 수정 필요)
├── setup/                     # ★ 환경 구축 스크립트 ★
│   ├── phase1_collect_info.sh     # 노드 정보 수집
│   ├── phase2_ssh_setup.sh        # SSH 무비밀번호 설정
│   ├── phase3_install_rdma.sh     # RDMA 유저스페이스 도구
│   ├── phase4_install_deps.sh     # OpenMPI, Boost 1.85, MKL, CMake
│   ├── phase5_build_and_setup.sh  # RED-ANNS 빌드 + 클러스터 설정
│   ├── phase6_test_rdma.sh        # RDMA 연결 테스트
│   └── run_on_all_nodes.sh        # 스크립트 일괄 실행
├── logs/                      # 실험 로그 (자동 생성)
└── results/                   # CSV + PNG/PDF (자동 생성)
```

---

## 전체 설정 워크플로우

> **모든 명령은 node-0에서 실행** (마스터 노드)

### Phase 0: CloudLab 실험 생성
CloudLab에서 4노드 실험을 시작하고 SSH 접속을 확인합니다.

### Phase 1: 노드 정보 수집 (✅ 완료)
```bash
# 이미 수집 완료. 위의 환경 정보 참고.
```

### Phase 2: SSH 무비밀번호 설정 (~1분)
```bash
# node-0에서만 실행
cd ~/RED-ANNS/experiments/setup
bash phase2_ssh_setup.sh
```

이 스크립트가 하는 일:
1. **hostname 기반 SSH 확인** (CloudLab이 자동 설정했을 수 있음)
2. SSH 키 생성 (없으면)
3. hostname으로 모든 노드에 공개키 복사
4. 모든 노드에 키 동기화 + **experiment IP도 known_hosts에 등록**
5. hostname **및** experiment IP 기반 cross-node SSH 검증

> **중요**: MPI는 `hosts.mpi`의 `10.10.1.x` IP로 SSH하므로,
> experiment IP SSH도 작동해야 합니다.

### Phase 3: RDMA 유저스페이스 도구 설치 (~5분)
```bash
# node-0에서 모든 노드에 일괄 실행 (hostname으로 SSH/SCP)
bash run_on_all_nodes.sh phase3_install_rdma.sh
```

설치 후 확인:
```bash
ibv_devinfo -d mlx5_0    # RDMA 디바이스 정보
ibdev2netdev             # mlx5_0 → ens2f0np0 (Up) 확인
```

### Phase 4: 빌드 의존성 설치 (~15분)
```bash
bash run_on_all_nodes.sh phase4_install_deps.sh
```

설치 항목: OpenMPI, Boost 1.85 (소스 빌드), CMake, Intel MKL, matplotlib

### Phase 5: RED-ANNS 빌드 + 클러스터 설정 (~5분)
```bash
bash phase5_build_and_setup.sh
```

이 스크립트가 하는 일:
1. `global.hpp` 설정 확인 (num_servers=4, num_threads=8 등)
2. `hosts`/`hosts.mpi` 파일 생성 (**10.10.1.x experiment IP만!**)
3. `build.sh` 실행
4. **hostname으로** rsync하여 모든 노드에 바이너리 동기화

### Phase 6: RDMA 연결 테스트 (~2분)
```bash
bash phase6_test_rdma.sh
```

테스트 내용:
1. 각 노드의 RDMA 디바이스 **자동 감지** (node-3 NIC 차이 처리)
2. `ibv_devinfo` (SSH via hostname → 각 노드 확인)
3. MPI hostname 테스트 (experiment 서브넷 제한)
4. `ib_write_bw`: SSH는 hostname, RDMA 서버 주소는 experiment IP
5. `ib_read_lat`: 위와 동일

기대 결과:
- Bandwidth: ~90-100 Gbps (ConnectX-6 100G)
- Latency: ~1-3 μs

---

## 데이터셋 준비

### ⚠️ 디스크 공간 주의
현재 노드당 **~57 Gi** 여유. 100M 데이터셋은 **30-50 Gi** 필요.

**옵션 A: 추가 스토리지 마운트** (권장)
```bash
lsblk
sudo mkfs.ext4 /dev/sdb
sudo mount /dev/sdb /mnt/data
```

**옵션 B: 작은 데이터셋 사용**
- deep10M: base ~3.8GB + index ~1GB = ~5GB

### 데이터셋 다운로드
```bash
# DEEP-100M (~38GB)
mkdir -p /mnt/data/deep100M && cd /mnt/data/deep100M
wget https://storage.yandexcloud.net/yandex-research/ann-datasets/deep/base.1B.fbin.crop_nb_100000000
wget https://storage.yandexcloud.net/yandex-research/ann-datasets/deep/query.public.10K.fbin
wget https://storage.yandexcloud.net/yandex-research/ann-datasets/deep/gt100-public.10K.bin
```

### JSON 설정 파일
`app/deep100M_K4.json` 예시:
```json
{
    "base_file": "/mnt/data/deep100M/base.fbin",
    "query_file": "/mnt/data/deep100M/query.fbin",
    "gt_file": "/mnt/data/deep100M/gt.bin",
    "graph_file": "/mnt/data/deep100M/deep100M.vamana",
    "bkmeans_labels": "/mnt/data/deep100M/bkmeans_labels.txt",
    "bkmeans_centroids": "/mnt/data/deep100M/bkmeans_centroids.txt",
    "dim": 96,
    "num_base": 100000000,
    "num_query": 10000
}
```

---

## 실험 실행

### 빠른 테스트 (더미 데이터, 클러스터 불필요)
```bash
cd ~/RED-ANNS/experiments
bash run_all.sh --dry-run
# → 더미 로그 생성 → CSV 파싱 → 그래프 플로팅
```

### 실제 실험
```bash
cd ~/RED-ANNS/experiments

# Figure별 개별 실행
bash run_fig10.sh deep100M     # ~2시간
bash run_fig11.sh deep100M     # ~30분
bash run_fig14.sh deep100M     # ~20분
bash run_fig16a.sh deep100M    # ~15분

# 전체 실행
bash run_all.sh

# 결과 파싱 + 플로팅
python3 parse_logs.py --figure fig10
python3 plot_all.py --figure fig10 --pdf
```

---

## 재현 가능한 Figure 목록

| Figure | 설명 | 스크립트 | 예상 시간 | 난이도 |
|--------|------|----------|-----------|--------|
| Fig 10 | QPS vs Recall@10 | run_fig10.sh | ~2h | ★★★ 핵심 |
| Fig 11 | Top-K (1,10,100) | run_fig11.sh | ~30m | ★★ |
| Fig 12 | Dist. computation | (Fig10 데이터) | 0 | ★ |
| Fig 14 | Remote access ratio | run_fig14.sh | ~20m | ★★ |
| Fig 16a| RBFS latency | run_fig16a.sh | ~15m | ★★★ 핵심 |
| Fig 16b| PQ pruning (ε) | run_fig16b.sh | ~20m | ★★★ 코드수정 |

---

## 논문 환경 vs 현재 환경

| 항목 | 논문 환경 | CloudLab 환경 |
|------|-----------|---------------|
| CPU | 2x Xeon Silver 4210R + 2x Gold 5218 | 4x Xeon Silver 4314 (16C) |
| Memory | 128 GB/node | 251 GB/node |
| NIC | ConnectX-5 100Gbps | ConnectX-6 Dx/Lx 100Gbps |
| Switch | SN2100 100GbE | CloudLab infra |
| OS | Ubuntu 20.04 | Ubuntu 22.04 |
| Disk | 충분 | ~57 Gi (제한적) |

---

## 트러블슈팅

### MPI 연결 오류
```bash
# 서브넷으로 NIC 지정 (NIC 이름이 노드마다 다르므로)
mpiexec --mca btl_tcp_if_include 10.10.1.0/24 \
        --mca oob_tcp_if_include 10.10.1.0/24 ...

# experiment IP로 SSH 안 되면:
ssh 10.10.1.1 hostname   # 각 노드에서 테스트
# 안 되면 phase2 다시 실행
```

### RDMA 초기화 실패
```bash
ulimit -l                 # unlimited여야 함
# 부족하면:
sudo bash -c 'echo "* soft memlock unlimited" >> /etc/security/limits.conf'
sudo bash -c 'echo "* hard memlock unlimited" >> /etc/security/limits.conf'
# 재로그인 후 확인
```

### run_on_all_nodes.sh SCP 실패
```bash
# hostname으로 SSH 가능한지 확인
ssh node-1 hostname
# 안 되면 phase2 먼저 실행
# 또는 각 노드에서 직접 실행:
ssh node-1 'sudo bash /tmp/phase3_install_rdma.sh'
```

### 결과가 논문과 다름
- 하드웨어 차이로 **절대값은 다를 수 있음** (정상)
- **상대적 성능 순서**만 확인: RED-ANNS > Locality+Sched > Locality > Random > MR-ANNS
