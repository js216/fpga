# SPDX-License-Identifier: MIT
# Makefile --- TODO: description
# Copyright (c) 2026 Jakob Kastelic
CHAPTERS := $(notdir $(basename $(wildcard src/*.nw)))

chapter_src = src/$(1).nw

# Single-target default (used by chapters that don't declare BOARDS_<name>).
# Override on the command line: `make DEVICE=hx8k PACKAGE=ct256 ...`.
DEVICE  ?= hx1k
PACKAGE ?= tq144

# Chapters that build for more than one iCE40 board declare their list
# below. Each board gets its own subdirectory under build/<chap>/, its
# own pcf (verilog/<chap>_<board>.pcf), its own bitstream, and its own
# tangled TEST.md / verify.py. Single-target chapters leave BOARDS_<chap>
# empty and keep the legacy DEVICE/PACKAGE flow.
BOARDS_uart := hx1k hx8k

# Per-board nextpnr arguments. Add a row when you add a board.
nextpnr_pkg_hx1k := tq144
nextpnr_pkg_hx8k := ct256

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

build/$(1)/$(1).sby: $$(call chapter_src,$(1)) | build/$(1)
	cd build/$(1) && tangle $(1).sby < ../../$$<

build/$(1)/$(1).mk: $$(call chapter_src,$(1)) | build/$(1)
	@cd build/$(1) && tangle $(1).mk < ../../$$< 2>/dev/null
	@touch $$@

build/$(1)/Makefile: $$(call chapter_src,$(1)) | build/$(1)
	@cd build/$(1) && tangle Makefile < ../../$$< 2>/dev/null
	@touch $$@

build/$(1)/$(1).typ: $$(call chapter_src,$(1)) style.typ | build/$(1)
	cp style.typ $$@
	weave < $$< >> $$@

doc/$(1).pdf: build/$(1)/$(1).typ | docdir
	typst compile $$< $$@

doc: doc/$(1).pdf

ifeq ($$(BOARDS_$(1)),)
# ---- single-target chapter: legacy DEVICE/PACKAGE flow ----

build/$(1)/$(1).asc: build/$(1)/$(1).json verilog/$(1).pcf
	cd build/$(1) && nextpnr-ice40 --$$(DEVICE) --package $$(PACKAGE) \
		--json $(1).json --pcf ../../verilog/$(1).pcf \
		--asc $(1).asc --freq 12 -q

build/$(1)/$(1).bin: build/$(1)/$(1).asc
	cd build/$(1) && icepack $(1).asc $(1).bin

else
# ---- multi-board chapter: one bitstream per board ----
$$(foreach b,$$(BOARDS_$(1)),$$(eval $$(call CHAP_BOARD_RULES,$(1),$$(b))))
endif

endef

# Per-(chapter,board) rules. $(1) = chapter, $(2) = board.
define CHAP_BOARD_RULES

build/$(1)/$(2):
	mkdir -p $$@

build/$(1)/$(2)/$(1).asc: build/$(1)/$(1).json verilog/$(1)_$(2).pcf | build/$(1)/$(2)
	cd build/$(1)/$(2) && nextpnr-ice40 --$(2) --package $$(nextpnr_pkg_$(2)) \
		--json ../$(1).json --pcf ../../../verilog/$(1)_$(2).pcf \
		--asc $(1).asc --freq 12 -q --pcf-allow-unconstrained

build/$(1)/$(2)/$(1).bin: build/$(1)/$(2)/$(1).asc
	cd build/$(1)/$(2) && icepack $(1).asc $(1).bin

bitstream: build/$(1)/$(2)/$(1).bin

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
MP135_QSPI_SRC := /home/claude/stm32mp135_test_board/baremetal/qspi

stage: bitstream
	@mkdir -p $(MP135_QSPI_DIR)
	ln -sf $(CURDIR)/build/jedec/jedec.bin $(MP135_QSPI_DIR)/jedec.bin
	@mkdir -p $(CURDIR)/build/spi
	ln -sf $(MP135_QSPI_DIR)/main.stm32 $(CURDIR)/build/spi/main.stm32
	ln -sf $(MP135_QSPI_SRC)/flash.tsv  $(CURDIR)/build/spi/flash.tsv
	@mkdir -p $(CURDIR)/build/uart
	ln -sf $(MP135_QSPI_DIR)/main.stm32 $(CURDIR)/build/uart/main.stm32
	ln -sf $(MP135_QSPI_SRC)/flash.tsv  $(CURDIR)/build/uart/flash.tsv

.PHONY: stage

# ---- clean ----

clean:
	rm -rf build doc

# Per-chapter fragments: VS list, .json (multi-file deps), sim, formal,
# and any bitstream/sim/formal aggregate appends.
-include $(foreach c,$(CHAPTERS),build/$(c)/$(c).mk)
