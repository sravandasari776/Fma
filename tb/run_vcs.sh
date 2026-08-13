#!/usr/bin/env bash
# Compile + run the U_FMA testbench under Synopsys VCS and dump a waveform
# scoped to the system's top-level inputs/outputs only (fma_io.vcd).
#
# This is the Synopsys counterpart of run_sim.sh (which uses Icarus Verilog).
# It compiles the same plain-Verilog (IEEE 1364-2001/2005) sources, enables
# the +define+DUMP_WAVES dump block in tb_fma_top.v, runs the self-check, and
# leaves fma_io.vcd next to this script for viewing in DVE / Verdi.
#
# Requirements on the target machine:
#   - Synopsys VCS on PATH (`vcs`, and `dve` or `verdi` to view the waveform)
#   - a valid Synopsys licence (SNPSLMD_LICENSE_FILE / LM_LICENSE_FILE set)
#
# Usage:
#   ./run_vcs.sh            # compile + simulate, produce fma_io.vcd
#   ./run_vcs.sh --regen    # regenerate vectors.txt first, then run
set -e
cd "$(dirname "$0")"

if [ "$1" == "--regen" ]; then
  python3 gen_vectors.py
fi

RTL_DIR=../rtl

# fma_defs.vh and fma_funcs.v are `include-d inside the modules (not stand-alone
# compilation units), so they are NOT listed here -- +incdir lets VCS find them.
# The remaining files match run_sim.sh exactly.
vcs -full64 -timescale=1ns/1ps \
    +define+DUMP_WAVES \
    +incdir+"$RTL_DIR" \
    -o simv_fma \
    "$RTL_DIR"/csa32.v \
    "$RTL_DIR"/align_shifter.v "$RTL_DIR"/incrementer.v \
    "$RTL_DIR"/stage1_bias_generator.v "$RTL_DIR"/stage1_unified_lzc.v \
    "$RTL_DIR"/stage1_unified_extractor.v "$RTL_DIR"/stage1_booth_multiplier.v \
    "$RTL_DIR"/stage1_exp_align_controller.v "$RTL_DIR"/stage1_comparator.v \
    "$RTL_DIR"/stage2_align_amount_finalizer.v "$RTL_DIR"/stage2_addend_alignment.v \
    "$RTL_DIR"/stage2_product_align_ctrl.v "$RTL_DIR"/stage2_mult_aligner.v \
    "$RTL_DIR"/stage2_relative_normalizer.v "$RTL_DIR"/stage2_invert_swap.v "$RTL_DIR"/stage2_csa4to2.v \
    "$RTL_DIR"/stage3_csa3to2.v "$RTL_DIR"/stage3_sticky_logic.v "$RTL_DIR"/stage3_csla.v \
    "$RTL_DIR"/stage3_lzau.v "$RTL_DIR"/stage3_complement.v \
    "$RTL_DIR"/stage4_normalization.v "$RTL_DIR"/stage4_rounding.v "$RTL_DIR"/stage4_exp_adjuster.v \
    "$RTL_DIR"/stage4_sign_detection.v "$RTL_DIR"/stage4_output_finalize.v \
    "$RTL_DIR"/fma_lane_pipe.v "$RTL_DIR"/fma_top.v \
    tb_fma_top.v

./simv_fma

echo "---------------------------------------------"
echo "Waveform written to: $(pwd)/fma_io.vcd"
echo "View it with:  dve -vpd fma_io.vcd   (or)   verdi -vcd fma_io.vcd &"
