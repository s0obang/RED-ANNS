#!/usr/bin/env python3
"""
JSON 설정 파일의 K, L, T 값을 변경한 임시 파일 생성.
MR-ANNS (test_map_reduce)는 실행 인자로 K,L,T를 받지 않고
JSON에서 읽으므로, L sweep 시 임시 JSON 필요.
"""
import json
import argparse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_json", help="원본 JSON 경로")
    parser.add_argument("output_json", help="출력 JSON 경로")
    parser.add_argument("--K", type=str, default=None)
    parser.add_argument("--L", type=str, default=None)
    parser.add_argument("--T", type=str, default=None)
    args = parser.parse_args()

    with open(args.input_json, "r") as f:
        config = json.load(f)

    if args.K is not None:
        config["K"] = args.K
    if args.L is not None:
        config["L"] = args.L
    if args.T is not None:
        config["T"] = args.T

    with open(args.output_json, "w") as f:
        json.dump(config, f, indent=4)


if __name__ == "__main__":
    main()
