#!/usr/bin/env bash
# U_FMA: the whole verification in one command.
#   1. unit tests    - every RTL block on its own (tb/unit/run_unit.sh)
#   2. system test   - the whole FMA against the golden model (tb/run_sim.sh)
#   3. shell test    - the same vectors through the decimal I/O shell
#                      (fma_fp64_top: operands in / results out as doubles)
#   4. report        - decoded, human-readable summary (tb/report.py)
#                      -> docs/VERIFICATION_REPORT.md
# Usage: ./run_all.sh          (SIM=xsim ./run_all.sh to use Vivado xsim)
set -u
cd "$(dirname "$0")"

echo
echo "=== 1/4  Unit tests: each RTL block on its own ==========================="
tb/unit/run_unit.sh
echo
echo "=== 2/4  System test: whole FMA vs golden model =========================="
tb/run_sim.sh --regen --no-report
sim_rc=$?
echo
echo "=== 3/4  System test through the decimal I/O shell ======================="
tb/run_sim.sh --shell
shell_rc=$?
echo
echo "=== 4/4  Report =========================================================="
python3 tb/report.py
rep_rc=$?
exit $(( sim_rc != 0 || shell_rc != 0 || rep_rc != 0 ))
