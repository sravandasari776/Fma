#!/usr/bin/env bash
# Compile and run the U_FMA self-checking testbench (Icarus Verilog).
# Plain Verilog (IEEE 1364-2001/2005) sources -- no SystemVerilog constructs.
# Usage: ./run_sim.sh [--regen]   (--regen regenerates vectors.txt first)
set -e
cd "$(dirname "$0")"

if [ "$1" == "--regen" ]; then
  python3 gen_vectors.py
fi

RTL_DIR=../rtl
SIM=/tmp/fma_sim.vvp

iverilog -g2005 -I "$RTL_DIR" -o "$SIM" \
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

vvp "$SIM"
