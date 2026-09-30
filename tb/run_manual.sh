#!/usr/bin/env bash
# Run ONE operation through the RTL with a pure-Verilog testbench (tb_manual.v).
# No Python and no expected answer anywhere: the inputs are hex encodings
# given on the command line, and the only thing that can produce the
# printed result is the RTL. The result appears 3 clock edges after the
# inputs; values from inside each pipeline stage are printed along the way.
#
# Usage:  tb/run_manual.sh <format> <a_i hex> <b_i hex> <c_i hex>
#   tb/run_manual.sh SP      3FC00000 40000000 40400000   # 1.5 + 2*3            -> 40f00000 (7.5)
#   tb/run_manual.sh HP      38003C00 40003C00 42003C00   # 2 lanes: 1+1*1, 0.5+2*3 -> 46804000
#   tb/run_manual.sh E4M3    00380038 3CB84038 40384038   # 4 lanes packed in bytes
#   tb/run_manual.sh SP+E4M3 3F800000 38383838 38383838   # mixed: 1 + 4 x (1*1)  -> 40a00000 (5.0)
# Formats: E4M3 E5M2 HP DLFloat16 BFloat16 TF32 SP. "X+Y" = mixed: addend X, products Y.
# tb/try_fma.py prints the a_i/b_i/c_i hex for any decimal inputs ("FMA ports" line).
#
#   RTL_DIR=/path/to/rtl_copy tb/run_manual.sh ...   # run against a different (e.g. deliberately
#                                                    # modified) copy of the RTL
#   SIM=xsim tb/run_manual.sh ...                    # Vivado xsim instead of Cadence Xcelium
set -u
cd "$(dirname "$0")"
TB_DIR=$(pwd)
RTL_DIR=$(cd "${RTL_DIR:-../rtl}" && pwd)

if [ $# -ne 4 ]; then
  sed -n '2,20p' "$0"; exit 2
fi

cls_ew() {  # format name -> "class ew"
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    e4m3) echo "0 4" ;;  e5m2) echo "0 5" ;;
    hp|fp16|half) echo "1 5" ;;  dlfloat16|dlf16) echo "1 6" ;;  bfloat16|bf16) echo "1 8" ;;
    sp|fp32|single) echo "2 8" ;;  tf32) echo "3 8" ;;
    *) echo "unknown format '$1'" >&2; exit 2 ;;
  esac
}

if [[ "$1" == *+* ]]; then
  MIX=1; read -r PRA EWA <<<"$(cls_ew "${1%%+*}")"; read -r PRM EWM <<<"$(cls_ew "${1#*+}")"
else
  MIX=0; read -r PRA EWA <<<"$(cls_ew "$1")"; PRM=$PRA; EWM=$EWA
fi
A=${2#0x}; B=${3#0x}; C=${4#0x}

SIM=${SIM:-xrun}
if [ "$SIM" = "xrun" ] && ! command -v xrun >/dev/null 2>&1; then
  export PATH=/home/install/XCELIUM2209/tools.lnx86/bin:$PATH
  export LM_LICENSE_FILE=${LM_LICENSE_FILE:-5280@192.168.6.16}
  export CDS_LIC_FILE=${CDS_LIC_FILE:-$LM_LICENSE_FILE}
fi
RTL_FILES=$(ls "$RTL_DIR"/*.v | grep -v fma_funcs.v)
OUT=$TB_DIR/out/manual
mkdir -p "$OUT" && cd "$OUT"

echo "Compiling the RTL from $RTL_DIR with $SIM:"
for f in $RTL_FILES; do printf "  %s\n" "$(basename "$f")"; done | paste - - - | column -t
ARGS="+MIX=$MIX +PRA=$PRA +PRM=$PRM +EWA=$EWA +EWM=$EWM +A=$A +B=$B +C=$C"
if [ "$SIM" = "xsim" ]; then
  { xvlog -i "$RTL_DIR" $RTL_FILES "$TB_DIR/tb_manual.v" && xelab -debug off tb_manual -s manual_sim && \
    xsim manual_sim -R -testplusarg "MIX=$MIX" -testplusarg "PRA=$PRA" -testplusarg "PRM=$PRM" \
      -testplusarg "EWA=$EWA" -testplusarg "EWM=$EWM" -testplusarg "A=$A" -testplusarg "B=$B" -testplusarg "C=$C"; } \
    >manual.log 2>&1
else
  xrun -64bit -nocopyright -timescale 1ns/1ps -access +r -incdir "$RTL_DIR" -top tb_manual \
    $RTL_FILES "$TB_DIR/tb_manual.v" $ARGS >manual.log 2>&1
fi
if ! grep -q " RESULT:" manual.log; then
  echo "Simulation failed -- see $OUT/manual.log"; exit 1
fi
echo "====================================================================="
sed -n '/ U_FMA manual run/,/ RESULT:/p' manual.log
echo "====================================================================="
echo "(full simulator transcript: tb/out/manual/manual.log)"
