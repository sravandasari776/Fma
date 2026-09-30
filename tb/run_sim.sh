#!/usr/bin/env bash
# Full-system regression for U_FMA: every vector in tb/vectors.txt goes
# through fma_top (one per clock, fully pipelined) and dout_o is checked
# against the golden model's expected result. Ends with the human-readable
# report (tb/report.py).
#
# Usage:
#   ./run_sim.sh               # run the ~10.7k-vector regression + print the report
#   ./run_sim.sh --regen       # regenerate vectors.txt from golden_model.py first
#   ./run_sim.sh --waves       # also dump waveforms (out/fma_waves.vcd, + .shm with Xcelium)
#   ./run_sim.sh --demo --gui  # 40 hand-picked vectors, then open SimVision on the waveform
#   ./run_sim.sh --no-report   # skip report.py
#   ./run_sim.sh --vectors=F   # simulate another vector file (e.g. from run_stress.sh)
#   ./run_sim.sh --shell       # same vectors through the decimal I/O shell (fma_fp64_top):
#                              #   operands in as doubles, results out as doubles
#   SIM=iverilog ./run_sim.sh  # Icarus Verilog instead of Cadence Xcelium (default)
#   SIM=xsim ./run_sim.sh      # Vivado xsim (xvlog/xelab/xsim on PATH)
#
# Outputs (tb/out/): sim.log, sim_results.txt, fma_waves.vcd / fma_waves.shm
# Plain Verilog (IEEE 1364-2005) sources -- no SystemVerilog constructs.
set -u
cd "$(dirname "$0")"
TB_DIR=$(pwd)
RTL_DIR=$(cd ../rtl && pwd)
OUT_DIR=$TB_DIR/out

REGEN=0; WAVES=0; GUI=0; REPORT=1; VEC=$TB_DIR/vectors.txt
TOP=tb_fma_top; RES=sim_results.txt; LOG=sim.log
for arg in "$@"; do
  case "$arg" in
    --regen)     REGEN=1 ;;
    --waves)     WAVES=1 ;;
    --gui)       WAVES=1; GUI=1 ;;
    --demo)      VEC=$TB_DIR/demo_vectors.txt ;;
    --vectors=*) VEC=$(cd "$(dirname "${arg#--vectors=}")" && pwd)/$(basename "${arg#--vectors=}") ;;
    --no-report) REPORT=0 ;;
    --shell)     TOP=tb_fma_fp64_top; RES=sim_results_fp64.txt; LOG=sim_fp64.log ;;
    *) echo "unknown option: $arg (see the header of $0)"; exit 2 ;;
  esac
done

[ "$TOP" = "tb_fma_fp64_top" ] && { REPORT=0; WAVES=0; GUI=0; }   # report.py covers the core run

if [ $REGEN -eq 1 ]; then
  python3 gen_vectors.py || exit 1
fi

# --- simulator setup (same lab defaults as tb/unit/run_unit.sh) ---
SIM=${SIM:-xrun}
if [ "$SIM" = "xrun" ] && ! command -v xrun >/dev/null 2>&1; then
  export PATH=/home/install/XCELIUM2209/tools.lnx86/bin:$PATH
  export LM_LICENSE_FILE=${LM_LICENSE_FILE:-5280@192.168.6.16}
  export CDS_LIC_FILE=${CDS_LIC_FILE:-$LM_LICENSE_FILE}
fi

# every RTL file except fma_funcs.v (that one is `include-d inside modules)
RTL_FILES=$(ls "$RTL_DIR"/*.v | grep -v fma_funcs.v)

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"
rm -rf "$RES" "$LOG"
[ $WAVES -eq 1 ] && rm -rf fma_waves.vcd fma_waves.shm
cp "$VEC" vectors.txt

DEFS=""
[ $WAVES -eq 1 ] && DEFS="DUMP_WAVES"

echo "Simulating $(head -1 vectors.txt) vectors from ${VEC#$(dirname "$TB_DIR")/} with $SIM ($TOP) ..."
if [ "$SIM" = "xsim" ]; then
  D=""; [ -n "$DEFS" ] && D="-d DUMP_WAVES"
  { xvlog $D -i "$RTL_DIR" $RTL_FILES "$TB_DIR/$TOP.v" && \
    xelab -debug off $TOP -s fma_sim && xsim fma_sim -R; } >"$LOG" 2>&1
elif [ "$SIM" = "iverilog" ]; then
  D=""; [ -n "$DEFS" ] && D="-D$DEFS"
  iverilog -g2005 $D -I "$RTL_DIR" -s $TOP -o fma_sim.vvp $RTL_FILES "$TB_DIR/$TOP.v" \
    >"$LOG" 2>&1 && vvp -n fma_sim.vvp >>"$LOG" 2>&1
else
  D=""; [ -n "$DEFS" ] && D="+define+DUMP_WAVES +define+USE_SHM"
  xrun -64bit -q -nocopyright -timescale 1ns/1ps -access +r $D \
    -incdir "$RTL_DIR" -top $TOP $RTL_FILES "$TB_DIR/$TOP.v" >"$LOG" 2>&1
fi

# show only the meaningful lines of the simulator transcript
grep -E "^(Reading|FAIL|TOTAL|RESULT|ERROR|TIMEOUT)" "$LOG"
if ! grep -q "^TOTAL" "$LOG"; then
  echo "Simulation did not complete -- see $OUT_DIR/$LOG"
  exit 1
fi
echo "Full transcript: tb/out/$LOG   Per-vector results: tb/out/$RES"
[ $WAVES -eq 1 ] && echo "Waveforms: tb/out/fma_waves.vcd$( [ "$SIM" = "xrun" ] && echo ' and tb/out/fma_waves.shm')"

if [ $REPORT -eq 1 ]; then
  python3 "$TB_DIR/report.py" --vectors "$VEC"
fi

if [ $GUI -eq 1 ]; then
  echo "Opening SimVision (signals pre-loaded by tb/fma_waves.svcf) ..."
  simvision -input "$TB_DIR/fma_waves.svcf" &
fi
grep -q "^RESULT: ALL PASS" "$LOG"
