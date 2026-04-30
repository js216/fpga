# TODO: QSPI FPGA-to-MPU Mission Handoff

## Mission target

Demonstrate bit-accurate sustained data transfer from FPGA to STM32MP135 MPU
using the real QUADSPI peripheral:

- Single-lane path: already demonstrated above 100 Mbps wall-rate with 512 MB
  transfer.
- Quad-lane path: still unfinished.
- Final quad requirement: at least 200 Mbps, ideally higher, with no data
  errors.

## Current verified state

Latest full-suite run:

- Command: `cd /home/claude/SR835_firmware/fpga/build/spi && make test`
- Result: 19 passing blocks, first failure at block 20/31.
- First failing test: `Check quad peripheral read returns 1024-byte incrementing
  pattern`
- Failure symptom: `quad raw mismatch at 1: got 10, expected 01`
- Quad throughput/rate tests were not reached.

Passing before the failure:

- 1-lane stream @ presc=5 wall rate >= 100 Mbps.
- 1-lane 512 MB stream @ presc=5 within 45 s, correct CRC, wall rate about 109
  Mbps.
- Quad peripheral diagnostics:
  - 0x6C one-hot returns `12 48 ...`
  - 0x6E nibble-hold returns `00 11 22 ... ff`
  - 0x6F nibble-ramp returns `01 23 45 67 89 ab cd ef`

## Required working pattern

- Read and follow `AGENTS.md`.
- Use short-lived fresh agents for diagnoser/editor/verifier/review roles.
- Close each agent after it finishes.
- Do not run individual tests.
- Always verify with full suite only: `cd
  /home/claude/SR835_firmware/fpga/build/spi && make test`
- Do not remove passing tests.
- Keep monotonic progress: no change is acceptable if it regresses previously
  passing blocks.

## Immediate next tasks

1. Stabilize the 0x6B quad peripheral read.
   - Current blocker is byte assembly/cadence for `op=6b`.
   - The passing 0x6F nibble-ramp proves the STM32 peripheral can capture
     ordered quad nibbles correctly.
   - The 0x6B stream still captures as `00 10 20 ...` or related byte-phase
     variants depending on FPGA cadence changes.
   - Future agents should avoid relying on GPIO bit-bang results as proof of
     QUADSPI peripheral behavior.

2. Add a low-cost 0x6B-specific diagnostic if needed.
   - Avoid the previous synthesis-heavy q6b/q60/q61 debug RAM/printing; it
     caused iCE40 placement failure.
   - Prefer a small opcode or mode that emits a simple repeating 0x6B-compatible
     byte pattern through the same peripheral framing.
   - Keep diagnostics late or non-blocking only if they are not the mission
     path; do not delete them.

3. Once `q 0 1024` passes, continue through the existing quad sweep.
   - Required next gates are quad pattern checks at presc=203, 63, 15, and 5.
   - Then add/enable a real quad wall-rate floor of at least 200 Mbps.
   - Use wall timing markers already defined by the test policy: before UART
     start command, after firmware reports transfer completion/check.

4. Make quad streaming use the proven DMA/CRC structure.
   - Single-lane uses DDR ping-pong/auto-consume and hardware CRC path
     successfully.
   - Quad path should use the same sustained-transfer validation model once the
     basic 0x6B peripheral read is bit-correct.
   - Do not claim throughput success until a large transfer is checked for
     correctness.

5. Clean up before commit.
   - Review dirty generated files and source noweb outputs carefully.
   - Do not revert unrelated user changes.
   - Commit only after the full suite reaches the intended green point or after
     an explicitly agreed checkpoint.

## Files most likely involved

- FPGA source: `src/qspi.nw`
- Test plan/checkers: `src/spi.nw`
- Generated outputs may change after builds:
  - `verilog/qspi.v`
  - `tb/tb_qspi.sv`
  - other generated Verilog/testbench files
- Firmware QUADSPI driver:
  `/home/claude/stm32mp135_test_board/baremetal/qspi/src/qspi.c`
- Firmware CLI: `/home/claude/stm32mp135_test_board/baremetal/qspi/src/cli.c`

## Known bad or inconclusive attempts

- Requiring the old FPGA `q6b pn=... io=...` debug line is obsolete; that debug
  path was removed to fit the FPGA.
- The synthesis-heavy q6b/q60/q61 capture path caused `nextpnr-ice40` placement
  failure.
- `data_byte - 1` seeding made the first captured byte `f0`; it is not the right
  fix.
- A temporary first-byte hold improved the first bytes but failed at byte 7.
- Low-nibble-first changes were influenced by GPIO bit-bang behavior and did not
  solve the real QUADSPI peripheral path.

## Current caution

The current working tree is dirty and mid-investigation. Future agents should
inspect the current diffs before editing and should treat the latest verified
full-suite result as the only trusted hardware status.
