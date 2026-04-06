# FPGA module library: literate source -> HDL + tests + docs
#
# Each .nw file may produce any subset of these tangled outputs:
#   %.v            synthesizable Verilog
#   tb_%.sv        SystemVerilog testbench
#   golden_%.py    Python golden model (optional)
#   %.sby          SymbiYosys formal configuration (optional)
#   %_props.sv     formal property module (optional)

NW   := $(wildcard *.nw)
MODS := $(NW:.nw=)

# output collections
PDF  := $(addsuffix .pdf,$(MODS))
V    := $(addsuffix .v,$(MODS))
TB   := $(addprefix tb_,$(addsuffix .sv,$(MODS)))
SIM  := $(addprefix obj_dir/Vtb_,$(MODS))

# ---- top-level targets ----

all: $(PDF) $(SIM)

test: $(PDF) $(SIM) formal
	@echo "==== ALL TESTS PASSED ===="

doc: $(PDF)

# prevent Make from deleting tangled files as intermediaries
.SECONDARY:

# ---- tangle rules ----

%.v: %.nw
	tangle $@ < $<

tb_%.sv: %.nw
	tangle $@ < $<

golden_%.py: %.nw
	tangle $@ < $<

%.sby: %.nw
	tangle $@ < $<


# ---- simulation ----

# CORDIC needs a golden model; generate hex files first
obj_dir/Vtb_cordic: tb_cordic.sv cordic.v expected_cordic.hex
	verilator -Wall --binary tb_cordic.sv cordic.v
	cp expected_cordic.hex test_ftws.hex obj_dir/
	obj_dir/Vtb_cordic

expected_cordic.hex test_ftws.hex: golden_cordic.py
	python3 golden_cordic.py

# generic simulation rule for modules without golden models
obj_dir/Vtb_%: tb_%.sv %.v
	verilator -Wall --binary $^
	obj_dir/Vtb_$*

# ---- formal verification ----

# find which modules have .sby chunks
SBY_NW := $(shell for f in $(NW); do grep -l '<<.*\.sby>>=' $$f 2>/dev/null; done)
SBY_MODS := $(SBY_NW:.nw=)
FORMAL := $(addprefix formal_,$(SBY_MODS))

formal: $(FORMAL)

formal_%: %.sby %.v
	sby -f $<

# ---- synthesis estimation (informational, not gating) ----

synth: $(V)
	@for v in $(V); do \
		mod=$${v%.v}; \
		echo "==== $$mod ===="; \
		yosys -p "read_verilog $$v; synth_ice40 -top $$mod" -q 2>&1 | tail -20; \
		echo; \
	done

# ---- documentation ----

%.pdf: %.typ
	typst compile $<

%.typ: %.nw style.txt
	cp style.txt $@
	weave < $< >> $@

# ---- clean ----

clean:
	rm -f *.typ *.v *.sv *.py *.sby *.pdf *.hex
	rm -rf obj_dir
