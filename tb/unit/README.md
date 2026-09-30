# Per-block unit testbenches

One self-checking testbench per RTL block, so each block can be verified
(and shown) on its own instead of only through the full `fma_top` run.

```
cd tb/unit
./run_unit.sh                          # run all blocks, print a PASS/FAIL table
./run_unit.sh stage4_rounding          # run one block
./run_unit.sh -gui stage4_rounding     # run one block and open SimVision
./run_unit.sh -list                    # list the blocks
SIM=iverilog ./run_unit.sh             # use Icarus Verilog instead of Xcelium
```

Outputs:

- `out/logs/<block>.log`: the readable report for that block
- `out/waves/tb_<block>.vcd`: its waveform (SimVision: `simvision out/waves/tb_<block>.vcd`)

Every report has the same layout:

1. **Banner**: the block name, its MPFMA-DS-001 section, and what it should do.
2. **Directed tests**: hand-picked cases (1.0, -2.5, ties, overflow, NaN, ...),
   one row each: inputs | got | expected | PASS/FAIL | what the case means.
3. **Random tests**: hundreds or thousands of vectors checked against a
   small reference model written inside the testbench. Only failures are printed.
4. **SUMMARY** line: checks / PASS / FAIL / BLOCK PASSED or FAILED.

## Blocks, in pipeline order

| Stage | Block | Testbench | What is checked |
|---|---|---|---|
| 1 | stage1_unified_extractor (6.1) | tb_stage1_unified_extractor.v | sign/exp/significand/flags for all 7 formats, subnormals renormalized |
| 1 | stage1_bias_generator (6.2) | tb_stage1_bias_generator.v | exhaustive: bias for ew=4..8, normal/subnormal |
| 1 | stage1_booth_multiplier (6.3) | tb_stage1_booth_multiplier.v | sum+carry == b*c |
| 1 | stage1_unified_lzc (6.4) | tb_stage1_unified_lzc.v | leading-zero count with the leading 1 at every position |
| 1 | stage1_exp_align_controller (6.5) | tb_stage1_exp_align_controller.v | product exp, exact 48-bit product sig, Inf*0=NaN, etc. |
| 1 | stage1_comparator (6.6) | tb_stage1_comparator.v | largest exponent, invalid/zero lanes ignored, ties |
| 2 | stage2_align_amount_finalizer (7.1) | tb_stage2_align_amount_finalizer.v | shift = ref-a, clamped 0..127 |
| 2 | stage2_addend_alignment (7.2) | tb_stage2_addend_alignment.v | 24-bit addend into the 76-bit frame, right shift, lost bits jammed into bit 0 + sticky |
| 2 | stage2_invert_swap (7.3) | tb_stage2_invert_swap.v | inversion vs anchor sign, neg_count = number of inverted terms |
| 2 | stage2_relative_normalizer (7.4) | tb_stage2_relative_normalizer.v | pass-through (4 x 48-bit products) |
| 2 | stage2_product_align_ctrl (7.5) | tb_stage2_product_align_ctrl.v | shift = ref-prod, clamped 0..127 |
| 2 | stage2_mult_aligner (7.6) | tb_stage2_mult_aligner.v | exact 48-bit product into the frame, right shift, jam bit + sticky |
| 2 | stage2_csa4to2 (7.7) | tb_stage2_csa4to2.v | sum+carry == a+p0+p1+p2+p3+neg_count, worst-case 5-term overflow |
| 3 | stage3_csa3to2 (8.1) | tb_stage3_csa3to2.v | sum+carry preserved |
| 3 | stage3_sticky_logic (8.2) | tb_stage3_sticky_logic.v | exhaustive OR |
| 3 | stage3_csla (8.3) | tb_stage3_csla.v | sum+carry, carry across the bit-20 split |
| 3 | stage3_lzau (8.4) | tb_stage3_lzau.v | leading-one position - 71 |
| 3 | incrementer (8.5) | tb_incrementer.v | a+1 with wrap |
| 3 | stage3_complement (8.6) | tb_stage3_complement.v | two's complement to sign-magnitude |
| 4 | stage4_normalization (9.1) | tb_stage4_normalization.v | leading 1 back to bit 71, sticky, left shift limited at emin (subnormal results) |
| 4 | stage4_rounding (9.2) | tb_stage4_rounding.v | round-to-nearest-even for m=2,3,7,9,10,23, ties, overflow, subnormal inputs |
| 4 | stage4_exp_adjuster (9.3) | tb_stage4_exp_adjuster.v | ref + adjust + rounding carry |
| 4 | stage4_sign_detection (9.4) | tb_stage4_sign_detection.v | exhaustive, incl. IEEE NaN / Inf / -0 sign rules |
| 4 | stage4_output_finalize (9.5) | tb_stage4_output_finalize.v | known encodings of every format, Inf/NaN/subnormal/-0 |
| - | csa32, align_shifter, incrementer | tb_csa32.v, tb_align_shifter.v, tb_incrementer.v | shared helper blocks (76-bit frame) |
| shell | fp64_to_fmt | tb_fp64_to_fmt.v | decimal I/O shell input: double -> format, round-to-nearest-even, overflow/subnormal/NaN; 24 hand-known cases + 7,000 random vs a real-arithmetic model |
| shell | fmt_to_fp64 | tb_fmt_to_fp64.v | decimal I/O shell output: format -> double, exact; every encoding of 6 formats + SP random; lossless round trip through both converters |
| 2-4 | fma_lane_pipe | tb_fma_lane_pipe.v | full accumulate/round path, specials, subnormal result, 2-cycle latency, pipelined |
| all | fma_top | tb_fma_top_directed.v | hand-checkable cases for every format and mixed mode + one case per bug fixed (BUG1-BUG8), 3-cycle latency |

The full system regression against `golden_model.py` (~10.7k vectors,
all passing) is `tb/tb_fma_top.v`, run by `tb/run_sim.sh`; `./run_all.sh`
at the repository root runs these unit tests, then the regression, then
the report (`docs/VERIFICATION_REPORT.md`).
