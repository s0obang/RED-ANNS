#!/usr/bin/env python3
"""
Build a Vamana-compatible .vamana file from a raw bin dataset.

Format:
  [uint64 file_size][uint32 max_degree][uint32 start][uint64 frozen_pts]
  Then for each node: [uint32 degree][uint32 neighbor ids...]
"""

import argparse
import os
import struct
from pathlib import Path

import numpy as np


def read_bin_vectors(path: str):
    with open(path, "rb") as f:
        header = np.fromfile(f, dtype=np.uint32, count=2)
        if header.size != 2:
            raise RuntimeError(f"invalid bin file header: {path}")
        n, dim = int(header[0]), int(header[1])
        mm = np.memmap(path, dtype=np.float32, mode="r", offset=8, shape=(n, dim))
        return n, dim, mm


def write_vamana(out_path: str, n: int, dim: int, neighbors: np.ndarray):
    # neighbors: (n, R), uint32
    neighbors = np.asarray(neighbors, dtype=np.uint32)
    if neighbors.ndim != 2 or neighbors.shape[0] != n:
        raise ValueError("invalid neighbors shape")
    max_degree = neighbors.shape[1] if neighbors.size else 0
    # from graph header, expected_file_size is computed using fixed max_degree
    expected_file_size = (8 + 4 + 4 + 8) + n * (4 + 4 * max_degree)
    with open(out_path, "wb") as f:
        f.write(struct.pack("<Q", expected_file_size))
        f.write(struct.pack("<I", max_degree))
        f.write(struct.pack("<I", 0))
        f.write(struct.pack("<Q", 0))
        for i in range(n):
            row = neighbors[i]
            k = int(row.shape[0])
            f.write(struct.pack("<I", k))
            f.write(row.astype("<u4").tobytes())


def exact_knn(data: np.ndarray, k: int, batch_size: int = 512):
    n, dim = data.shape
    if k >= n:
        raise ValueError("k must be smaller than num vectors")
    sq = np.einsum("ij,ij->i", data, data)
    neighbors = np.empty((n, k), dtype=np.uint32)
    for i in range(0, n, batch_size):
        end = min(n, i + batch_size)
        x = data[i:end]
        # shape: (bs, n)
        dist = sq[i:end, None] + sq[None, :] - 2.0 * (x @ data.T)
        np.fill_diagonal(dist[:, i:end], np.inf)
        idx = np.argpartition(dist, k, axis=1)[:, :k]
        # stable sort inside k for deterministic order
        vals = np.take_along_axis(dist, idx, axis=1)
        order = np.argsort(vals, axis=1)
        neighbors[i:end] = np.take_along_axis(idx, order, axis=1).astype(np.uint32)
    return neighbors


def approx_knn(data: np.ndarray, k: int, ef: int = 200, M: int = 16):
    try:
        import hnswlib
    except Exception:
        raise RuntimeError(
            "Approximate mode requires hnswlib (pip install hnswlib). "
            "Set --mode exact or install hnswlib."
        )

    n, dim = data.shape
    if k >= n:
        raise ValueError("k must be smaller than num vectors")

    index = hnswlib.Index(space="l2", dim=dim)
    index.init_index(max_elements=n, M=M, ef_construction=200)
    index.set_ef(ef)
    index.add_items(data.astype(np.float32), np.arange(n, dtype=np.int32))

    k_query = k + 1
    labels = np.empty((n, k), dtype=np.uint32)
    BATCH = 10000
    for start in range(0, n, BATCH):
        end = min(n, start + BATCH)
        q = data[start:end]
        nn, _ = index.knn_query(q, k=k_query)
        # remove self id if present
        for i in range(end - start):
            row = nn[i]
            row = row[row != (start + i)]
            if row.shape[0] < k:
                extra, _ = index.knn_query(q[i:i+1], k=k_query + 2)
                row = extra[0][extra[0] != (start + i)]
                row = row[:k]
            else:
                row = row[:k]
            labels[start + i] = row.astype(np.uint32)
    return labels


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="input .fbin file")
    parser.add_argument("--output", required=True, help="output .vamana file")
    parser.add_argument("--k", type=int, required=True, help="out-degree")
    parser.add_argument("--mode", choices=["exact", "approx"], default="exact")
    parser.add_argument("--ef", type=int, default=200)
    parser.add_argument("--M", type=int, default=16)
    parser.add_argument("--batch", type=int, default=1024, help="exact mode batch rows")
    parser.add_argument("--max-memory-items", type=int, default=0,
                        help="not implemented; keep dataset from memmap")
    args = parser.parse_args()

    if args.k <= 0:
        raise ValueError("--k must be > 0")

    n, dim, data = read_bin_vectors(args.input)
    print(f"input n={n}, dim={dim}, k={args.k}, mode={args.mode}")
    data_f = np.asarray(data, dtype=np.float32)

    if args.mode == "exact":
        neighbors = exact_knn(data_f, args.k, batch_size=max(1, args.batch))
    else:
        if n > 100000 and args.k > 64:
            print("warning: large n and large k; exact quality may be expensive.")
        neighbors = approx_knn(data_f, args.k, ef=args.ef, M=args.M)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    write_vamana(args.output, n, dim, neighbors)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
