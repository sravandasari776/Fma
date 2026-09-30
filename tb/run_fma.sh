#!/usr/bin/env bash
# Decimal in, decimal out: one FMA operation, typed as ordinary numbers.
#
#   tb/run_fma.sh <mode> <numbers...>
#
#   tb/run_fma.sh SP 1.5 2 3                              # 1.5 + 2*3            -> 7.5
#   tb/run_fma.sh HP 1 2 3   0.5 -4 0.25                  # 2 lanes: A B C per lane
#   tb/run_fma.sh E4M3 1 2 3  0 0.5 0.5  -1 1 1  2 2 2    # up to 4 lanes for 8-bit
#   tb/run_fma.sh SP+E4M3 1   2 3  -1 0.5  1.5 1  0.25 1  # mixed: A, then B C pairs
#                                                         #  = 1 + 2*3 - 1*0.5 + 1.5*1 + 0.25*1
# <mode>: one format = multiple precision (independent A + B*C per lane):
#           E4M3 E5M2 (4 lanes)  HP DLFloat16 BFloat16 (2 lanes)  TF32 SP (1 lane)
#         ADDEND+PRODUCTS = mixed precision (one A + up to 4 or 2 products):
#           HP/DLFloat16/BFloat16 + E4M3/E5M2,  SP/TF32 + E4M3/E5M2/HP/DLFloat16/BFloat16
# numbers: 1.5  -0.25  1e-3  0.1  inf  -inf  nan  -0
#
# What happens: the simulator reads each number into an IEEE double (the
# only non-RTL step); the RTL shell fma_fp64_top rounds each one into the
# format (fp64_to_fmt), runs U_FMA (fma_top), and converts the result back
# to a double (fmt_to_fp64), which is printed in decimal. No Python.
#
#   SIM=xsim tb/run_fma.sh ...       # Vivado xsim instead of Cadence Xcelium
#   RTL_DIR=/path/rtl tb/run_fma.sh  # use another copy of the RTL
set -u
cd "$(dirname "$0")"
TB_DIR=$(pwd)
RTL_DIR=$(cd "${RTL_DIR:-../rtl}" && pwd)

usage() { sed -n '2,24p' "$0"; exit 2; }
[ $# -lt 2 ] && usage

fmt_info() {  # name -> "canonical class ew"
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    e4m3) echo "E4M3 0 4" ;;          e5m2) echo "E5M2 0 5" ;;
    hp|fp16|half) echo "HP 1 5" ;;    dlfloat16|dlf16) echo "DLFloat16 1 6" ;;
    bfloat16|bf16) echo "BFloat16 1 8" ;;
    sp|fp32|single) echo "SP 2 8" ;;  tf32) echo "TF32 3 8" ;;
    *) echo "run_fma.sh: unknown format '$1' (E4M3 E5M2 HP DLFloat16 BFloat16 TF32 SP)" >&2; return 1 ;;
  esac
}
lanes_of() { case $1 in 0) echo 4 ;; 1) echo 2 ;; *) echo 1 ;; esac; }

# normalize/check one number: prints the text to hand to the simulator
norm_num() {
  local v=$1 l
  l=$(echo "$v" | tr '[:upper:]' '[:lower:]')
  case "$l" in
    inf|+inf|infinity|+infinity) echo "inf"; return ;;
    -inf|-infinity) echo "-inf"; return ;;
    nan|+nan|-nan) echo "nan"; return ;;
  esac
  if [[ "$v" =~ ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$ ]]; then
    if [[ "$v" =~ ^-[0.]*([eE].*)?$ ]]; then echo "-0"; else echo "$v"; fi
  else
    echo "run_fma.sh: '$v' is not a decimal number" >&2; return 1
  fi
}

MODE=$1; shift
NUMS=()
for v in "$@"; do n=$(norm_num "$v") || exit 2; NUMS+=("$n"); done
N=${#NUMS[@]}
declare -A VAL

if [[ "$MODE" == *+* ]]; then
  read -r FA PRA EWA <<<"$(fmt_info "${MODE%%+*}")" || exit 2
  read -r FP PRM EWM <<<"$(fmt_info "${MODE#*+}")" || exit 2
  [ -z "${FA:-}" ] || [ -z "${FP:-}" ] && exit 2
  if ! { [ "$PRA" = 1 ] && [ "$PRM" = 0 ]; } && ! { [ "$PRA" -ge 2 ] && [ "$PRM" -le 1 ]; }; then
    echo "run_fma.sh: mixed $FA + $FP is not a combination the paper supports"; exit 2
  fi
  MAXP=$(lanes_of "$PRM")
  if [ $((N % 2)) -eq 0 ] || [ "$N" -lt 3 ] || [ $(((N - 1) / 2)) -gt "$MAXP" ]; then
    echo "run_fma.sh: $FA+$FP needs A then 1..$MAXP pairs B C (you gave $N numbers)"; exit 2
  fi
  MIX=1; NL=$(((N - 1) / 2)); VAL[A0]=${NUMS[0]}
  for ((i = 0; i < NL; i++)); do VAL[B$i]=${NUMS[$((1 + 2 * i))]}; VAL[C$i]=${NUMS[$((2 + 2 * i))]}; done
else
  read -r FA PRA EWA <<<"$(fmt_info "$MODE")" || exit 2
  [ -z "${FA:-}" ] && exit 2
  FP=$FA; PRM=$PRA; EWM=$EWA
  MAXL=$(lanes_of "$PRA")
  if [ $((N % 3)) -ne 0 ] || [ $((N / 3)) -gt "$MAXL" ]; then
    echo "run_fma.sh: $FA takes A B C for 1..$MAXL lane(s) (you gave $N numbers)"; exit 2
  fi
  MIX=0; NL=$((N / 3))
  for ((i = 0; i < NL; i++)); do
    VAL[A$i]=${NUMS[$((3 * i))]}; VAL[B$i]=${NUMS[$((3 * i + 1))]}; VAL[C$i]=${NUMS[$((3 * i + 2))]}
  done
fi

ARGS=("MIX=$MIX" "PRA=$PRA" "PRM=$PRM" "EWA=$EWA" "EWM=$EWM" "NL=$NL" "FMTA=$FA" "FMTP=$FP")
for k in "${!VAL[@]}"; do ARGS+=("$k=${VAL[$k]}"); done

SIM=${SIM:-xrun}
if [ "$SIM" = "xrun" ] && ! command -v xrun >/dev/null 2>&1; then
  export PATH=/home/install/XCELIUM2209/tools.lnx86/bin:$PATH
  export LM_LICENSE_FILE=${LM_LICENSE_FILE:-5280@192.168.6.16}
  export CDS_LIC_FILE=${CDS_LIC_FILE:-$LM_LICENSE_FILE}
fi
RTL_FILES=$(ls "$RTL_DIR"/*.v | grep -v fma_funcs.v)
OUT=$TB_DIR/out/decimal
mkdir -p "$OUT" && cd "$OUT"

if [ "$SIM" = "xsim" ]; then
  XA=(); for a in "${ARGS[@]}"; do XA+=(-testplusarg "$a"); done
  { xvlog -i "$RTL_DIR" $RTL_FILES "$TB_DIR/tb_decimal.v" && xelab -debug off tb_decimal -s decimal_sim && \
    xsim decimal_sim -R "${XA[@]}"; } >decimal.log 2>&1
else
  PA=(); for a in "${ARGS[@]}"; do PA+=("+$a"); done
  xrun -64bit -q -nocopyright -timescale 1ns/1ps -access +r -incdir "$RTL_DIR" -top tb_decimal \
    $RTL_FILES "$TB_DIR/tb_decimal.v" "${PA[@]}" >decimal.log 2>&1
fi
if grep -q "^ERROR" decimal.log; then grep "^ERROR" decimal.log; exit 1; fi
if ! grep -q " RESULT:" decimal.log; then
  echo "Simulation failed -- see $OUT/decimal.log"; exit 1
fi
echo "=============================================================================="
sed -n '/U_FMA, decimal in/,/^ RESULT:/p' decimal.log
echo "=============================================================================="
echo "(simulator transcript: tb/out/decimal/decimal.log)"
