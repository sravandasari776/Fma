// tb_util.vh
// Shared reporting helpers for the per-block unit testbenches in tb/unit/.
// `include-d INSIDE each testbench module body, right after that module
// declares `parameter TB_NAME = "<block name>";` (plain Verilog has no
// global task scope, so every testbench gets its own copy).
//
// Every unit testbench prints the same layout so results are easy to read:
//   ==== banner (block name + what it is supposed to do) ====
//   --- directed tests ---   one readable row per hand-picked case
//   --- random tests   ---   N vectors vs. a reference model (only the
//                            first few failures, if any, are printed)
//   SUMMARY <block> : checks | PASS | FAIL | BLOCK PASSED/FAILED
//
// Compile with +define+DUMP_WAVES to also get <TB_NAME>.vcd for viewing
// in SimVision / GTKWave (run_unit.sh does this by default).

integer n_pass;
integer n_fail;
integer seed;

task banner;
  input [8*120-1:0] title;
  input [8*110-1:0] func;
  begin
    n_pass = 0;
    n_fail = 0;
    seed   = 32'h1234_5678;
    $display("");
    $display("==========================================================================================");
    $display(" UNIT TEST : %0s", title);
    $display(" FUNCTION  : %0s", func);
    $display("==========================================================================================");
  end
endtask

task section;
  input [8*110-1:0] s;
  begin
    $display("");
    $display(" --- %0s ---", s);
  end
endtask

task tally;
  input ok;
  begin
    if (ok) n_pass = n_pass + 1;
    else    n_fail = n_fail + 1;
  end
endtask

function [8*4-1:0] pf;
  input ok;
  begin
    pf = ok ? "PASS" : "FAIL";
  end
endfunction

// print the last line of every random section
task random_done;
  input integer n;
  input integer fails_before;
  begin
    $display("   %0d random vectors checked against the reference model: %0d mismatches",
             n, n_fail - fails_before);
  end
endtask

task summary;
  begin
    $display("");
    $display("------------------------------------------------------------------------------------------");
    if (n_fail == 0)
      $display(" SUMMARY %0s : %0d checks | %0d PASS | %0d FAIL | BLOCK PASSED",
               TB_NAME, n_pass + n_fail, n_pass, n_fail);
    else
      $display(" SUMMARY %0s : %0d checks | %0d PASS | %0d FAIL | BLOCK FAILED",
               TB_NAME, n_pass + n_fail, n_pass, n_fail);
    $display("==========================================================================================");
    $finish;
  end
endtask

`ifdef DUMP_WAVES
initial begin
  $dumpfile({"tb_", TB_NAME, ".vcd"});
  $dumpvars;
end
`endif
