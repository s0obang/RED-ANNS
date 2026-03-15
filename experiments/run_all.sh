#!/bin/bash
# ============================================================
# RED-ANNS 실험 재현 통합 파이프라인
# ============================================================
# 전체 실험을 한 번에 실행하고 결과를 CSV + 그래프로 생성합니다.
#
# 사용법:
#   cd experiments
#   bash run_all.sh                        # 전체 실행
#   bash run_all.sh --fig10-only           # Figure 10만
#   bash run_all.sh --fig16a-only          # Figure 16(a)만
#   bash run_all.sh --parse-only           # 로그 파싱만
#   bash run_all.sh --plot-only            # 플로팅만 (기존 CSV)
#   bash run_all.sh --dry-run              # 더미 데이터로 파이프라인 테스트
# ============================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 인자 파싱
RUN_FIG10=true
RUN_FIG11=true
RUN_FIG14=true
RUN_FIG16A=true
RUN_EXPERIMENTS=true
RUN_PARSE=true
RUN_PLOT=true
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --fig10-only)  RUN_FIG11=false; RUN_FIG14=false; RUN_FIG16A=false ;;
        --fig11-only)  RUN_FIG10=false; RUN_FIG14=false; RUN_FIG16A=false ;;
        --fig14-only)  RUN_FIG10=false; RUN_FIG11=false; RUN_FIG16A=false ;;
        --fig16a-only) RUN_FIG10=false; RUN_FIG11=false; RUN_FIG14=false ;;
        --parse-only)  RUN_EXPERIMENTS=false ;;
        --plot-only)   RUN_EXPERIMENTS=false; RUN_PARSE=false ;;
        --dry-run)     DRY_RUN=true; RUN_EXPERIMENTS=false ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: bash run_all.sh [--fig10-only|--fig11-only|--fig14-only|--fig16a-only|--parse-only|--plot-only|--dry-run]"
            exit 1
            ;;
    esac
done

echo "============================================"
echo " RED-ANNS Experiment Reproduction Pipeline"
echo "============================================"
echo " Fig10:       $RUN_FIG10"
echo " Fig11:       $RUN_FIG11"
echo " Fig14:       $RUN_FIG14"
echo " Fig16(a):    $RUN_FIG16A"
echo " Experiments: $RUN_EXPERIMENTS"
echo " Parse:       $RUN_PARSE"
echo " Plot:        $RUN_PLOT"
echo " Dry Run:     $DRY_RUN"
echo ""

# ---- Step 0: Dry run (더미 데이터 생성) ----
if [[ "$DRY_RUN" == true ]]; then
    echo "=== Step 0: Generating dummy data ==="
    python3 generate_dummy_logs.py
    RUN_PARSE=true
    RUN_PLOT=true
    echo ""
fi

# ---- Step 1: 환경 확인 ----
echo "=== Step 1: Environment Check ==="
if [[ "$RUN_EXPERIMENTS" == true ]]; then
    source config.sh 2>/dev/null || { echo "ERROR: config.sh not found"; exit 1; }
    echo "  Servers:  $(get_num_servers)"
    echo "  Hostfile: $HOSTFILE"
    echo "  NIC:      $NIC_INTERFACE"
    echo "  Binary:   $BIN_DISTRIBUTED"

    if [[ ! -f "$HOSTFILE" ]]; then
        echo "ERROR: Hostfile not found: $HOSTFILE"
        exit 1
    fi
    if [[ ! -f "$BIN_DISTRIBUTED" ]]; then
        echo "ERROR: Binary not found: $BIN_DISTRIBUTED"
        echo "먼저 'bash build.sh'로 빌드하세요."
        exit 1
    fi
fi
echo ""

# ---- Step 2: 실험 실행 ----
if [[ "$RUN_EXPERIMENTS" == true ]]; then
    echo "=== Step 2: Running Experiments ==="
    [[ "$RUN_FIG10" == true ]] && { echo "--- Figure 10 ---"; bash run_fig10.sh 2>&1 | tee logs/fig10_pipeline.log; }
    [[ "$RUN_FIG11" == true ]] && { echo "--- Figure 11 ---"; bash run_fig11.sh 2>&1 | tee logs/fig11_pipeline.log; }
    [[ "$RUN_FIG14" == true ]] && { echo "--- Figure 14 ---"; bash run_fig14.sh 2>&1 | tee logs/fig14_pipeline.log; }
    [[ "$RUN_FIG16A" == true ]] && { echo "--- Figure 16(a) ---"; bash run_fig16a.sh 2>&1 | tee logs/fig16a_pipeline.log; }
    echo ""
else
    echo "=== Step 2: SKIPPED ==="
    echo ""
fi

# ---- Step 3: 로그 파싱 → CSV ----
if [[ "$RUN_PARSE" == true ]]; then
    echo "=== Step 3: Parsing Logs → CSV ==="
    [[ "$RUN_FIG10" == true ]] && python3 parse_logs.py --figure fig10
    [[ "$RUN_FIG11" == true ]] && python3 parse_logs.py --figure fig11
    [[ "$RUN_FIG14" == true ]] && python3 parse_logs.py --figure fig14
    [[ "$RUN_FIG16A" == true ]] && python3 parse_logs.py --figure fig16a
    # 통합 CSV
    python3 parse_logs.py -o results/all_results.csv
    echo ""
else
    echo "=== Step 3: SKIPPED ==="
    echo ""
fi

# ---- Step 4: 플로팅 ----
if [[ "$RUN_PLOT" == true ]]; then
    echo "=== Step 4: Plotting ==="
    FIGURES=""
    [[ "$RUN_FIG10" == true ]] && FIGURES="$FIGURES fig10"
    [[ "$RUN_FIG11" == true ]] && FIGURES="$FIGURES fig11"
    [[ "$RUN_FIG14" == true ]] && FIGURES="$FIGURES fig14"
    [[ "$RUN_FIG16A" == true ]] && FIGURES="$FIGURES fig16a"

    if [[ -n "$FIGURES" ]]; then
        python3 plot_all.py --figure $FIGURES --pdf
    fi
    echo ""
else
    echo "=== Step 4: SKIPPED ==="
    echo ""
fi

# ---- 완료 ----
echo "============================================"
echo " Pipeline Complete!"
echo "============================================"
echo ""
echo " Results:"
ls -la results/ 2>/dev/null || echo "  (no results yet)"
echo ""
echo " Logs:"
ls -la logs/ 2>/dev/null | tail -10 || echo "  (no logs yet)"
