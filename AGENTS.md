# Agentic pattern

Loop: identify failing hardware test → fix qspi.nw → upload → verify → commit →
next.

## Roles

**Orchestrator**
- Runs `python3 $TEST_SERV/run_md.py` in
  `~/stm32mp135_test_board/baremetal/qspi/` (fail-fasts on first red block).
- Diagnoses the missing qspi.nw feature.
- Writes a detailed fix spec.
- Dispatches Worker (background).
- After Worker returns: re-runs the test runner directly (skip Verifier when
  PASS/FAIL is already structured).
- On green: commits `src/qspi.nw` + tangled `verilog/qspi.v` + `tb/tb_qspi.sv`.
  Loops.
- On red: feeds output back, re-dispatches.

**Worker** (background `general-purpose`)
- Edits `src/qspi.nw` per spec. Literate style: named chunks, prose, no
  comment-as-structure.
- `make sim` → PASS.
- `make bitstream` → clean (no new warnings).
- `cd build/qspi && python3 $TEST_SERV/run_md.py` → uploads via TEST.md
  (`fpga:program`).
- Reports: sim pass, build warnings, upload status, files touched.

**Verifier** (only when output ambiguous)
- Runs the MP135 test suite, reports next failure. Most loops skip this.

## Constraints

- Read-only: `~/stm32mp135_test_board/` (other agent owns).
- Zero `-Wno-*`, `verilator lint_off`, `(* keep *)`, `#[allow]`. Root-cause
  warnings.
- Tangled `.v` / `.sv` are tracked — commit with the `.nw`.
- No SPDX header on `.nw` / `.v` / `.sv` (only `.rs`).
