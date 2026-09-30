#!/usr/bin/env bash
# Stress test: extra random regressions with other seeds, beyond the
# committed tb/vectors.txt (seed 0xF3A5EED). Each seed is a fresh ~10.7k-
# vector set from the same generator and golden model. Mismatches, if any,
# are decoded into tb/out/stress_<seed>/report.md.
# Usage: tb/run_stress.sh [seed ...]      (default seeds: 1 2 3)
set -u
cd "$(dirname "$0")"
SEEDS=${*:-1 2 3}
total=0; bad=0
for s in $SEEDS; do
  d=out/stress_$s
  mkdir -p "$d"
  python3 gen_vectors.py --seed "$s" --out "$d/vectors.txt" --demo-out "$d/demo_vectors.txt" >/dev/null
  ./run_sim.sh --vectors="$d/vectors.txt" --no-report >/dev/null
  cp out/sim_results.txt "$d/"
  n=$(head -1 "$d/vectors.txt"); f=$(grep -c " F$" "$d/sim_results.txt")
  total=$((total + n)); bad=$((bad + f))
  printf "seed %-6s %6d vectors  %6d pass  %3d mismatches   (decoded: tb/%s/report.md)\n" "$s" "$n" $((n - f)) "$f" "$d"
  python3 report.py --vectors "$d/vectors.txt" --results "$d/sim_results.txt" --md "$d/report.md" >/dev/null
done
echo "stress total: $total vectors, $((total - bad)) pass, $bad mismatches"
