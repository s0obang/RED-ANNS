#!/usr/bin/env bash

# Prepare deep10M data for RED-ANNS (method-2 pipeline).
# - Keep file name compatibility
# - Build sample + learn GT + bkmeans input/labels/centroids
# - Build base/learn graphs via external builder if provided
# - If builders are unavailable and VAMANA_FALLBACK=1, generate graphs via build_vamana_graph.py (approx on large base)

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

DEEP10M_FILE="$DATA_DIR/deep10M.fbin"

BKMEANS_K="${BKMEANS_K:-4}"
SAMPLE_SIZE="${SAMPLE_SIZE:-1000}"
LEARN_GT_K="${LEARN_GT_K:-100}"
VAMANA_FALLBACK="${VAMANA_FALLBACK:-0}"
VAMANA_GRAPH_BUILDER="${VAMANA_GRAPH_BUILDER:-$ROOT_DIR/scripts/build_vamana_graph.py}"
VAMANA_LEARN_GRAPH_K="${VAMANA_LEARN_GRAPH_K:-${BKMEANS_K}}"
VAMANA_BASE_GRAPH_K="${VAMANA_BASE_GRAPH_K:-32}"
VAMANA_FALLBACK_MODE="${VAMANA_FALLBACK_MODE:-approx}"
VAMANA_FALLBACK_LEARN_MODE="${VAMANA_FALLBACK_LEARN_MODE:-exact}"
VAMANA_FALLBACK_EF="${VAMANA_FALLBACK_EF:-256}"
VAMANA_FALLBACK_M="${VAMANA_FALLBACK_M:-32}"

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

if [[ ! -f "$BASE_FILE" ]]; then
  echo "ERROR: missing source base file: $BASE_FILE" >&2
  echo "Hint: expected at least one of them in $DATA_DIR" >&2
  echo "  - base.10M.fbin (downloaded from public link)" >&2
  echo "  - deep10M.fbin (if you downloaded with this name)" >&2
  exit 1
fi
if [[ ! -f "$QUERY_FILE" ]]; then
  echo "ERROR: missing source query file: $QUERY_FILE" >&2
  exit 1
fi
if [[ ! -f "$GT_FILE" ]]; then
  echo "ERROR: missing source gt file: $GT_FILE" >&2
  exit 1
fi

if [[ ! -f "$DEEP10M_FILE" ]]; then
  echo "[compat] create $DEEP10M_FILE as symlink to $BASE_FILE"
  ln -sfn "$BASE_FILE" "$DEEP10M_FILE"
fi

echo "[1/6] make sample(1000) file: $SAMPLE_FILE"
if [[ -f "$SAMPLE_FILE" ]]; then
  echo "[skip] exists: $SAMPLE_FILE"
else
python3 - "$BASE_FILE" "$SAMPLE_SIZE" "$SAMPLE_FILE" <<'PY'
import argparse
import numpy as np
import struct

parser = argparse.ArgumentParser()
parser.add_argument("base")
parser.add_argument("sample_size", type=int)
parser.add_argument("out")
args = parser.parse_args()

with open(args.base, "rb") as f:
    header = np.fromfile(f, dtype=np.uint32, count=2)
    n, d = int(header[0]), int(header[1])

if args.sample_size > n:
    raise RuntimeError(f"sample_size={args.sample_size} is larger than n={n}")

mm = np.memmap(args.base, mode="r", dtype=np.float32, offset=8, shape=(n, d), order="C")
rs = np.random.RandomState(42)
idx = rs.choice(n, size=args.sample_size, replace=False)
sample = np.asarray(mm[idx], dtype=np.float32)

with open(args.out, "wb") as f:
    f.write(struct.pack("<II", sample.shape[0], sample.shape[1]))
    sample.tofile(f)

print(f"OK: write {args.sample_size} samples from base ({n}, {d})")
PY
fi

echo "[2/6] make learn gt: $SAMPLE_GT_FILE"
python3 - "$SAMPLE_FILE" "$LEARN_GT_K" "$SAMPLE_GT_FILE" <<'PY'
import argparse
import numpy as np
import struct

parser = argparse.ArgumentParser()
parser.add_argument("sample")
parser.add_argument("k", type=int)
parser.add_argument("out")
args = parser.parse_args()

with open(args.sample, "rb") as f:
    header = np.fromfile(f, dtype=np.uint32, count=2)
    n, d = int(header[0]), int(header[1])
    data = np.fromfile(f, dtype=np.float32).reshape(n, d)

sq = (data ** 2).sum(axis=1, keepdims=True)
dist = sq + sq.T - 2.0 * data @ data.T
np.fill_diagonal(dist, np.inf)

k = min(int(args.k), n - 1)
nn = np.argpartition(dist, k, axis=1)[:, :k]
nn = np.take_along_axis(nn, np.argsort(np.take_along_axis(dist, nn, axis=1), axis=1), axis=1)

with open(args.out, "wb") as f:
    f.write(struct.pack("<II", nn.shape[0], nn.shape[1]))
    nn.astype(np.uint32).tofile(f)

print(f"OK: write learn gt ({args.out})")
PY

echo "[3/6] make bkmeans input: $BKMEANS_INPUT_FILE"
python3 - "$SAMPLE_FILE" "$BKMEANS_INPUT_FILE" <<'PY'
import argparse
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("sample")
parser.add_argument("out")
args = parser.parse_args()

with open(args.sample, "rb") as f:
    header = np.fromfile(f, dtype=np.uint32, count=2)
    n, d = int(header[0]), int(header[1])
    data = np.fromfile(f, dtype=np.float32).reshape(n, d)

with open(args.out, "w") as f:
    for v in data:
        f.write(" ".join(f"{x:.6f}" for x in v) + "\n")

print(f"OK: write {n} vectors to {args.out}")
PY

echo "[4/6] make bkmeans labels/centroids (k=$BKMEANS_K)"
python3 - "$BKMEANS_K" "$SAMPLE_FILE" "$BASE_FILE" "$BKMEANS_LABEL_FILE" "$BKMEANS_CENT_FILE" <<'PY'
import numpy as np

import sys

k, sample_file, base_file, label_file, cent_file = sys.argv[1:]
k = int(k)

with open(sample_file, "rb") as f:
    _ = np.fromfile(f, dtype=np.uint32, count=2)  # n, d
    sample = np.fromfile(f, dtype=np.float32).reshape(_[0], _[1])

centers = sample[: min(k, sample.shape[0])].copy()
if sample.shape[0] >= k:
    rng = np.random.RandomState(42)
    idx = [rng.randint(0, sample.shape[0])]
    while len(idx) < k:
        d2 = np.min(((sample[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2), axis=1)
        p = d2 / d2.sum()
        idx.append(int(rng.choice(sample.shape[0], p=p)))
        centers = sample[idx]

with open(cent_file, "w") as f:
    for c in centers:
        f.write(" ".join(f"{x:.6f}" for x in c) + "\n")

with open(base_file, "rb") as bf:
    header = np.fromfile(bf, dtype=np.uint32, count=2)
    n_base, d_base = int(header[0]), int(header[1])

base_mm = np.memmap(base_file, mode="r", dtype=np.float32, offset=8, shape=(n_base, d_base), order="C")
with open(label_file, "w") as f:
    for start in range(0, n_base, 500000):
        end = min(start + 500000, n_base)
        block = np.asarray(base_mm[start:end], dtype=np.float32)
        dist = ((block[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
        lbl = np.argmin(dist, axis=1)
        for v in lbl:
            f.write(f"{int(v)}\n")

print(f"OK: write {n_base} labels to {label_file}")
print(f"OK: write {centers.shape[0]} centroids to {cent_file}")
PY

echo "[5/6] ensure learn graph: $SAMPLE_GRAPH_FILE"
if [[ -f "$SAMPLE_GRAPH_FILE" ]]; then
  echo "[skip] exists: $SAMPLE_GRAPH_FILE"
else
  if [[ -n "${VAMANA_LEARN_BUILDER:-}" && -x "${VAMANA_LEARN_BUILDER}" ]]; then
    echo "Using external learn builder: $VAMANA_LEARN_BUILDER"
    builder_args=()
    [[ -n "${VAMANA_LEARN_ARGS:-}" ]] && IFS=' ' read -r -a builder_args <<< "$VAMANA_LEARN_ARGS"
    "$VAMANA_LEARN_BUILDER" --base "$SAMPLE_FILE" --out "$SAMPLE_GRAPH_FILE" --k "$BKMEANS_K" "${builder_args[@]}"
  elif [[ "$VAMANA_FALLBACK" == "1" ]]; then
    echo "Using fallback local Vamana generator for learn graph: $VAMANA_GRAPH_BUILDER"
    python3 "$VAMANA_GRAPH_BUILDER" \
      --input "$SAMPLE_FILE" \
      --output "$SAMPLE_GRAPH_FILE" \
      --k "$VAMANA_LEARN_GRAPH_K" \
      --mode "$VAMANA_FALLBACK_LEARN_MODE" \
      --ef "$VAMANA_FALLBACK_EF" \
      --M "$VAMANA_FALLBACK_M"
  else
    echo "ERROR: VAMANA_LEARN_BUILDER is not set or not executable."
    echo "       This script cannot safely build a valid learn graph without a real Vamana builder."
    echo "       To allow fallback generation, set VAMANA_FALLBACK=1."
    echo "       Set VAMANA_LEARN_BUILDER=/path/to/learn_builder and rerun."
    exit 1
  fi
fi

echo "[6/6] ensure base graph: $BASE_GRAPH_FILE"
if [[ -f "$BASE_GRAPH_FILE" ]]; then
  echo "[skip] exists: $BASE_GRAPH_FILE"
else
  if [[ -n "${VAMANA_BASE_BUILDER:-}" && -x "${VAMANA_BASE_BUILDER}" ]]; then
    echo "Using external base builder: $VAMANA_BASE_BUILDER"
    builder_args=()
    [[ -n "${VAMANA_BASE_ARGS:-}" ]] && IFS=' ' read -r -a builder_args <<< "$VAMANA_BASE_ARGS"
    "$VAMANA_BASE_BUILDER" --base "$DEEP10M_FILE" --out "$BASE_GRAPH_FILE" --k "$BKMEANS_K" "${builder_args[@]}"
  elif [[ "$VAMANA_FALLBACK" == "1" ]]; then
    echo "Using fallback local Vamana generator for base graph: $VAMANA_GRAPH_BUILDER"
    python3 "$VAMANA_GRAPH_BUILDER" \
      --input "$DEEP10M_FILE" \
      --output "$BASE_GRAPH_FILE" \
      --k "$VAMANA_BASE_GRAPH_K" \
      --mode "$VAMANA_FALLBACK_MODE" \
      --ef "$VAMANA_FALLBACK_EF" \
      --M "$VAMANA_FALLBACK_M"
  else
    echo "ERROR: VAMANA_BASE_BUILDER is not set or not executable."
    echo "       This script cannot safely build a valid base graph without a real Vamana builder."
    echo "       To allow fallback generation, set VAMANA_FALLBACK=1."
    echo "       Set VAMANA_BASE_BUILDER=/path/to/base_builder and rerun."
    exit 1
  fi
fi

cat > "$JSON_OUT" <<EOF_JSON
{
  "metric": "L2",
  "file_format": "bin",
  "base_file": "$DEEP10M_FILE",
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
  "filename_prefix": "$DATA_DIR"
}
EOF_JSON

echo "[done] wrote: $JSON_OUT"
echo " - base graph: $BASE_GRAPH_FILE"
echo " - learn graph: $SAMPLE_GRAPH_FILE"
echo " - sample: $SAMPLE_FILE"
echo " - learn gt: $SAMPLE_GT_FILE"
echo " - bkmeans: $BKMEANS_CENT_FILE, $BKMEANS_LABEL_FILE"
echo
echo "Next steps for full distributed run:"
echo "1) build partition files (meta/bucket/lid/data_num) with test_search_membkt if needed"
echo "2) sync all nodes using scripts/sync_deep10M_nodes.sh $DATA_DIR"
