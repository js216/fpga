# Agentic pattern

Pipeline of single-purpose agents. Orchestrator owns FSM, spawns each
phase, relays artifacts.

## Rig reset

/loop 30m
Hardware rig is down. Submit the FPGA `uart_echo` to reset
rig, as follows: `cd build/uart && make test`. (If Makefile missing in
build/uart, tangle it from uart.nw.)

## FSM

Trigger: "read AGENTS.md and work on `<ex>`" → assistant = Orchestrator.
Per `<ex>`, run:

    TEST → red?  → DIAGNOSE → EDIT → BUILD → VERIFY → TEST → green? →
    SCAN     → next issue → TEST  |  DONE

Orchestrator drives loop in foreground (state visible to user).  Each
phase = one short-lived background agent. No heartbeats; exit = status.
Caps: 8 iterations total, 3 same-issue retries.

## Phase agents

Each spawned `general-purpose` with `run_in_background: true`.
Orchestrator does not poll; it waits for the completion notification,
then prints the result before next phase.

- **Tester**: `cd build/<ex> && make test`. Returns PASS/FAIL + failing
  block name + verbatim block tail. NOTE: runner aborts on first failing
  block (no `--full`); blocks past the first failure are NOT executed.
  The summary `K/N BLOCKS FAILED` counts unattempted blocks as
  not-failed --- never read it as `N-K PASSED`. Only blocks before the
  first failure are actually exercised.
- **Diagnoser**: given red output + `<ex>.nw` path, returns fix spec
  (root cause, target chunk name, proposed change). Read-only.
- **Editor**: given spec, edits `<ex>.nw` (literate: named chunks +
  prose, no comment-as-structure). Returns diff.
- **Builder**: `make sim` (must PASS) + `make bitstream` (no new
  warnings). Returns sim result, warning delta, artifact paths.
- **Verifier**: `cd build/<ex> && make test` upload+verify. Same return
  shape as Tester.
- **Scanner**: greps `<ex>.nw` for TODO/FIXME/BUG, deferred blocks,
  prose-flagged issues, recent-commit follow-ups. Returns next
  actionable issue or "none".

## Orchestrator rules

- One pipeline per `<ex>`, parallel across examples.
- On VERIFY green: `git commit` (no Claude co-author, no test-result
  chatter), then SCAN.
- On Builder warning regression or sim FAIL: re-DIAGNOSE with new
  evidence.
- On 3 same-issue VERIFY reds: skip to SCAN.
- Never run `make` or edit source itself; only spawns + commits +
  relays.
- On Diagnoser exit: print full diagnosis (root cause, target chunk,
  proposed change) verbatim before spawning Editor.
- On Verifier exit: print full result (PASS/FAIL, failing block name,
  verbatim tail) verbatim before next FSM transition.
