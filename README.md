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

### How to Test

The source file in each example explains the hardware and procedure needed to
test manually, as well as a description of the automated test procedure using
the [`test_serv`](https://github.com/js216/test_serv) framework.

Each example defines a `verify.py` script which makes use of the bullet points
following each automated test description to check that the returned test
artifacts pass the test criteria.

With the test server running, each example can be verified in one step. For
example:

    cd build/uart
    python3 $TEST_SERV/run_md.py

### Modules

- **blinky**: Parameterized LED blinker (hardware bring-up)
- **uart**: 8N1 UART receiver, transmitter, and iCEstick echo demo
- **gpio**: Verify and emit signals on GPIO pins
- **qspi**: Emulate a QSPI flash interface
- **cordic**: CORDIC sine/cosine generator

### Author

Jakob Kastelic (Stanford Research Systems, Inc.)
