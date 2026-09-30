# U_FMA: Configurable Mixed/Multiple-Precision Floating-Point FMA

Verilog RTL and verification of the configurable, fully pipelined fused multiply-add unit from:

- Niknia et al., *"A Configurable Floating-Point Fused Multiply-Add Design With Mixed Precision for AI Accelerators,"* IEEE Trans. Circuits Syst. Artif. Intell., vol. 2, no. 3, pp. 248–261, Sep. 2025.
- `docs/FMA_Design_Document.docx` (MPFMA-DS-001): the block-level spec derived from the paper's Fig. 3, used as the RTL contract.

## In five lines

- It computes **A + B × C with a single rounding**, in 7 formats: E4M3, E5M2, HP, DLFloat16, BFloat16, TF32 and SP.
- **Multiple-precision mode** runs 4 × 8-bit, 2 × 16-bit or 1 × 32-bit independent FMAs per clock.
- **Mixed-precision mode** computes `A + B0·C0 + … + B3·C3`: several low-precision products added into one wider number, as in AI dot products.
- It is a 4-stage pipeline with 3 registers. It takes one operation per clock, and each result appears 3 clock edges later.
- It is plain Verilog-2005, 29 blocks, one file per block of the paper's Fig. 3.
- An optional hardware **decimal I/O shell** (`fma_fp64_top`) lets you type ordinary decimal numbers and read the answer in decimal (`tb/run_fma.sh`).

## Status

| | Result |
|---|---|
| Unit tests: 30 testbenches, one per RTL block | **30 / 30 pass** (795,281 checks) |
| System regression: whole FMA vs an independent exact-arithmetic golden model | **10,743 / 10,743 vectors pass** (17,139 FMA results, bit-exact) |
| Same regression through the decimal I/O shell (operands and results as doubles) | **10,743 / 10,743 vectors pass** |
| Spec sign-off checklist F01–F13 (MPFMA-DS-001 §13.1) | **13 / 13 PASS** |
| Second simulator (Vivado xsim) | same 10,743 / 10,743 |
| Stress: 5 extra random seeds, 53,715 vectors | 53,712 match; 3 hit the documented mixed-mode limitation (`docs/DEVIATIONS.md` §4) |

Verification found and fixed **8 design bugs** that the original 909/925 regression and the unit tests had missed. For example, `1.75 + 4 × 1.75` in mixed mode used to return −7.25 instead of 8.75. See `docs/VERIFICATION_REPORT.md` and `docs/DEVIATIONS.md`.

## Run it

**Your own numbers, in decimal (all RTL after the number is read):**
```
tb/run_fma.sh SP 1.5 2 3                              # 1.5 + 2 x 3            -> 7.5
tb/run_fma.sh HP 1 2 3   0.5 -4 0.25                  # 2 lanes of A B C       -> 7, -0.5
tb/run_fma.sh HP+E4M3 1  2 3  -1 0.5  1.5 1  0.25 1   # mixed: A, then B C pairs -> 8.25
```
The mode is one format (multiple precision: `E4M3 E5M2 HP DLFloat16 BFloat16 TF32 SP`) or `ADDEND+PRODUCTS` (mixed precision). The numbers can be `1.5`, `-0.25`, `1e-3`, `0.1`, `inf`, `nan` or `-0`.
- **What the RTL does:** each number becomes an IEEE double, and the RTL shell (`fma_fp64_top`) rounds it into the format (`fp64_to_fmt`), runs the FMA (`fma_top`), and turns the result back into a double (`fmt_to_fp64`).
- **What gets printed:** the result in decimal, plus every step in between (see `docs/DESIGN_EXPLAINED.md` §8).

**Verification:**
```
./run_all.sh                    # unit tests + both regressions + report          (~3 min)
tb/run_sim.sh                   # full regression + report only                    (~10 s)
tb/run_sim.sh --shell           # the same regression through the decimal I/O shell
tb/run_sim.sh --demo --gui      # 40 hand-picked operations, open SimVision on the waveform
tb/unit/run_unit.sh <block>     # one block's unit test (tb/unit/run_unit.sh -list)
tb/run_stress.sh 1 2 3          # extra random seeds
python3 tb/try_fma.py SP 1.5 2 3               # YOUR numbers through the RTL + hand-check worksheet
python3 tb/try_fma.py SP+E4M3 1  2 3  -1 0.5   # mixed: A + B0*C0 + B1*C1 (+ up to 4 pairs)
```

`tb/try_fma.py` takes plain decimal numbers (also `inf`, `nan`, `-0`, or a hex encoding) and runs them through `fma_top`. For each case it prints a worksheet that can be checked by hand:
- every operand's sign/exponent/mantissa bits (flagging inputs the format cannot hold exactly, such as 0.1);
- the exact sum;
- the round-to-nearest-even decision (kept bits | guard | sticky);
- the packed result next to the RTL's actual `dout_o`.

Run `python3 tb/try_fma.py --help` for the syntax, including `--file cases.txt` (many cases in one run) and `--gui` (see them in SimVision).

**No Python at all:** `tb/run_manual.sh HP+E4M3 3C00 283CB840 38383044` feeds hex inputs to a pure-Verilog testbench (`tb/tb_manual.v`) that has no expected answer. It prints `dout_o` after each clock edge (the result appears at edge 3) and values read from inside every pipeline stage. `RTL_DIR=<modified copy> tb/run_manual.sh …` runs the same inputs on a deliberately changed RTL, to show that the answer comes from the Verilog.

Cadence Xcelium is the default simulator. Use `SIM=xsim` (Vivado) or `SIM=iverilog` (Icarus) to switch; `tb/run_vcs.sh` runs the regression on Synopsys VCS.

## How to read the results

- **Terminal / `docs/VERIFICATION_REPORT.md`.** This is regenerated on every run. It contains:
  - pass/fail by mode and format, and by kind of test;
  - the spec's F01–F13 checklist;
  - the bug list;
  - **decoded worked examples** in plain numbers:
    ```
    [MIX_HP_E4M3] Mixed HP + 4 x E4M3
       -0.734375 + (28 x 0.4375) + (-1.875 x -1.75) + (-1.5 x 0.4375) + (-18 x 0.28125)
          exact = 9.078125  -> correctly rounded 0x488a = 9.078125  |  RTL: 0x488a = 9.078125  PASS
    ```
- **`tb/unit/out/logs/<block>.log`.** Per-block reports: what the block should do, hand-picked cases with their meaning, a random-test count, and a SUMMARY line.
- **Waveforms** (`tb/out/fma_waves.shm` / `.vcd`, created with `--waves` or `--gui`). Besides the raw ports, the testbench adds `view_*` signals that show operands and results as **decimal numbers**, the vector's label, and a `view_mismatch` flag.

## Documentation

| File | What's in it |
|---|---|
| `docs/DESIGN_EXPLAINED.md` | **Start here.** Floating point in two minutes, the two modes, the ports and packing, every pipeline block in one line, one operation traced through all 4 stages with real simulation values, how the verification works. |
| `docs/VERIFICATION_REPORT.md` | Generated results: tables, the spec checklist, decoded examples, per-block unit results. |
| `docs/DEVIATIONS.md` | Bugs found and fixed (root cause + fix), differences from the paper, known limitations, RTL style notes. |
| `tb/unit/README.md` | The per-block unit testbenches. |
| `docs/FMA_reference_paper.pdf`, `docs/FMA_Design_Document.docx` | Source paper and spec. |

## Repository layout

```
rtl/                 29 FMA blocks + 3 I/O-shell files (plain Verilog); fma_top.v = U_FMA top, fma_lane_pipe.v = stages 2-4
  fma_defs.vh          shared constants (widths, accumulator layout, format-class codes)
  fma_funcs.v          shared helper functions (`include-d inside modules)
  fma_fp64_top.v       decimal I/O shell: fp64_to_fmt.v (double -> format) + fma_top + fmt_to_fp64.v
tb/
  golden_model.py      independent reference: exact fractions, one rounding, IEEE special values
  gen_vectors.py       builds vectors.txt (~10.7k) + demo_vectors.txt (40) from the golden model
  tb_fma_top.v         self-checking system testbench (back-to-back, decoded view_* signals)
  tb_fma_fp64_top.v    the same regression through the decimal I/O shell
  run_fma.sh + tb_decimal.v   decimal in, decimal out: one operation, your numbers
  try_fma.py           your numbers + a hand-check worksheet (Python)
  run_manual.sh + tb_manual.v hex in, pure Verilog, no expected answer
  report.py            human-readable report -> terminal + docs/VERIFICATION_REPORT.md
  run_sim.sh           system regression (Xcelium / xsim / Icarus)
  run_stress.sh        extra random seeds
  fma_waves.svcf       SimVision signal list for the waveform
  unit/                one self-checking testbench per RTL block + run_unit.sh
docs/                  explanations, generated report, deviations, source paper + spec
run_all.sh             everything in one command
```

## Interface and packing convention

MPFMA-DS-001 leaves the `pra_i`/`prm_i` encoding and the bus packing to the RTL owner. This implementation defines:

- `pra_i` / `prm_i` (2 bits) select the **format class** of A / of B and C: `00` = 8-bit, `01` = 16-bit, `10` = 32-bit (SP), `11` = 19-bit (TF32).
- `ewa_i` / `ewm_i` (4 bits) select the **exponent width** (4–8). Together with the class, this picks the exact format. The bias is always `2^(ew-1) - 1`.

  | class | ew | format | class | ew | format |
  |---|---|---|---|---|---|
  | 8-bit | 4 | E4M3 | 16-bit | 8 | BFloat16 |
  | 8-bit | 5 | E5M2 | 32-bit | 8 | SP |
  | 16-bit | 5 | HP | 19-bit | 8 | TF32 |
  | 16-bit | 6 | DLFloat16 | | | |

- `a_i` / `b_i` / `c_i` (64 bits each) pack up to 4 lanes into the low 32 bits: byte lanes for the 8-bit class, halfword lanes for 16-bit, all 32 bits for SP, and the low 19 bits for TF32.
- In mixed-precision mode, lane 0 of `a_i` carries the single addend, and `b_i` / `c_i` carry the lower-precision dot-product operands. The result is in A's format.
- The low 32 bits of `dout_o` carry the packed result, using the same convention.

The header comment of `rtl/fma_top.v` is the authoritative description.

## Deviations from the paper, in brief

This implementation puts correctness first rather than minimal area. The main differences are:
- one unified 24-bit significand for all formats;
- a generic barrel shifter for alignment;
- a leading-zero count done after the add, rather than anticipated in parallel with it;
- a Comparator that also ranks the addend;
- a 76-bit accumulator that carries the exact 48-bit product, with sticky jamming.

Each difference is commented at its point of use and summarized in `docs/DEVIATIONS.md`.
