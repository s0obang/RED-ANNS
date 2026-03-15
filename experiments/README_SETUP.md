============================================================
 RED-ANNS 논문 Figure 재현 가이드
============================================================

## 파일 구조

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
├── logs/                      # 실험 로그 (자동 생성)
└── results/                   # CSV + PNG/PDF (자동 생성)


## 빠른 시작 (파이프라인 테스트)

실제 클러스터 없이 더미 데이터로 전체 파이프라인을 테스트:

    cd experiments
    bash run_all.sh --dry-run

이 명령은:
1. 논문 수치를 참고한 더미 로그 108개 생성
2. 로그를 CSV로 파싱
3. Figure 10, 11, 14, 16(a) 플로팅 (PNG + PDF)


## 실제 실험 실행

### Step 1: 환경 설정

#### 1.1 네트워크 확인
    # 4개 노드 간 SSH 무비밀번호 접속 확인
    ssh node1 hostname
    ssh node2 hostname
    ...

    # RDMA NIC 인터페이스 확인
    ibdev2netdev          # 또는 ibstat
    # 출력 예: mlx5_0 port 1 ==> eno1 (Up)

#### 1.2 hosts 파일 설정

hosts 파일 (RED-ANNS 루트):
    10.176.24.160
    10.176.24.162
    10.176.25.103
    10.176.25.104

hosts.mpi 파일:
    10.176.24.160 slots=1
    10.176.24.162 slots=1
    10.176.25.103 slots=1
    10.176.25.104 slots=1

#### 1.3 global.hpp 수정

include/global.hpp에서:
    static int num_servers = 4;    // 노드 수
    static int num_threads = 16;   // 논문: 8 (실험 시 변경)
    static int memstore_size_gb = 20;  // 노드 메모리에 맞게 조정

#### 1.4 config.sh 수정

experiments/config.sh에서:
    NIC_INTERFACE="eno1"           # 실제 RDMA NIC 이름
    NUMA_OPTS="numactl --cpunodebind=0 --membind=0"  # NUMA 설정
    DATASETS=(
        "deep100M:../app/deep100M_K4.json"
        "msturing:../app/msturing100M_K4.json"
        # ... 필요한 데이터셋 주석 해제
    )

### Step 2: 데이터 준비

#### 2.1 데이터셋 다운로드
    # BigANN Benchmark (DEEP, MS-Turing, Text2Image)
    # https://big-ann-benchmarks.com/

    # DEEP-100M
    wget http://...deep-image-96-angular.hdf5

    # 각 데이터셋별로 base.fbin, queries.fbin, groundtruth.ibin 필요

#### 2.2 인덱스 빌드 (Vamana graph)
    # 코드 내 인덱스 빌드 도구 사용
    # 또는 DiskANN 도구로 사전 빌드

#### 2.3 Balanced K-Means 파티셔닝
    # bkmeans 라벨/centroids 파일 생성
    # JSON에 경로가 설정되어 있어야 함

### Step 3: 빌드
    bash build.sh                  # Release 빌드
    # 또는
    bash debug.sh                  # Debug 빌드

### Step 4: 코드 동기화
    bash sync.sh                   # 모든 노드에 코드 배포

### Step 5: 실험 실행

    cd experiments

    # 전체 실행
    bash run_all.sh

    # Figure별 개별 실행
    bash run_fig10.sh              # ~2시간 (14 L값 × 5 configs)
    bash run_fig11.sh              # ~30분 (3 K값 × 4 configs)
    bash run_fig14.sh              # ~20분 (5 placement configs)
    bash run_fig16a.sh             # ~15분 (5 relax values)

    # 특정 데이터셋만
    bash run_fig10.sh deep100M

### Step 6: 결과 분석

    # 로그 파싱 → CSV
    python3 parse_logs.py --figure fig10
    python3 parse_logs.py --figure fig16a

    # 플로팅
    python3 plot_all.py --figure fig10 fig16a --pdf

    # 특정 데이터셋만
    python3 plot_all.py --figure fig10 --dataset deep100M


## 재현 가능한 Figure 목록

| Figure | 설명 | 스크립트 | 난이도 |
|--------|------|----------|--------|
| Fig 10 | QPS vs Recall@10 | run_fig10.sh | ★★★ 핵심 |
| Fig 11 | Top-K (1,10,100) sweep | run_fig11.sh | ★★ |
| Fig 12 | Dist. computation 비교 | (Fig10 데이터 활용) | ★ |
| Fig 14 | Remote ratio (placement) | run_fig14.sh | ★★ |
| Fig 16a| RBFS latency breakdown | run_fig16a.sh | ★★★ 핵심 |
| Fig 16b| PQ pruning (epsilon) | run_fig16b.sh | ★★★ 코드수정 필요 |


## Figure 16(b) 재현을 위한 코드 수정

epsilon이 index.cpp에 하드코딩되어 있어 외부 파라미터화 필요:

1) tests/test_search_distributed.cpp의 main()에서:
   - argc 체크를 10→11로 변경
   - argv[10]에서 epsilon 읽기:
     float epsilon = std::stof(std::string(argv[10]));

2) search 함수에 epsilon 전달:
   - test_search_distributed_with_dynamic_scheduling에 파라미터 추가

3) src/index.cpp에서 하드코딩된 1.1을 epsilon으로 교체:
   - pq.compute_dist(...) < best_L_nodes[...].distance * epsilon

4) 재빌드 후 run_fig16b.sh 실행


## 하드웨어 차이 참고

논문 환경:
    - 2× Dual Xeon Silver 4210R (10C/20T) + 128GB
    - 2× Dual Xeon Gold 5218 (16C/32T) + 128GB
    - ConnectX-5 100Gbps RoCE NIC
    - SN2100 100GbE switch

당신의 환경 (sm110p + sm220u):
    - 절대 수치(QPS)는 다를 수 있음
    - 상대적 트렌드(RED-ANNS > Locality > Random 등)는 재현 가능
    - NIC 종류/대역폭이 다르면 remote access latency가 달라짐
    - config.sh에서 NUMA_OPTS를 환경에 맞게 조정 필요


## 트러블슈팅

### MPI 연결 오류
    # NIC 인터페이스 확인
    mpiexec --mca btl_tcp_if_include eno1 ...

### RDMA 초기화 실패
    # ulimit 확인
    ulimit -l unlimited
    # /etc/security/limits.conf에 추가:
    # * soft memlock unlimited
    # * hard memlock unlimited

### 메모리 부족
    # global.hpp의 memstore_size_gb 줄이기
    # 또는 작은 데이터셋(deep10M) 사용

### 결과가 논문과 다름
    - 하드웨어 차이로 절대값은 다를 수 있음
    - 상대적 성능 순서(RED-ANNS > Locality > Random)만 확인
    - L 값 범위 조정 필요할 수 있음
