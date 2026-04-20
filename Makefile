CHAPTERS := $(notdir $(basename $(wildcard src/*.nw)))

# iCEstick defaults; override on command line.
DEVICE  ?= hx1k
PACKAGE ?= tq144

.PHONY: all doc sim formal bitstream clean

all: doc sim formal bitstream

doc:    $(addprefix doc/,$(addsuffix .pdf,$(CHAPTERS)))
sim:    $(addprefix build/sim_,$(CHAPTERS))
formal: $(addprefix build/formal_,$(CHAPTERS))
bitstream:  # per-chapter .mk fragments append prereqs

.NOTINTERMEDIATE:

build verilog tb:
	mkdir -p $@

# ---- tangle ----

verilog/%.v: src/%.nw | verilog
	cd verilog && tangle $*.v < ../$<

verilog/%.pcf: src/%.nw | verilog
	cd verilog && tangle $*.pcf < ../$<

tb/tb_%.sv: src/%.nw | tb
	cd tb && tangle tb_$*.sv < ../$<

build/%.sby: src/%.nw | build
	cd build && tangle $*.sby < ../$<

# Makefile fragment: optional, empty if chapter has no <<%.mk>> chunk.
build/%.mk: src/%.nw | build
	@cd build && tangle $*.mk < ../$< 2>/dev/null
	@touch $@

# ---- doc ----

doc/%.pdf: src/%.nw style.typ | build
	@mkdir -p doc
	cp style.typ build/$*.typ
	weave < $< >> build/$*.typ
	typst compile build/$*.typ doc/$*.pdf

# ---- sim ----

build/sim_%: tb/tb_%.sv verilog/%.v | build
	cd build && verilator -Wall --binary --top-module tb_$* \
		../tb/tb_$*.sv ../verilog/$*.v
	cd build && obj_dir/Vtb_$*
	@touch $@

# ---- formal ----

build/formal_%: build/%.sby verilog/%.v
	cd build && sby -f $*.sby
	@touch $@

# ---- bitstream ----

build/%.json: verilog/%.v | build
	cd build && yosys -q -p "read_verilog ../verilog/$*.v; \
		synth_ice40 -top $* -json $*.json"

build/%.asc: build/%.json verilog/%.pcf
	cd build && nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) \
		--json $*.json --pcf ../verilog/$*.pcf --asc $*.asc \
		--freq 12 -q

build/%.bin: build/%.asc
	cd build && icepack $*.asc $*.bin

# ---- clean ----

clean:
	rm -rf build doc

# ---- per-chapter fragments ----

-include $(addprefix build/,$(addsuffix .mk,$(CHAPTERS)))
