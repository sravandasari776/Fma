#!/usr/bin/env bash
# Compile + run the U_FMA regression under Synopsys VCS and dump a waveform
# of the system's top-level inputs/outputs plus the decoded view_* signals
# (out/fma_waves.vcd). This is the Synopsys counterpart of run_sim.sh (which
# defaults to Cadence Xcelium); it runs the same self-checking testbench.
#
# Requirements on the target machine:
#   - Synopsys VCS on PATH (`vcs`, and `dve` or `verdi` to view the waveform)
#   - a valid Synopsys licence (SNPSLMD_LICENSE_FILE / LM_LICENSE_FILE set)
#
# Usage:
#   ./run_vcs.sh            # compile + simulate, produce out/fma_waves.vcd
#   ./run_vcs.sh --regen    # regenerate vectors.txt first, then run
set -e
cd "$(dirname "$0")"
TB_DIR=$(pwd)
RTL_DIR=$(cd ../rtl && pwd)

if [ "${1:-}" == "--regen" ]; then
  python3 gen_vectors.py
fi

mkdir -p out && cd out
cp "$TB_DIR/vectors.txt" .

# fma_funcs.v is `include-d inside the modules (not a stand-alone
# compilation unit), so it is excluded here -- +incdir lets VCS find it.
vcs -full64 -timescale=1ns/1ps \
    +define+DUMP_WAVES \
    +incdir+"$RTL_DIR" \
    -o simv_fma \
    $(ls "$RTL_DIR"/*.v | grep -v fma_funcs.v) \
    "$TB_DIR/tb_fma_top.v"

./simv_fma
python3 "$TB_DIR/report.py"

echo "---------------------------------------------"
echo "Waveform written to: $(pwd)/fma_waves.vcd"
echo "View it with:  dve -vpd fma_waves.vcd   (or)   verdi -vcd fma_waves.vcd &"
