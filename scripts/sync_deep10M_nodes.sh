#!/usr/bin/env bash

# Sync RED-ANNS deep10M artifacts from node-0 to all members.
set -euo pipefail

DATA_DIR="${1:-/ann/data/deep10M}"
NODES="${2:-node-1 node-2 node-3}"
REMOTE_USER="${3:-$USER}"
BUCKET_COUNT="${4:-4}"
FILENAME_PREFIX="${5:-$DATA_DIR}"

REMOTE_UID="$(id -u)"
REMOTE_GID="$(id -g)"

BASE_FILES=(
  "$DATA_DIR/base.10M.fbin"
  "$DATA_DIR/query.public.10K.fbin"
  "$DATA_DIR/groundtruth.public.10K.ibin"
  "$DATA_DIR/deep10M.vamana"
  "$DATA_DIR/deep10M_sample1k.fbin"
  "$DATA_DIR/deep10M_sample1k.vamana"
  "$DATA_DIR/deep10M_sample1k_gt100.ibin"
  "$DATA_DIR/deep10M.bkmeans_input.txt"
  "$DATA_DIR/deep10M_K4.bkmeans_centroids.txt"
  "$DATA_DIR/deep10M_K4.bkmeans_labels.txt"
  "$FILENAME_PREFIX.meta"
  "$FILENAME_PREFIX.partition"
  "$FILENAME_PREFIX.lid"
  "$FILENAME_PREFIX.data_num"
)

for i in $(seq 0 $((BUCKET_COUNT-1))); do
  BASE_FILES+=("$FILENAME_PREFIX.bucket_$i")
done

mkdir -p "$DATA_DIR"
mkdir -p "${FILENAME_PREFIX%/*}"

for n in $NODES; do
  echo "== $n =="
  ssh "$REMOTE_USER@$n" "sudo mkdir -p '$DATA_DIR' '${FILENAME_PREFIX%/*}' && sudo chown $REMOTE_UID:$REMOTE_GID '$DATA_DIR' '${FILENAME_PREFIX%/*}'"

  for f in "${BASE_FILES[@]}"; do
    if [[ ! -e "$f" ]]; then
      echo "  [skip] $(basename "$f") (missing)"
      continue
    fi

    echo "  sync $(basename "$f")"
    rsync -av --inplace --partial "$f" "$REMOTE_USER@$n:$f"
    ssh "$REMOTE_USER@$n" "sudo chown $REMOTE_UID:$REMOTE_GID '$f'"
  done
done

echo "[done] Sync complete."
