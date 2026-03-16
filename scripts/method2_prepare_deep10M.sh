#!/usr/bin/env bash

# ------------------------------------------------------------
# RED-ANNS deep10M 방법2 (로컬 준비용 최소 스크립트)
# - 목표: methods that are required by repo-based tests can be prepared.
# - 그래프 파일은 외부 빌더가 있으면 외부 빌더를 사용하고,
#   없으면 실험용 임시 ring graph를 생성합니다(정확도는 낮음).
# ------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DATA_DIR="${1:-/ann/data/deep10M}"
JSON_OUT="${2:-$ROOT_DIR/app/deep10M_query10k_local_method2.json}"

BASE_FILE_DEFAULT="$DATA_DIR/base.10M.fbin"
QUERY_FILE_DEFAULT="$DATA_DIR/query.public.10K.fbin"
GT_FILE_DEFAULT="$DATA_DIR/groundtruth.public.10K.ibin"

BASE_FILE="${BASE_FILE:-$BASE_FILE_DEFAULT}"
QUERY_FILE="${QUERY_FILE:-$QUERY_FILE_DEFAULT}"
GT_FILE="${GT_FILE:-$GT_FILE_DEFAULT}"

BKMEANS_K="${BKMEANS_K:-4}"
SAMPLE_SIZE="${SAMPLE_SIZE:-1000}"
LEARN_GT_K="${LEARN_GT_K:-100}"

SAMPLE_FILE="$DATA_DIR/deep10M_sample1k.fbin"
SAMPLE_GT_FILE="$DATA_DIR/deep10M_sample1k_gt100.ibin"
SAMPLE_GRAPH_FILE="$DATA_DIR/deep10M_sample1k.vamana"

BASE_GRAPH_FILE="$DATA_DIR/deep10M.vamana"
BKMEANS_INPUT_FILE="$DATA_DIR/deep10M.bkmeans_input.txt"
BKMEANS_LABEL_FILE="$DATA_DIR/deep10M_K${BKMEANS_K}.bkmeans_labels.txt"
BKMEANS_CENT_FILE="$DATA_DIR/deep10M_K${BKMEANS_K}.bkmeans_centroids.txt"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command '$1' not found." >&2
    exit 1
  }
}

need_cmd python3

mkdir -p "$DATA_DIR"

for f in "$BASE_FILE" "$QUERY_FILE" "$GT_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    echo "- 먼저 base/query/gt를 /ann/data/deep10M에 준비해 주세요." >&2
    exit 1
  fi
done

if [[ ! -f "$SAMPLE_FILE" ]]; then
  echo "[1/6] create $SAMPLE_FILE (from base sample)"

  python3 - "$BASE_FILE" "$SAMPLE_SIZE" "$SAMPLE_FILE" <<'PY'
import argparse
import numpy as np
import struct

parser = argparse.ArgumentParser()
parser.add_argument('base')
parser.add_argument('sample_size', type=int)
parser.add_argument('out')
args = parser.parse_args()

with open(args.base, 'rb') as f:
    header = np.fromfile(f, dtype=np.uint32, count=2)
    n, d = int(header[0]), int(header[1])

if args.sample_size > n:
    raise RuntimeError(f"sample_size={args.sample_size} is larger than n={n}")

mm = np.memmap(args.base, mode='r', dtype=np.float32, offset=8, shape=(n, d), order='C')
rs = np.random.RandomState(42)
idx = rs.choice(n, size=args.sample_size, replace=False)
sample = np.asarray(mm[idx], dtype=np.float32)

with open(args.out, 'wb') as f:
    f.write(struct.pack('<II', sample.shape[0], sample.shape[1]))
    sample.tofile(f)

print(f"OK: write {args.sample_size} samples from base ({n}, {d})")
PY
else
  echo "[skip] $SAMPLE_FILE exists"
fi

echo "[2/6] create learn_gt ($SAMPLE_GT_FILE) - top-${LEARN_GT_K} on sample vs sample"
python3 - "$SAMPLE_FILE" "$LEARN_GT_K" "$SAMPLE_GT_FILE" <<'PY'
import argparse
import numpy as np
import struct

parser = argparse.ArgumentParser()
parser.add_argument('sample')
parser.add_argument('k', type=int)
parser.add_argument('out')
args = parser.parse_args()

with open(args.sample, 'rb') as f:
    header = np.fromfile(f, dtype=np.uint32, count=2)
    n, d = int(header[0]), int(header[1])
    data = np.fromfile(f, dtype=np.float32).reshape(n, d)

sq = (data ** 2).sum(axis=1, keepdims=True)
dist = sq + sq.T - 2.0 * data @ data.T
np.fill_diagonal(dist, np.inf)

k = min(int(args.k), n - 1)
nn = np.argpartition(dist, k, axis=1)[:, :k]
nn = np.take_along_axis(nn, np.argsort(np.take_along_axis(dist, nn, axis=1), axis=1), axis=1)

with open(args.out, 'wb') as f:
    f.write(struct.pack('<II', nn.shape[0], nn.shape[1]))
    nn.astype(np.uint32).tofile(f)

print(f"OK: write learn gt ({args.out})")
PY

echo "[3/6] create bkmeans_input from sample"
python3 - "$SAMPLE_FILE" "$BKMEANS_INPUT_FILE" <<'PY'
import argparse
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('sample')
parser.add_argument('out')
args = parser.parse_args()

with open(args.sample, 'rb') as f:
    header = np.fromfile(f, dtype=np.uint32, count=2)
    n, d = int(header[0]), int(header[1])
    data = np.fromfile(f, dtype=np.float32).reshape(n, d)

with open(args.out, 'w') as f:
    for v in data:
        f.write(' '.join(f'{x:.6f}' for x in v) + '\n')

print(f"OK: write {n} vectors to {args.out}")
PY

echo "[4/6] make bkmeans labels/centroids"
export DATA_DIR BASE_FILE BKMEANS_K
python3 - <<'PY'
import os
import numpy as np
from pathlib import Path

DATA_DIR = os.environ['DATA_DIR']
SAMPLE_FILE = os.path.join(DATA_DIR, 'deep10M_sample1k.fbin')
BASE_FILE = os.environ['BASE_FILE']
K = int(os.environ['BKMEANS_K'])
LABEL_FILE = os.path.join(DATA_DIR, f'deep10M_K{K}.bkmeans_labels.txt')
CENT_FILE = os.path.join(DATA_DIR, f'deep10M_K{K}.bkmeans_centroids.txt')

with open(SAMPLE_FILE, 'rb') as f:
    h = np.fromfile(f, dtype=np.uint32, count=2)
    ns, d = int(h[0]), int(h[1])
    sample = np.fromfile(f, dtype=np.float32).reshape(ns, d)

centers = sample[:min(K, ns)].copy()
if ns >= K:
    # simple kmeans++ style init
    rng = np.random.RandomState(42)
    idx = [rng.randint(0, ns)]
    while len(idx) < K:
        d2 = np.min(((sample[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2), axis=1)
        probs = d2 / d2.sum()
        idx.append(int(rng.choice(ns, p=probs)))
        centers = sample[idx]

centers = centers.astype(np.float32)

with open(CENT_FILE, 'w') as f:
    for c in centers:
        f.write(' '.join(f'{x:.6f}' for x in c) + '\n')

with open(BASE_FILE, 'rb') as bf:
    hb = np.fromfile(bf, dtype=np.uint32, count=2)
    n_base, d_base = int(hb[0]), int(hb[1])

mm = np.memmap(BASE_FILE, mode='r', dtype=np.float32, offset=8, shape=(n_base, d_base), order='C')

with open(LABEL_FILE, 'w') as lf:
    for start in range(0, n_base, 500000):
        end = min(start + 500000, n_base)
        block = np.asarray(mm[start:end], dtype=np.float32)
        dist = ((block[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
        lbl = np.argmin(dist, axis=1)
        for v in lbl:
            lf.write(f'{int(v)}\n')

print(f"OK: write {n_base} labels to {LABEL_FILE}")
print(f"OK: write centroids to {CENT_FILE}")
PY

echo "[5/6] ensure learn graph ($SAMPLE_GRAPH_FILE)"
if [[ -f "$SAMPLE_GRAPH_FILE" ]]; then
  echo "[skip] existing: $SAMPLE_GRAPH_FILE"
else
  if [[ -n "${VAMANA_LEARN_BUILDER:-}" && -x "${VAMANA_LEARN_BUILDER}" ]]; then
    echo "외부 빌더 설정 감지: $VAMANA_LEARN_BUILDER"
    "$VAMANA_LEARN_BUILDER" \
      --base "$SAMPLE_FILE" --out "$SAMPLE_GRAPH_FILE" \
      --k "${BKMEANS_K}" \
      ${VAMANA_LEARN_ARGS:-}
  else
    echo "경고: VAMANA_LEARN_BUIL더 미지정 -> 샘플 기반 임시 ring graph 생성"
    N="$SAMPLE_SIZE" OUT="$SAMPLE_GRAPH_FILE" R="2" \
      python3 - <<'PY'
import os, struct
n = int(os.environ['N'])
out = os.environ['OUT']
R = int(os.environ['R'])

with open(out, 'wb') as f:
    f.write(struct.pack('<Q', 0))
    f.write(struct.pack('<I', R))
    f.write(struct.pack('<I', 0))
    f.write(struct.pack('<Q', 0))
    edges = 0
    for i in range(n):
        neighbors = [(i + r) % n for r in range(1, R + 1)]
        f.write(struct.pack('<I', len(neighbors)))
        for nb in neighbors:
            f.write(struct.pack('<I', nb))
        edges += len(neighbors)

file_size = (8 + 4 + 4 + 8) + edges * 4 + n * 4
with open(out, 'r+b') as f:
    f.seek(0)
    f.write(struct.pack('<Q', file_size))
print(f"OK: write {out}")
PY
  fi
fi

echo "[6/6] ensure base graph ($BASE_GRAPH_FILE)"
if [[ -f "$BASE_GRAPH_FILE" ]]; then
  echo "[skip] existing: $BASE_GRAPH_FILE"
else
  if [[ -n "${VAMANA_BASE_BUILDER:-}" && -x "${VAMANA_BASE_BUILDER}" ]]; then
    echo "외부 빌더 설정 감지: $VAMANA_BASE_BUILDER"
    "$VAMANA_BASE_BUILDER" \
      --base "$BASE_FILE" --out "$BASE_GRAPH_FILE" \
      --k "${BKMEANS_K}" \
      ${VAMANA_BASE_ARGS:-}
  else
    echo "경고: VAMANA_BASE_BUILDER 미지정 -> 임시 ring graph 생성(실행은 가능하나 성능/정확도 저하)"
    n_base="$(python3 - <<'PY'
import numpy as np, os
with open(os.environ['BASE_FILE'], 'rb') as f:
    print(int(np.fromfile(f, dtype=np.uint32, count=1)[0]))
PY
)"
    N="$n_base" OUT="$BASE_GRAPH_FILE" \
      python3 - <<'PY'
import os, struct
n = int(os.environ['N'])
out = os.environ['OUT']

with open(out, 'wb') as f:
    f.write(struct.pack('<Q', 0))
    f.write(struct.pack('<I', 1))
    f.write(struct.pack('<I', 0))
    f.write(struct.pack('<Q', 0))
    for i in range(n):
        f.write(struct.pack('<I', 1))
        f.write(struct.pack('<I', (i + 1) % n))

file_size = (8 + 4 + 4 + 8) + n * (1 + 1) * 4
with open(out, 'r+b') as f:
    f.seek(0)
    f.write(struct.pack('<Q', file_size))
print(f"OK: write {out}")
PY
  fi
fi

cat > "$JSON_OUT" <<EOF_JSON
{
  "metric": "L2",
  "file_format": "bin",
  "base_file": "$BASE_FILE",
  "graph_file": "$BASE_GRAPH_FILE",
  "learn_data_file": "$SAMPLE_FILE",
  "learn_graph_file": "$SAMPLE_GRAPH_FILE",
  "learn_gt_file": "$SAMPLE_GT_FILE",
  "query_file": "$QUERY_FILE",
  "gt_file": "$GT_FILE",
  "K": "10",
  "L": "100",
  "T": "16",
  "bkmeans_K": "$BKMEANS_K",
  "bkmeans_input_file": "$BKMEANS_INPUT_FILE",
  "bkmeans_labels_output_file": "$BKMEANS_LABEL_FILE",
  "bkmeans_centroids_output_file": "$BKMEANS_CENT_FILE",
  "bucket_count": "4",
  "filename_prefix": "./data/deep10M"
}
EOF_JSON

echo "[done] created: $JSON_OUT"
echo "  - base graph: $BASE_GRAPH_FILE"
echo "  - learn graph: $SAMPLE_GRAPH_FILE"
echo "  - learn data: $SAMPLE_FILE"
echo "  - learn gt: $SAMPLE_GT_FILE"
echo "  - bkmeans: $BKMEANS_CENT_FILE, $BKMEANS_LABEL_FILE"

