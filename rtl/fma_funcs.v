// fma_funcs.v
// Reusable combinational helper functions, plain Verilog (IEEE 1364-2001).
// Unlike SystemVerilog, plain Verilog has no compilation-unit (global)
// function scope -- a `function` declaration is only callable from within
// the module that contains it. So this file is deliberately NOT guarded
// against multiple inclusion: it is `include`-d once INSIDE the body of
// every module that calls one of these helpers (right after that module's
// port list, not before the `module` keyword), giving that module its own
// private local copy of the full helper set. Re-including this same text
// into several different modules within one compilation is exactly the
// intended use, not an error -- only including it twice into the *same*
// module body would redefine these functions and must be avoided by the
// caller.
`include "fma_defs.vh"

function [`WW-1:0] shift_mask;
  input [`SHW-1:0] amt;
  begin
    if (amt == 0) shift_mask = 0;
    else shift_mask = ({`WW{1'b1}} >> (`WW - amt));
  end
endfunction

// Right-shift a WW-bit magnitude by `amt` (0..127, saturating beyond WW).
// Returns {sticky, shifted} packed into one WW+1-bit value (bit WW =
// sticky: whether any '1' bit was shifted out, needed for rounding).
function [`WW:0] shift_right_sticky;
  input [`WW-1:0] val;
  input [`SHW-1:0] amt;
  reg [`WW-1:0] shifted;
  reg           sticky;
  begin
    if (amt >= `WW) begin
      shifted = 0;
      sticky  = (val != 0);
    end else begin
      shifted = val >> amt;
      sticky  = |(val & shift_mask(amt));
    end
    shift_right_sticky = {sticky, shifted};
  end
endfunction

function [`SHW-1:0] clamp_shift;
  input signed [`EXPW-1:0] diff;
  reg [`SHW-1:0] r;
  begin
    if (diff < 0) r = 0;
    else if (diff > (2**`SHW - 1)) r = {`SHW{1'b1}};
    else r = diff[`SHW-1:0];
    clamp_shift = r;
  end
endfunction

// Total stored bit width (S+E+M) of one lane's slot for a given class
// (`CLS_8/`CLS_16/`CLS_32/`CLS_19).
function integer class_total_bits;
  input [1:0] cls;
  begin
    case (cls)
      `CLS_8:  class_total_bits = 8;
      `CLS_16: class_total_bits = 16;
      `CLS_32: class_total_bits = 32;
      `CLS_19: class_total_bits = 19;
      default: class_total_bits = 8;
    endcase
  end
endfunction

function integer lane_count;
  input [1:0] cls;
  begin
    case (cls)
      `CLS_8:  lane_count = 4;
      `CLS_16: lane_count = 2;
      `CLS_32: lane_count = 1;
      `CLS_19: lane_count = 1;
      default: lane_count = 1;
    endcase
  end
endfunction

function integer mant_width;
  input [1:0] cls;
  input integer ew;
  begin
    mant_width = class_total_bits(cls) - 1 - ew;
  end
endfunction

function integer bias_of;
  input integer ew;
  begin
    bias_of = (1 << (ew - 1)) - 1;
  end
endfunction

// Route lane `i` of a 64-bit packed operand bus out as a right-justified
// 32-bit slice, per the packing convention documented in fma_top.v
// (byte/halfword/word lanes for the 8-/16-/32-bit classes; low 19 bits
// for the TF32 class). Lanes beyond the class's active lane_count() are
// don't-care duplicates of a valid lane, never X.
function [31:0] lane_slice;
  input [63:0] bus;
  input [1:0]  cls;
  input integer i;
  integer li;
  begin
    case (cls)
      `CLS_8: begin
        li = i % 4;
        lane_slice = {24'b0, bus[8*li +: 8]};
      end
      `CLS_16: begin
        li = i % 2;
        lane_slice = {16'b0, bus[16*li +: 16]};
      end
      `CLS_32: lane_slice = bus[31:0];
      `CLS_19: lane_slice = {13'b0, bus[18:0]};
      default: lane_slice = bus[31:0];
    endcase
  end
endfunction

// Round-to-nearest-even a SIGW-bit normalized significand (sig[23]==1,
// unless input is zero) down to `m` mantissa bits, given extra sticky
// bits below the kept LSB. Returns {rnd_ovf, result} packed into one
// SIGW+1-bit value (bit SIGW = rnd_ovf: a carry-out past the hidden bit,
// requiring +1 to the exponent).
//
// guard_extra/sticky_extra are the bit immediately below sig's window and
// the OR of everything below that, respectively (both supplied by the
// caller, since sig itself only ever holds SIGW=24 bits). At the widest
// supported mantissa (m=SIGW-1=23, e.g. SP), there are zero spare bits
// inside sig for a guard bit -- omitting guard_extra there would silently
// truncate instead of round (the round decision would only ever see
// "exact", regardless of what was shifted out below the kept field).
function [`SIGW:0] round_nearest_even;
  input [`SIGW-1:0] sig;
  input integer     m;
  input             guard_extra;
  input             sticky_extra;
  integer drop;
  integer b;
  reg guard, round_b, sticky;
  reg [`SIGW-1:0] kept;
  reg [`SIGW-1:0] result;
  reg [`SIGW-1:0] result_o;
  reg rnd_ovf;
  reg [`SIGW:0] wide_result;
  begin
    // kept mantissa occupies sig[23 -: (m+1)] (hidden bit + m bits);
    // bits below that, plus guard_extra/sticky_extra, are guard/round/sticky.
    drop = `SIGW - 1 - m; // number of bits below the kept field, within sig
    if (drop <= 0) begin
      // m==SIGW-1 (full-width mantissa, e.g. SP): kept already uses all
      // SIGW bits, so a round-up carry must be captured in one extra bit
      // rather than indexed as result[m+1] (out of range for a SIGW-bit
      // register when m+1==SIGW).
      kept   = sig;
      guard  = guard_extra;
      sticky = sticky_extra;
      if (guard && (sticky || kept[0])) begin
        wide_result = {1'b0, kept} + 1'b1;
      end else begin
        wide_result = {1'b0, kept};
      end
      rnd_ovf  = wide_result[`SIGW];
      result_o = wide_result[`SIGW-1:0];
    end else begin
      guard   = sig[drop-1];
      round_b = (drop >= 2) ? sig[drop-2] : 1'b0;
      sticky  = sticky_extra | guard_extra;
      for (b = 0; b <= drop-3; b = b + 1) sticky = sticky | sig[b];
      kept = sig >> drop;
      if (guard && (round_b || sticky || kept[0])) begin
        result = kept + 1'b1;
      end else begin
        result = kept;
      end
      rnd_ovf = result[m+1]; // carry propagated past hidden bit
      result_o = result << drop;
    end
    round_nearest_even = {rnd_ovf, result_o};
  end
endfunction
