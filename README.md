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

Verify all tools are available:

    which tangle weave verilator yosys sby nextpnr-ice40 typst python3

### Getting started

Build documentation and run all tests:

    make test

Build only the PDF documentation:

    make doc

Run synthesis estimation (informational, targets ICE40HX4K-TQ144):

    make synth

### Structure

Each `.nw` file is a self-contained literate program containing:

- Synthesizable Verilog (tangled to `%.v`)
- SystemVerilog testbench (tangled to `tb_%.sv`)
- Golden model script, if needed (tangled to `golden_%.py`)
- SymbiYosys configuration (tangled to `%.sby`)
- Formal property module (tangled to `%_props.sv`)

All code, including tests, appears in the PDF for offline review.

### Modules

| Module | Description |
|--------|-------------|
| `cordic.nw` | CORDIC sine/cosine generator |
| `blinky.nw` | Parameterized LED blinker (hardware bring-up) |

### Author

Jakob Kastelic (Stanford Research Systems, Inc.)
