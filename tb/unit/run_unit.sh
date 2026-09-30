#!/usr/bin/env bash
# Run the per-block unit testbenches (tb/unit/tb_*.v), one RTL block at a time.
#
# Usage:
#   ./run_unit.sh                     # run every unit testbench, print a summary table
#   ./run_unit.sh stage1_booth_multiplier stage3_csla   # run only these blocks
#   ./run_unit.sh -gui stage4_rounding                  # run one block and open SimVision
#   ./run_unit.sh -list               # list available block testbenches
#   SIM=iverilog ./run_unit.sh        # use Icarus Verilog instead of Cadence Xcelium
#
# Output (all under tb/unit/out/):
#   logs/<block>.log    full, readable transcript of that block's test
#   waves/tb_<block>.vcd waveform of that block's test (open in SimVision/GTKWave)
set -u
cd "$(dirname "$0")"
UNIT_DIR=$(pwd)
RTL_DIR=$(cd ../../rtl && pwd)
OUT_DIR=$UNIT_DIR/out
mkdir -p "$OUT_DIR/logs" "$OUT_DIR/waves"

# --- simulator setup ------------------------------------------------------
SIM=${SIM:-xrun}
if [ "$SIM" = "xrun" ] && ! command -v xrun >/dev/null 2>&1; then
  # lab install location (see /home/install/cshrc)
  export PATH=/home/install/XCELIUM2209/tools.lnx86/bin:$PATH
  export LM_LICENSE_FILE=${LM_LICENSE_FILE:-5280@192.168.6.16}
  export CDS_LIC_FILE=${CDS_LIC_FILE:-$LM_LICENSE_FILE}
fi

# every RTL file except fma_funcs.v (that one is `include-d inside modules)
RTL_FILES=$(ls "$RTL_DIR"/*.v | grep -v fma_funcs.v)

GUI=0
BLOCKS=()
for arg in "$@"; do
  case "$arg" in
    -gui)  GUI=1 ;;
    -list) ls "$UNIT_DIR"/tb_*.v | sed 's#.*/tb_##; s#\.v$##'; exit 0 ;;
    *)     BLOCKS+=("${arg#tb_}") ;;
  esac
done
if [ ${#BLOCKS[@]} -eq 0 ]; then
  for f in "$UNIT_DIR"/tb_*.v; do b=$(basename "$f" .v); BLOCKS+=("${b#tb_}"); done
fi

run_one() {
  local blk=$1
  local tb=tb_$blk
  local log=$OUT_DIR/logs/$blk.log
  if [ ! -f "$UNIT_DIR/$tb.v" ]; then
    echo "no testbench $tb.v" >"$log"; return 1
  fi
  local work=$OUT_DIR/work_$blk
  mkdir -p "$work"
  (
    cd "$work"
    if [ "$SIM" = "iverilog" ]; then
      iverilog -g2005 -DDUMP_WAVES -I "$RTL_DIR" -I "$UNIT_DIR" -s "$tb" -o sim.vvp \
        $RTL_FILES "$UNIT_DIR/$tb.v" && vvp -n sim.vvp
    else
      local gui_opts="-access +r"
      [ $GUI -eq 1 ] && gui_opts="-gui -access +rwc"
      xrun -64bit -q -nocopyright -timescale 1ns/1ps +define+DUMP_WAVES \
        -incdir "$RTL_DIR" -incdir "$UNIT_DIR" -top "$tb" $gui_opts \
        $RTL_FILES "$UNIT_DIR/$tb.v"
    fi
  ) >"$log" 2>&1
  [ -f "$work/$tb.vcd" ] && mv -f "$work/$tb.vcd" "$OUT_DIR/waves/"
  rm -rf "$work"
}

printf "\n%-34s %8s %8s %8s   %s\n" "RTL BLOCK" "CHECKS" "PASS" "FAIL" "RESULT"
printf "%s\n" "--------------------------------------------------------------------------"
total_blk=0; bad_blk=0
for blk in "${BLOCKS[@]}"; do
  run_one "$blk"
  log=$OUT_DIR/logs/$blk.log
  line=$(grep " SUMMARY " "$log" | tail -1)
  total_blk=$((total_blk + 1))
  if [ -z "$line" ]; then
    printf "%-34s %8s %8s %8s   %s\n" "$blk" "-" "-" "-" "DID NOT RUN (see out/logs/$blk.log)"
    bad_blk=$((bad_blk + 1)); continue
  fi
  checks=$(echo "$line" | sed -E 's/.*: ([0-9]+) checks.*/\1/')
  pass=$(echo "$line"   | sed -E 's/.*\| ([0-9]+) PASS.*/\1/')
  fail=$(echo "$line"   | sed -E 's/.*\| ([0-9]+) FAIL.*/\1/')
  res=$(echo "$line"    | sed -E 's/.*\| (BLOCK [A-Z]+).*/\1/')
  [ "$fail" != "0" ] && bad_blk=$((bad_blk + 1))
  printf "%-34s %8s %8s %8s   %s\n" "$blk" "$checks" "$pass" "$fail" "$res"
done
printf "%s\n" "--------------------------------------------------------------------------"
echo "$((total_blk - bad_blk)) / $total_blk blocks passed."
echo "Detailed per-block reports : $OUT_DIR/logs/<block>.log"
echo "Waveforms                  : $OUT_DIR/waves/tb_<block>.vcd"
