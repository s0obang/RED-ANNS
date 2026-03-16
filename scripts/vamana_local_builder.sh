#!/usr/bin/env bash
set -euo pipefail

# Adapter to call local Python Vamana graph generator with the interface expected by
# method2_prepare_deep10M.sh:
#   --base INPUT --out OUTPUT --k K
#
# Usage (required):
#   bash scripts/vamana_local_builder.sh --base <input> --out <output> --k <k>
#
# Optional env vars:
#   VAMANA_BUILDER_MODE: exact|approx (default: approx)
#   VAMANA_BUILDER_EF:    int (default: 1024)
#   VAMANA_BUILDER_M:     int (default: 64)

BASE_FILE=""
OUT_FILE=""
K=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE_FILE="$2"
      shift 2
      ;;
    --out)
      OUT_FILE="$2"
      shift 2
      ;;
    --k)
      K="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BASE_FILE" || -z "$OUT_FILE" || -z "$K" ]]; then
  echo "Usage: $0 --base <input> --out <output> --k <k>" >&2
  exit 1
fi

MODE="${VAMANA_BUILDER_MODE:-approx}"
EF="${VAMANA_BUILDER_EF:-1024}"
M="${VAMANA_BUILDER_M:-64}"

# For small sample graphs, default to exact for stability.
if [[ "$MODE" == "auto" ]]; then
  n=$(python3 - <<PY
import numpy as np,sys
hdr=np.fromfile(sys.argv[1],dtype=np.uint32,count=2)
print(int(hdr[0]))
PY
"$BASE_FILE")
  if [[ "$n" -le 2000 ]]; then
    MODE="exact"
  else
    MODE="approx"
  fi
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT_DIR/scripts/build_vamana_graph.py" \
  --input "$BASE_FILE" \
  --output "$OUT_FILE" \
  --k "$K" \
  --mode "${MODE}" \
  --ef "${EF}" \
  --M "${M}"

