#!/usr/bin/env bash

# Prepare RED-ANNS deep10M end-to-end:
# 1) download base/query/gt
# 2) generate derived files (sample, learn gt, bkmeans, graphs)
# 3) generate distributed partition files via test_search_membkt
# 4) optionally sync to other nodes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DATA_DIR="/ann/data/deep10M"
JSON_PATH="$ROOT_DIR/app/deep10M_query10k_K4.json"
NODES="node-1 node-2 node-3"
REMOTE_USER="$USER"
BUCKET_COUNT=4
SKIP_PARTITION=0
SKIP_SYNC=0

usage() {
  cat <<'EOF'
Usage:
  bash scripts/prepare_redanns_full_deep10M.sh [options]

Options:
  --data-dir PATH        target data dir (default: /ann/data/deep10M)
  --json PATH            config json path (default: app/deep10M_query10k_K4.json)
  --nodes "n1 n2 n3"     nodes to sync to (default: "node-1 node-2 node-3")
  --remote-user USER     ssh user for remote nodes (default: current $USER)
  --bucket-count N       number of buckets (default: 4)
  --skip-partition       skip test_search_membkt generation
  --skip-sync            skip node sync
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --json)
      JSON_PATH="$2"
      shift 2
      ;;
    --nodes)
      NODES="$2"
      shift 2
      ;;
    --remote-user)
      REMOTE_USER="$2"
      shift 2
      ;;
    --bucket-count)
      BUCKET_COUNT="$2"
      shift 2
      ;;
    --skip-partition)
      SKIP_PARTITION=1
      shift
      ;;
    --skip-sync)
      SKIP_SYNC=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command '$1' not found." >&2; exit 1; }; }

need_cmd bash
need_cmd python3
need_cmd wget

read_json_string() {
  local key="$1"
  python3 - "$JSON_PATH" "$key" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], "r"))
val = obj.get(sys.argv[2], "")
if isinstance(val, (int, float)):
    print(val)
else:
    print(val if val is not None else "")
PY
}

mkdir -p "$DATA_DIR"

base_file="$(read_json_string base_file)"
query_file="$(read_json_string query_file)"
gt_file="$(read_json_string gt_file)"
filename_prefix="$(read_json_string filename_prefix)"
bucket_count_json="$(read_json_string bucket_count)"
bkmeans_k="$(read_json_string bkmeans_K)"

if [[ -z "$filename_prefix" ]]; then
  filename_prefix="$DATA_DIR"
fi
if [[ -n "$bucket_count_json" ]]; then
  BUCKET_COUNT="$bucket_count_json"
fi
if [[ -z "$base_file" ]]; then
  base_file="$DATA_DIR/base.10M.fbin"
fi
if [[ -z "$query_file" ]]; then
  query_file="$DATA_DIR/query.public.10K.fbin"
fi
if [[ -z "$gt_file" ]]; then
  gt_file="$DATA_DIR/groundtruth.public.10K.ibin"
fi
if [[ -z "$bkmeans_k" ]]; then
  bkmeans_k=4
fi

echo "[1/4] ensure base/query/gt files in $DATA_DIR"

if [[ ! -f "$base_file" && -f "$DATA_DIR/base.10M.fbin" ]]; then
  base_file="$DATA_DIR/base.10M.fbin"
fi
if [[ ! -f "$query_file" && -f "$DATA_DIR/query.public.10K.fbin" ]]; then
  query_file="$DATA_DIR/query.public.10K.fbin"
fi
if [[ ! -f "$gt_file" && -f "$DATA_DIR/groundtruth.public.10K.ibin" ]]; then
  gt_file="$DATA_DIR/groundtruth.public.10K.ibin"
fi

if [[ ! -f "$base_file" ]]; then
  echo "download: $(basename "$base_file")"
  wget -c "https://storage.yandexcloud.net/yandex-research/ann-datasets/DEEP/$(basename "$base_file")" -O "$DATA_DIR/$(basename "$base_file")"
  base_file="$DATA_DIR/$(basename "$base_file")"
fi

if [[ ! -f "$query_file" ]]; then
  echo "download: $(basename "$query_file")"
  wget -c "https://storage.yandexcloud.net/yandex-research/ann-datasets/DEEP/$(basename "$query_file")" -O "$DATA_DIR/$(basename "$query_file")"
  query_file="$DATA_DIR/$(basename "$query_file")"
fi

if [[ ! -f "$gt_file" ]]; then
  echo "download: $(basename "$gt_file")"
  wget -c "https://storage.yandexcloud.net/yandex-research/ann-datasets/DEEP/$(basename "$gt_file")" -O "$DATA_DIR/$(basename "$gt_file")"
  gt_file="$DATA_DIR/$(basename "$gt_file")"
fi

echo "[2/4] generate method-2 artifacts (sample, gt, bkmeans, graphs)"
BASE_FILE="$base_file" QUERY_FILE="$query_file" GT_FILE="$gt_file" \
  BKMEANS_K="$bkmeans_k" \
  bash "$SCRIPT_DIR/method2_prepare_deep10M.sh" "$DATA_DIR" "$JSON_PATH"

if [[ "$SKIP_PARTITION" -eq 0 ]]; then
  echo "[3/4] generate partition files (meta / bucket_* / partition / lid / data_num)"
  BUILD_BIN="$ROOT_DIR/build/tests/test_search_membkt"
  if [[ ! -x "$BUILD_BIN" ]]; then
    echo "[skip] partition generation: missing executable $BUILD_BIN"
    echo "       run: bash build.sh"
    echo "       then rerun this script without --skip-partition"
  else
    (cd "$ROOT_DIR" && "$BUILD_BIN")
  fi
else
  echo "[3/4] skip partition generation"
fi

echo "[4/4] final required-file check"
missing=0
missing_list=()

required_files=(
  "$DATA_DIR/base.10M.fbin"
  "$DATA_DIR/query.public.10K.fbin"
  "$DATA_DIR/groundtruth.public.10K.ibin"
  "$DATA_DIR/deep10M.fbin"
  "$DATA_DIR/deep10M_sample1k.fbin"
  "$DATA_DIR/deep10M_sample1k_gt100.ibin"
  "$DATA_DIR/deep10M.bkmeans_input.txt"
  "$DATA_DIR/deep10M_K${bkmeans_k}.bkmeans_labels.txt"
  "$DATA_DIR/deep10M_K${bkmeans_k}.bkmeans_centroids.txt"
  "$DATA_DIR/deep10M_sample1k.vamana"
  "$DATA_DIR/deep10M.vamana"
)

if [[ "$SKIP_PARTITION" -eq 0 ]]; then
  required_files+=(
    "$filename_prefix.meta"
    "$filename_prefix.partition"
    "$filename_prefix.lid"
    "$filename_prefix.data_num"
  )

  for i in $(seq 0 $((BUCKET_COUNT-1))); do
    required_files+=("$filename_prefix.bucket_$i")
  done
fi

for f in "${required_files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "MISSING: $f"
    missing=1
    missing_list+=("$f")
  else
    echo "OK: $f"
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "Missing files exist. fix above before running RED-ANNS."
  echo "If bucket files are missing, set --skip-partition=0 after building and rerun."
  exit 1
fi

if [[ "$SKIP_SYNC" -eq 0 ]]; then
  need_cmd rsync
  need_cmd ssh
  echo "sync to nodes..."
  bash "$SCRIPT_DIR/sync_deep10M_nodes.sh" "$DATA_DIR" "$NODES" "$REMOTE_USER" "$BUCKET_COUNT" "$filename_prefix"
else
  echo "sync skipped."
fi

echo "[done] redanns preparation complete."
