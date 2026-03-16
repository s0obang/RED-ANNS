# deep10M (방법 2) 외부 Vamana 빌더 연동 가이드

현재 저장소의 `scripts/method2_prepare_deep10M.sh`는 외부 빌더가 있으면 그 빌더를 사용하고,
없으면 임시 ring-graph를 만든 뒤 진행합니다.

## 1) 추천 실행 순서 (방법 2)

```bash
cd /ann/RED-ANNS
mkdir -p /ann/data/deep10M

# base/query/gt를 먼저 다운로드
wget -c https://storage.yandexcloud.net/yandex-research/ann-datasets/DEEP/base.10M.fbin -O /ann/data/deep10M/base.10M.fbin
wget -c https://storage.yandexcloud.net/yandex-research/ann-datasets/DEEP/query.public.10K.fbin -O /ann/data/deep10M/query.public.10K.fbin
wget -c https://storage.yandexcloud.net/yandex-research/ann-datasets/DEEP/groundtruth.public.10K.ibin -O /ann/data/deep10M/groundtruth.public.10K.ibin

# 방법2: 누락 파생물 생성 + JSON 갱신
bash scripts/method2_prepare_deep10M.sh /ann/data/deep10M app/deep10M_query10k_local_method2.json
```

출력 JSON: `app/deep10M_query10k_local_method2.json`

## 2) 외부 빌더 연동 (고품질)

`VAMANA_LEARN_BUILDER`와 `VAMANA_BASE_BUILDER`에 빌더 실행 파일을 지정하면
스크립트가 각 그래프를 해당 빌더로 생성합니다.

```bash
export VAMANA_LEARN_BUILDER=/path/to/learn_builder
export VAMANA_BASE_BUILDER=/path/to/base_builder
export VAMANA_LEARN_ARGS="--L 32 --R 128 --alpha 1.2"
export VAMANA_BASE_ARGS="--L 32 --R 128 --alpha 1.2"
bash scripts/method2_prepare_deep10M.sh /ann/data/deep10M app/deep10M_query10k_local_method2.json
```

빌더 인터페이스는 다음을 가정합니다.
- `--base <input_bin>`
- `--out <output_vamana>`
- `--k <int>`

빌더 인터페이스가 다르면 `VAMANA_*_ARGS`에 맞게 감싸서 실행 가능한 래퍼 스크립트를 만들어
`VAMANA_*_BUILDER`에 포인트하면 됩니다.

예시(래퍼):
```bash
cat > /tmp/my_deep10M_base_wrapper.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/path/to/tool --input "$1" --output "$2" --metric l2 "$@"
EOF
chmod +x /tmp/my_deep10M_base_wrapper.sh

export VAMANA_BASE_BUILDER=/tmp/my_deep10M_base_wrapper.sh
export VAMANA_BASE_ARGS="--some-tool-options"
```

## 3) 분산 실험 전 준비

`filename_prefix`가 `/ann/data/deep10M`으로 돼 있으므로 각 노드에서 동일 경로에 데이터가 있어야 합니다.
- `scripts/sync_deep10M_nodes.sh /ann/data/deep10M` 로 node-1/2/3 동기화
- `build/tests/test_search_membkt`로 `./data/deep10M.meta/.bucket/.partition/.lid/.data_num` 생성 필요(기존 구조 유지용)
