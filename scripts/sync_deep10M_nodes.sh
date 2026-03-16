#!/usr/bin/env bash

# ------------------------------------------------------------
# deep10M 노드 동기화 스크립트 (node-0 -> node-1/2/3)
# - 전제: ssh/rsync 노드 간 통신 가능
# - 생성된 파일 소유권을 원격 노드 사용자 기준으로 정리
# ------------------------------------------------------------

set -euo pipefail

DATA_DIR="${1:-/ann/data/deep10M}"
NODES="${2:-node-1 node-2 node-3}"
REMOTE_USER="${3:-$USER}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILES=(
  "base.10M.fbin"
  "query.public.10K.fbin"
  "groundtruth.public.10K.ibin"
  "deep10M.vamana"
  "deep10M_sample1k.fbin"
  "deep10M_sample1k.vamana"
  "deep10M_sample1k_gt100.ibin"
  "deep10M.bkmeans_input.txt"
  "deep10M_K4.bkmeans_centroids.txt"
  "deep10M_K4.bkmeans_labels.txt"
)

REMOTE_UID="$(id -u)"
REMOTE_GID="$(id -g)"

mkdir -p "$DATA_DIR"

for n in $NODES; do
  echo "== $n =="
  echo "Check remote directory..."
  ssh "$REMOTE_USER@$n" "sudo mkdir -p '$DATA_DIR' && sudo chown $REMOTE_UID:$REMOTE_GID '$DATA_DIR'"

  for f in "${FILES[@]}"; do
    local_path="$DATA_DIR/$f"
    if [[ -f "$local_path" ]]; then
      echo "  sync $f"
      rsync -av --inplace --partial "$local_path" "$REMOTE_USER@$n:$DATA_DIR/$f"
      ssh "$REMOTE_USER@$n" "sudo chown $REMOTE_UID:$REMOTE_GID '$DATA_DIR/$f'"
    else
      echo "  [skip] $local_path (missing)"
    fi
  done
done

echo "[done] Sync complete."

