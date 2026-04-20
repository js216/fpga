# FPGA codes

Reusable FPGA modules written as literate programs. Each `.nw` source
file produces both a typeset PDF document and synthesizable Verilog,
along with self-checking test benches and formal verification properties.

### Prerequisites (Debian/Ubuntu)

Install system packages:

    sudo apt-get install verilator yosys nextpnr-ice40 python3 z3

Install SymbiYosys (formal verification frontend) from source:

    git clone https://github.com/YosysHQ/sby
    cd sby && sudo make install

Install from cargo:

    cargo install typst-cli
    cargo install --git https://github.com/js216/littst

### Getting started

Build everything (docs, sims, formal proofs, bitstreams):

    make

Individual targets: `make doc`, `make sim`, `make formal`, `make bitstream`.

Bitstreams default to the iCEstick (iCE40-HX1K, TQ144, 12 MHz).
Override the target part on the command line:

    make bitstream DEVICE=hx8k PACKAGE=ct256

### Structure

Each `src/*.nw` file is a self-contained literate program containing:

- Synthesizable Verilog (tangled to `verilog/%.v`)
- SystemVerilog testbench (tangled to `tb/tb_%.sv`)
- SymbiYosys configuration (tangled to `build/%.sby`)
- iCEstick pin constraints, where applicable (tangled to `verilog/%.pcf`)

### Modules

| Module | Description |
|--------|-------------|
| `src/blinky.nw` | Parameterized LED blinker (hardware bring-up) |
| `src/uart.nw`   | 8N1 UART receiver, transmitter, and iCEstick echo demo |
| `src/cordic.nw` | CORDIC sine/cosine generator |

### Author

Jakob Kastelic (Stanford Research Systems, Inc.)
