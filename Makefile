# FPGA module library: literate source -> HDL + tests + docs
#
# All build artifacts go under build/ to keep the source
# directory clean. Stamp files (sim_*, formal_*) prevent
# re-running passing tests unless sources change.

B := build
NW   := $(wildcard *.nw)
MODS := $(NW:.nw=)

# ---- top-level targets ----

all: doc sim

test: doc sim formal
	@echo "==== ALL TESTS PASSED ===="

doc: $(addprefix $(B)/,$(addsuffix .pdf,$(MODS)))

sim: $(addprefix $(B)/sim_,$(MODS))

formal: $(addprefix $(B)/formal_,$(MODS))

# prevent Make from deleting tangled files as intermediaries
.SECONDARY:

# ---- directory ----

$(B):
	mkdir -p $(B)

# ---- tangle rules ----

$(B)/%.v: %.nw | $(B)
	cd $(B) && tangle $*.v < ../$<

$(B)/tb_%.sv: %.nw | $(B)
	cd $(B) && tangle tb_$*.sv < ../$<

$(B)/%.sby: %.nw | $(B)
	cd $(B) && tangle $*.sby < ../$<

# ---- documentation ----

$(B)/%.pdf: %.nw style.txt | $(B)
	cp style.txt $(B)/$*.typ
	weave < $< >> $(B)/$*.typ
	typst compile $(B)/$*.typ

# ---- simulation ----

$(B)/sim_%: $(B)/tb_%.sv $(B)/%.v
	cd $(B) && verilator -Wall --binary tb_$*.sv $*.v
	cd $(B) && obj_dir/Vtb_$*
	@touch $@

# ---- formal verification ----

$(B)/formal_%: $(B)/%.sby $(B)/%.v
	cd $(B) && sby -f $*.sby
	@touch $@

# ---- synthesis estimation (informational) ----

synth: $(addprefix $(B)/,$(addsuffix .v,$(MODS)))
	@for v in $(MODS); do \
		echo "==== $$v ===="; \
		yosys -p "read_verilog $(B)/$$v.v; synth_ice40 -top $$v" -q 2>&1 | tail -20; \
		echo; \
	done

# ---- clean ----

clean:
	rm -rf $(B)
