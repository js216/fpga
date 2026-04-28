CHAPTERS := $(notdir $(basename $(wildcard src/*.nw)))

# iCEstick defaults; override on command line.
DEVICE  ?= hx1k
PACKAGE ?= tq144

.PHONY: all doc sim formal bitstream clean

all: doc sim formal bitstream

# Top-level aggregates start empty; per-chapter rules add prereqs below.
doc:
sim:
formal:
bitstream:

.NOTINTERMEDIATE:

verilog tb:
	mkdir -p $@

# Order-only dependency target for doc dir (separate from .PHONY doc).
docdir:
	mkdir -p doc
.PHONY: docdir

# ---- tangle to top-level dirs ----

verilog/%.v: src/%.nw | verilog
	cd verilog && tangle $*.v < ../$<

verilog/%.pcf: src/%.nw | verilog
	cd verilog && tangle $*.pcf < ../$<

tb/tb_%.sv: src/%.nw | tb
	cd tb && tangle tb_$*.sv < ../$<

# ---- per-chapter generic rules ----
#
# Everything that fits a single-file pattern lives here; chapters with
# multi-file synthesis lists override .json / sim / formal in their own
# .mk fragment (see below).
define CHAP_RULES

build/$(1):
	mkdir -p $$@

build/$(1)/$(1).sby: src/$(1).nw | build/$(1)
	cd build/$(1) && tangle $(1).sby < ../../$$<

build/$(1)/$(1).mk: src/$(1).nw | build/$(1)
	@cd build/$(1) && tangle $(1).mk < ../../$$< 2>/dev/null
	@touch $$@

build/$(1)/TEST.md: src/$(1).nw | build/$(1)
	@cd build/$(1) && tangle TEST.md < ../../$$< 2>/dev/null
	@touch $$@

build/$(1)/verify.py: src/$(1).nw | build/$(1)
	@cd build/$(1) && tangle verify.py < ../../$$< 2>/dev/null
	@touch $$@

build/$(1)/$(1).typ: src/$(1).nw style.typ | build/$(1)
	cp style.typ $$@
	weave < $$< >> $$@

doc/$(1).pdf: build/$(1)/$(1).typ | docdir
	typst compile $$< $$@

build/$(1)/$(1).asc: build/$(1)/$(1).json verilog/$(1).pcf
	cd build/$(1) && nextpnr-ice40 --$$(DEVICE) --package $$(PACKAGE) \
		--json $(1).json --pcf ../../verilog/$(1).pcf \
		--asc $(1).asc --freq 12 -q

build/$(1)/$(1).bin: build/$(1)/$(1).asc
	cd build/$(1) && icepack $(1).asc $(1).bin

doc: doc/$(1).pdf

endef

$(foreach c,$(CHAPTERS),$(eval $(call CHAP_RULES,$(c))))

# ---- stage ----
#
# Cross-repo bitstream handoff. The MP135 baremetal test fixtures
# resolve `fpga:program bin=@<chap>.bin` against their own
# build/ directory; we own the artifact, so expose it via a
# symlink they can read. Re-run after `make bitstream` if either
# side's `clean` was invoked.

MP135_QSPI_DIR := /home/claude/stm32mp135_test_board/baremetal/qspi/build

stage: bitstream
	@mkdir -p $(MP135_QSPI_DIR)
	ln -sf $(CURDIR)/build/qspi/qspi.bin $(MP135_QSPI_DIR)/qspi.bin

.PHONY: stage

# ---- clean ----

clean:
	rm -rf build doc

# Per-chapter fragments: VS list, .json (multi-file deps), sim, formal,
# and any bitstream/sim/formal aggregate appends.
-include $(foreach c,$(CHAPTERS),build/$(c)/$(c).mk)
