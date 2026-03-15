# RED-ANNS 실험 재현 가이드

## ⚠️ CloudLab Control Network 주의사항 (필독!)

CloudLab은 **control network**와 **experiment network**를 엄격히 분리합니다.
control network의 과도한 사용은 **계정 정지** 또는 **실험 종료**를 초래합니다.

```
[Control Network]  128.105.x.x  (ens1f0np0, mlx5_4)  ← 인터넷 접속, SSH 로그인용
[Experiment Network]  10.10.1.x  (ens2f0np0 또는 ens2f1np1)  ← 모든 실험 트래픽용
```

**노드별 NIC 매핑:**
| 노드 | NIC 이름 | IP |
|------|---------|-----|
| node-0 | ens2f0np0 | 10.10.1.2 |
| node-1 | ens2f0np0 | 10.10.1.1 |
| node-2 | ens2f0np0 | 10.10.1.3 |
| node-3 | **ens2f1np1** | 10.10.1.4 |

**반드시 지켜야 할 사항:**
- `hosts`, `hosts.mpi` 파일에는 반드시 **10.10.1.x** (experiment network) IP만 기입
- MPI: NIC 이름 대신 **서브넷** `10.10.1.0/24`로 제한 (node-3 NIC 이름이 다르므로)
- RDMA 트래픽은 experiment NIC로만 전송
- 노드 간 FQDN(hostname) 대신 10.10.1.x IP 사용 (FQDN은 control net으로 해석됨)
- `config.sh`의 `run_mpi()` 함수에 이 설정이 포함되어 있음

**허용되는 control network 사용:**
- SSH 로그인 (외부에서 접속)
- apt-get 등 패키지 설치 (1회성)
- git clone/pull (1회성)

**확인 방법 (실험 실행 중):**
```bash
# control network 인터페이스의 트래픽 확인 (거의 0이어야 함)
tcpdump -c 100 -n -i ens1f0np0 not port ssh and not arp
# CloudLab 웹 UI → Experiment → Graphs 탭에서 Control Traffic 확인
```

참고: https://docs.cloudlab.us/control-net.html

---

## CloudLab Wisconsin 환경 정보 (Phase 1 수집)

```
호스트:    node-{0,1,2,3}.red-anns.ebpfnetworking-pg0.wisc.cloudlab.us
OS:        Ubuntu 22.04.2 LTS, kernel 5.15.0-168-generic
CPU:       2× Intel Xeon Silver 4314 @ 2.40GHz (16C/32T each, 64 logical CPUs)
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
├── config.sh                  # 클러스터/데이터셋 설정 (★ 수정 필요)
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

### Phase 0: CloudLab 실험 생성
CloudLab에서 4노드 실험을 시작하고 SSH 접속을 확인합니다.

### Phase 1: 노드 정보 수집 (✅ 완료)
```bash
# 이미 수집 완료. 위의 환경 정보 참고.
```

### Phase 2: SSH 무비밀번호 설정 (~5분)
```bash
# node-0 (마스터)에서만 실행
cd ~/RED-ANNS/experiments/setup

# ★ 먼저 phase2_ssh_setup.sh 열어서 NODE_IPS를 실제 IP로 수정 ★
vim phase2_ssh_setup.sh
# NODE_IPS=("10.10.1.2" "10.10.1.3" "10.10.1.4" "10.10.1.5")

bash phase2_ssh_setup.sh
```

**CloudLab 팁**: CloudLab은 실험 생성 시 자동으로 SSH 키를 배포하므로,
이미 무비밀번호 접속이 가능할 수 있습니다. Phase 2가 이를 확인합니다.

### Phase 3: RDMA 유저스페이스 도구 설치 (~5분)
```bash
# 방법 1: 마스터에서 모든 노드에 일괄 실행 (Phase 2 완료 후)
bash run_on_all_nodes.sh phase3_install_rdma.sh

# 방법 2: 각 노드에서 개별 실행
sudo bash phase3_install_rdma.sh
```

**커널 드라이버는 이미 로드됨** (mlx5_core, mlx5_ib). rdma-core만 설치하면 됩니다.

확인:
```bash
ibv_devinfo -d mlx5_0    # RDMA 디바이스 정보
ibdev2netdev             # mlx5_0 → ens2f0np0 (Up) 확인
```

### Phase 4: 빌드 의존성 설치 (~15분)
```bash
bash run_on_all_nodes.sh phase4_install_deps.sh
```

설치 항목:
| 패키지 | 버전 | 비고 |
|--------|------|------|
| OpenMPI | apt (4.1.x) | mpiexec |
| Boost | 1.85.0 (소스 빌드) | 기존 1.74 → 업그레이드 |
| CMake | apt (3.22+) | |
| Intel MKL | oneAPI | distance 계산 가속 |
| matplotlib | pip | 플로팅용 |

⚠️ Boost 1.85 소스 빌드에 5-10분 소요 (32코어 기준)

### Phase 5: RED-ANNS 빌드 + 클러스터 설정 (~5분)
```bash
# ★ 먼저 phase5_build_and_setup.sh의 NODE_IPS 수정 ★
vim phase5_build_and_setup.sh

bash phase5_build_and_setup.sh
```

이 스크립트가 하는 일:
1. `global.hpp` 설정 확인 (num_servers=4, num_threads=8 등)
2. `hosts`와 `hosts.mpi` 파일 생성 (10.10.1.x IP)
3. `build.sh` 실행
4. 모든 노드에 바이너리 동기화

### Phase 6: RDMA 연결 테스트 (~2분)
```bash
# ★ phase6_test_rdma.sh의 NODE_IPS 수정 ★
bash phase6_test_rdma.sh
```

기대 결과:
- ibv_devinfo: 모든 노드에서 mlx5_0 디바이스 정보 출력
- MPI hostname: 4개 노드 hostname 출력
- ib_write_bw: ~90-100 Gbps (ConnectX-6 100G)
- ib_read_lat: ~1-3 μs

---

## 데이터셋 준비

### ⚠️ 디스크 공간 주의
현재 노드당 **~57 Gi** 여유. 100M 데이터셋은 **30-50 Gi** 필요.

**옵션 A: 추가 스토리지 마운트** (권장)
```bash
# CloudLab에서 추가 디스크가 있으면 마운트
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

# MS-Turing-100M (~40GB)
# https://big-ann-benchmarks.com/ 에서 다운로드

# Text2Image-100M (~80GB, 200dim)
# https://big-ann-benchmarks.com/

# LAION-100M (~200GB, 512dim)
# https://big-ann-benchmarks.com/
```

### 인덱스 빌드 (Vamana Graph)
```bash
cd ~/RED-ANNS
# R=64, L=100 (논문 설정)
# 인덱스 빌드 바이너리 확인 후 실행
./build/tests/test_build_index <config.json>
```

### Balanced K-Means 파티셔닝
```bash
# K=4 (4노드)
# 출력: bkmeans_labels.txt, bkmeans_centroids.txt
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
# → results/ 에 fig10.png, fig11.png, fig14.png, fig16a.png 생성
```

### 실제 실험

```bash
cd ~/RED-ANNS/experiments

# ★ config.sh 확인 ★
# EXPERIMENT_SUBNET="10.10.1.0/24"  (NIC 이름이 노드마다 다르므로 서브넷 사용)
# NUMA_OPTS="numactl --cpunodebind=0 --membind=0"
# DATASETS에서 원하는 데이터셋 주석 해제

# Figure별 개별 실행
bash run_fig10.sh deep100M     # ~2시간 (14 L값 × 5 configs = 70 runs)
bash run_fig11.sh deep100M     # ~30분 (3 K값 × 4 configs = 12 runs)
bash run_fig14.sh deep100M     # ~20분 (5 placement configs)
bash run_fig16a.sh deep100M    # ~15분 (4 relax values)

# 전체 실행
bash run_all.sh

# 결과 파싱 + 플로팅
python3 parse_logs.py --figure fig10
python3 plot_all.py --figure fig10 --pdf
```

### 실행 순서 요약
```
1. config.sh 수정
2. bash run_fig10.sh deep100M     → logs/fig10_*.log
3. python3 parse_logs.py --fig10  → results/fig10_results.csv
4. python3 plot_all.py --fig10    → results/fig10.png + fig10.pdf
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
| CPU | 2× Xeon Silver 4210R (10C) + 2× Xeon Gold 5218 (16C) | 4× Xeon Silver 4314 (16C) |
| Memory | 128 GB/node | 251 GB/node |
| NIC | ConnectX-5 100Gbps | ConnectX-6 Dx/Lx 100Gbps |
| Switch | SN2100 100GbE | CloudLab infra |
| OS | Ubuntu 20.04 | Ubuntu 22.04 |
| Disk | 충분 | ~57 Gi (제한적) |

**차이점 영향**:
- 절대 QPS 수치는 다를 수 있음 (CPU 세대/클럭 차이)
- 상대적 트렌드 (RED-ANNS > Locality > Random)는 재현 가능
- ConnectX-6이 CX-5보다 latency가 약간 낮을 수 있음
- 메모리는 여유 (251 vs 128 GB)
- 디스크 공간이 제약 → 추가 스토리지 필요할 수 있음

---

## 트러블슈팅

### MPI 연결 오류
```bash
# NIC 인터페이스 명시
mpiexec --mca btl_tcp_if_include 10.10.1.0/24 --mca oob_tcp_if_include 10.10.1.0/24 ...

# 또는 btl_tcp_if_exclude로 외부 인터페이스 제외
mpiexec --mca btl_tcp_if_exclude ens1f0np0,lo ...
```

### RDMA 초기화 실패
```bash
# ulimit 확인 (unlimited여야 함)
ulimit -l

# 부족하면 설정
sudo bash -c 'echo "* soft memlock unlimited" >> /etc/security/limits.conf'
sudo bash -c 'echo "* hard memlock unlimited" >> /etc/security/limits.conf'
# 재로그인 후 확인
```

### 디스크 부족
```bash
# CloudLab 추가 디스크 확인
lsblk
# /dev/sdb 같은 디스크가 있으면 마운트
sudo mkfs.ext4 /dev/sdb
sudo mkdir -p /mnt/data
sudo mount /dev/sdb /mnt/data

# 또는 작은 데이터셋 사용
# config.sh에서 deep10M 등으로 변경
```

### Boost 빌드 실패
```bash
# 메모리 부족 시 (251Gi면 문제 없음)
./b2 install -j8 ...  # 병렬도 줄이기

# 디스크 부족 시
df -h /tmp  # /tmp 공간 확인
# 다른 디렉토리에서 빌드
cd /mnt/data && tar xzf /tmp/boost_1_85_0.tar.gz
```

### 결과가 논문과 다름
- 하드웨어 차이로 **절대값은 다를 수 있음** (정상)
- **상대적 성능 순서**만 확인: RED-ANNS > Locality+Sched > Locality > Random > MR-ANNS
- L 값 범위를 조정해야 할 수 있음 (recall 범위가 다르면)
- T=8로 통일 (config.sh 확인)
