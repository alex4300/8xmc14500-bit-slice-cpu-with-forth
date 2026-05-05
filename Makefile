# ============================================================================
# Makefile — MC14500 Bit-Slice CPU Project
# ============================================================================
#
# Prerequisites (macOS/Linux):
#   brew install icarus-verilog   (or apt install iverilog)
#   python3 (for assembler)
#
# Quick start:
#   make cpu                     — Run CPU testbench (21 tests)
#   make forth                   — Launch Forth REPL
#   make demo                    — Run Sierpinski + math demo
#
# ============================================================================

IVERILOG = iverilog
VVP      = vvp
MCASM    = python3 asm/mcasm.py

# Source files
RTL       = rtl/mc14500_cpu.v rtl/mc14500_slice.v rtl/spi_master.v
BUILD_DIR = build

# Waveform viewer (optional)
WAVE_VIEWER = surfer

# Default program for emulator
PROGRAM = asm/forth.asm

.PHONY: all slice cpu cpu-sync run repl forth demo rstack-demo sierpinski bench wave-slice wave-cpu clean bitstream flash flash-bit fpga-test fpga-test-simple loopback-test led-test uart-test

all: slice cpu

# --- Build directory ---
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# --- Assembler: .asm → .mem + .ram ---
$(BUILD_DIR)/%.mem: asm/%.asm asm/mcasm.py | $(BUILD_DIR)
	$(MCASM) $< -o $@

# Phase D: ROM is the Forth kernel only.  blocks_core.fth (HEDIT, MENU,
# files-FS) lives on the SD card; the user uploads it once with
# tools/upload_blocks.py and loads it on demand from the prompt
# (`SD-INIT . 0 100 0 110 THRU` or similar).  No boot_text BRAM needed.
$(BUILD_DIR)/forth.mem: asm/forth.asm asm/mcasm.py | $(BUILD_DIR)
	$(MCASM) asm/forth.asm -o $@

# --- Single Slice Testbench ---
slice: $(BUILD_DIR)/tb_slice.vvp
	@echo ""
	@echo "========================================"
	@echo "  Running Slice Testbench"
	@echo "========================================"
	$(VVP) $<

$(BUILD_DIR)/tb_slice.vvp: sim/tb_slice.v rtl/mc14500_slice.v | $(BUILD_DIR)
	$(IVERILOG) -o $@ $^

# --- Full CPU Testbench ---
cpu: $(BUILD_DIR)/tb_cpu.vvp $(BUILD_DIR)/test_cpu.mem
	@echo ""
	@echo "========================================"
	@echo "  Running CPU Testbench (SYNC_MEM=0, combinational)"
	@echo "========================================"
	$(VVP) $(BUILD_DIR)/tb_cpu.vvp

$(BUILD_DIR)/tb_cpu.vvp: sim/tb_cpu.v $(RTL) $(BUILD_DIR)/test_cpu.mem | $(BUILD_DIR)
	$(IVERILOG) -o $@ sim/tb_cpu.v $(RTL)

# Same testbench but with SYNC_MEM=1 — verifies the FPGA-path pipeline in sim
cpu-sync: $(BUILD_DIR)/tb_cpu_sync.vvp $(BUILD_DIR)/test_cpu.mem
	@echo ""
	@echo "========================================"
	@echo "  Running CPU Testbench (SYNC_MEM=1, registered BRAM path)"
	@echo "========================================"
	$(VVP) $(BUILD_DIR)/tb_cpu_sync.vvp

$(BUILD_DIR)/tb_cpu_sync.vvp: sim/tb_cpu.v $(RTL) $(BUILD_DIR)/test_cpu.mem | $(BUILD_DIR)
	$(IVERILOG) -o $@ -Pmc14500_cpu.SYNC_MEM=1 sim/tb_cpu.v $(RTL)

# --- Interactive Emulator ---
MEM_FILE = $(BUILD_DIR)/$(notdir $(PROGRAM:.asm=.mem))
RAM_FILE = $(MEM_FILE:.mem=.ram)
# Optional storage hex file (compiled from .fth via blockc.py)
STORAGE  =
# If set, write storage back here on simulator exit (persistence)
STORAGE_OUT =

run: $(MEM_FILE) $(STORAGE)
	@rm -f $(BUILD_DIR)/tb_interactive.vvp
	@$(IVERILOG) -o $(BUILD_DIR)/tb_interactive.vvp \
		-Ptb_interactive.ROM_FILE=\"$(MEM_FILE)\" \
		$(if $(wildcard $(RAM_FILE)),-Ptb_interactive.RAM_FILE=\"$(RAM_FILE)\") \
		$(if $(STORAGE),-Ptb_interactive.STORAGE_FILE=\"$(STORAGE)\") \
		$(if $(STORAGE_OUT),-Ptb_interactive.STORAGE_OUT=\"$(STORAGE_OUT)\") \
		sim/tb_interactive.v $(RTL)
	@echo ""
	@echo "========================================"
	@echo "  MC14500 Interactive Emulator"
	@echo "  Program: $(PROGRAM)"
	@echo "========================================"
	@echo ""
	@if [ -t 0 ]; then : > $(BUILD_DIR)/.uart_input; else cat > $(BUILD_DIR)/.uart_input; fi
	@INPUT_FILE=$(BUILD_DIR)/.uart_input $(VVP) $(BUILD_DIR)/tb_interactive.vvp

# --- Forth REPL (type commands, Ctrl+D to execute) ---
forth: repl
repl: $(MEM_FILE) $(STORAGE)
	@rm -f $(BUILD_DIR)/tb_interactive.vvp
	@$(IVERILOG) -o $(BUILD_DIR)/tb_interactive.vvp \
		-Ptb_interactive.ROM_FILE=\"$(MEM_FILE)\" \
		$(if $(wildcard $(RAM_FILE)),-Ptb_interactive.RAM_FILE=\"$(RAM_FILE)\") \
		$(if $(STORAGE),-Ptb_interactive.STORAGE_FILE=\"$(STORAGE)\") \
		$(if $(STORAGE_OUT),-Ptb_interactive.STORAGE_OUT=\"$(STORAGE_OUT)\") \
		sim/tb_interactive.v $(RTL)
	@echo "========================================"
	@echo "  MC14500 Forth REPL"
	@echo "  Type Forth commands, then Ctrl+D"
	@echo "========================================"
	@cat | tr '\n' '\r' > $(BUILD_DIR)/.uart_input
	@echo ""
	@INPUT_FILE=$(BUILD_DIR)/.uart_input $(VVP) $(BUILD_DIR)/tb_interactive.vvp 2>&1 | grep -v WARNING

# --- Demo targets ---
demo: $(MEM_FILE)
	@cat asm/demo/demo.fth | make run PROGRAM=asm/forth.asm

sierpinski: $(MEM_FILE)
	@cat asm/demo/demo_sierpinski.fth | make run PROGRAM=asm/forth.asm

# Verification tests for >R/R>/R@, 2SWAP forthword, INVERT forthword,
# and 3-level nested forthword calls (needs HW stack depth >= 16).
rstack-demo: $(MEM_FILE)
	@cat asm/demo/demo_rstack.fth | make run PROGRAM=asm/forth.asm

# Block-storage demo: boot loads Block 0 from storage
$(BUILD_DIR)/storage.hex: asm/demo/blocks.fth asm/blockc.py | $(BUILD_DIR)
	python3 asm/blockc.py $< -o $@

storage: $(MEM_FILE) $(BUILD_DIR)/storage.hex
	@cat | make run PROGRAM=asm/forth.asm STORAGE=$(BUILD_DIR)/storage.hex

# --- Benchmark ---
bench: $(BUILD_DIR)/bench.mem $(BUILD_DIR)/bench_forth.mem
	@echo ""
	@echo "=== Raw Assembly ==="
	$(IVERILOG) -o $(BUILD_DIR)/tb_bench_raw.vvp \
		-Ptb_bench.ROM_FILE=\"$(BUILD_DIR)/bench.mem\" \
		-Ptb_bench.MUL_START=11\'h020 -Ptb_bench.MUL_END=11\'h02E \
		-Ptb_bench.FIB_START=11\'h042 -Ptb_bench.FIB_END=11\'h04E \
		-Ptb_bench.FILL_START=11\'h061 -Ptb_bench.FILL_END=11\'h06D \
		sim/tb_bench.v $(RTL)
	@$(VVP) $(BUILD_DIR)/tb_bench_raw.vvp 2>&1 | grep -v WARNING
	@echo "=== STC Forth ==="
	$(IVERILOG) -o $(BUILD_DIR)/tb_bench_forth.vvp \
		-Ptb_bench.ROM_FILE=\"$(BUILD_DIR)/bench_forth.mem\" \
		-Ptb_bench.MUL_START=11\'h02C -Ptb_bench.MUL_END=11\'h041 \
		-Ptb_bench.FIB_START=11\'h057 -Ptb_bench.FIB_END=11\'h063 \
		-Ptb_bench.FILL_START=11\'h077 -Ptb_bench.FILL_END=11\'h083 \
		sim/tb_bench.v $(RTL)
	@$(VVP) $(BUILD_DIR)/tb_bench_forth.vvp 2>&1 | grep -v WARNING

# --- Waveform Viewers ---
wave-slice: $(BUILD_DIR)/tb_slice.vcd
	$(WAVE_VIEWER) $<

wave-cpu: $(BUILD_DIR)/tb_cpu.vcd
	$(WAVE_VIEWER) $<

# ============================================================================
# FPGA synthesis (Tang Nano 20K)
# ============================================================================
# Requires: yosys, nextpnr-himbaechel (with gowin support), gowin_pack
#   macOS:  brew install yosys && cargo install --git https://github.com/YosysHQ/apicula
#           brew install nextpnr (or build from source with himbaechel)
#   Linux:  apt install yosys && build nextpnr-himbaechel + apicula from source
# Programmer:
#   brew install openfpgaloader   # or build from source
#
# Targets:
#   make bitstream   — synthesize and route → build/mc14500_top.fs
#   make flash       — program FPGA (volatile, lost on power-off)
#   make flash-bit   — program external flash (persistent)
# ============================================================================

FPGA_TOP     = mc14500_top
# Tang Primer 20K + Dock ext-board (GW2A-LV18 in PG256 BGA package)
FPGA_DEVICE  = GW2A-LV18PG256C8/I7
FPGA_FAMILY  = GW2A-18
FPGA_BOARD   = tangprimer20k
FPGA_SOURCES = rtl/mc14500_top.v rtl/uart_tx.v rtl/uart_rx.v $(RTL)
FPGA_CST     = constraints/tang_primer_20k.cst

# Generate Forth microcode + inline ROM init for synthesis (yosys drops
# $readmemh silently for wider memories, so we paste the ROM contents
# directly as `rom[i] = 48'h...;` into forth_init.vh via --verilog-init).
$(BUILD_DIR)/forth_init.vh $(BUILD_DIR)/forth_ram_init.vh: $(BUILD_DIR)/forth.mem
	python3 asm/mcasm.py asm/forth.asm -o $(BUILD_DIR)/forth.mem --verilog-init
	cp $(BUILD_DIR)/forth.vh     $(BUILD_DIR)/forth_init.vh
	cp $(BUILD_DIR)/forth_ram.vh $(BUILD_DIR)/forth_ram_init.vh

# Storage BRAM init (blocks.fth → inline Verilog for 64-block FPGA storage)
$(BUILD_DIR)/storage_init.vh: asm/demo/blocks.fth asm/blockc.py | $(BUILD_DIR)
	python3 asm/blockc.py asm/demo/blocks.fth -o $(BUILD_DIR)/storage.hex \
		--verilog-init $(BUILD_DIR)/storage_init.vh --fpga-blocks 64

$(BUILD_DIR)/$(FPGA_TOP).json: $(FPGA_SOURCES) $(BUILD_DIR)/forth.mem $(BUILD_DIR)/forth_init.vh $(BUILD_DIR)/forth_ram_init.vh | $(BUILD_DIR)
	yosys -p "read_verilog -sv -DFPGA_BUILD -DFPGA_INLINE_INIT $(FPGA_SOURCES); \
		synth_gowin -top $(FPGA_TOP) -json $@" 2>&1 | tee $(BUILD_DIR)/$(FPGA_TOP)_yosys.log

$(BUILD_DIR)/$(FPGA_TOP)_pnr.json: $(BUILD_DIR)/$(FPGA_TOP).json $(FPGA_CST)
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device $(FPGA_DEVICE) \
		--vopt family=$(FPGA_FAMILY) \
		--vopt cst=$(FPGA_CST)

bitstream: $(BUILD_DIR)/$(FPGA_TOP).fs
$(BUILD_DIR)/$(FPGA_TOP).fs: $(BUILD_DIR)/$(FPGA_TOP)_pnr.json
	gowin_pack -d $(FPGA_FAMILY) -o $@ $<

flash: $(BUILD_DIR)/$(FPGA_TOP).fs
	openFPGALoader -b $(FPGA_BOARD) $<

flash-bit: $(BUILD_DIR)/$(FPGA_TOP).fs
	openFPGALoader -b $(FPGA_BOARD) -f $<

# --- FPGA CPU test (minimal: sends "Hi!" via UART, no SYNC_MEM pipeline) ---
# Uses SYNC_MEM=0 + tiny ROM/RAM that fits in LUTs (no BRAM complications).
# FPGA_INLINE_INIT tells the CPU to use an inline Verilog include instead of
# $readmemh — Gowin/yosys occasionally drops readmemh for wider ROMs.
# Defaults to test_fpga.asm (polling), override with FPGA_TEST_ASM=... for a
# different program. fpga-test-simple is a preset for test_uart_simple.asm
# (fire-and-forget, no AND+JZ poll — isolates whether the poll is broken).
FPGA_TEST_ASM ?= asm/test_fpga.asm
FPGA_TEST_STEM = $(basename $(notdir $(FPGA_TEST_ASM)))

fpga-test: $(FPGA_TEST_ASM) asm/mcasm.py | $(BUILD_DIR)
	$(MCASM) $(FPGA_TEST_ASM) -o $(BUILD_DIR)/$(FPGA_TEST_STEM).mem --verilog-init
	cp $(BUILD_DIR)/$(FPGA_TEST_STEM).mem $(BUILD_DIR)/forth.mem
	cp $(BUILD_DIR)/$(FPGA_TEST_STEM).vh  $(BUILD_DIR)/forth_init.vh
	@touch $(BUILD_DIR)/forth.ram
	yosys -p "read_verilog -sv -DFPGA_BUILD -DFPGA_INLINE_INIT \
		rtl/mc14500_fpga_test.v rtl/uart_tx.v rtl/mc14500_cpu.v rtl/mc14500_slice.v; \
		synth_gowin -top mc14500_fpga_test -json $(BUILD_DIR)/fpga_test.json"
	nextpnr-himbaechel --json $(BUILD_DIR)/fpga_test.json \
		--write $(BUILD_DIR)/fpga_test_pnr.json \
		--device $(FPGA_DEVICE) --vopt family=$(FPGA_FAMILY) --vopt cst=$(FPGA_CST)
	gowin_pack -d $(FPGA_FAMILY) -o $(BUILD_DIR)/fpga_test.fs $(BUILD_DIR)/fpga_test_pnr.json
	openFPGALoader -b $(FPGA_BOARD) $(BUILD_DIR)/fpga_test.fs

fpga-test-simple:
	$(MAKE) fpga-test FPGA_TEST_ASM=asm/test_uart_simple.asm

# --- UART module test (no CPU, just uart_tx sending "Hi!") ---
$(BUILD_DIR)/uart_test.json: rtl/uart_test.v rtl/uart_tx.v | $(BUILD_DIR)
	yosys -p "read_verilog -sv $^; synth_gowin -top uart_test -json $@"

$(BUILD_DIR)/uart_test_pnr.json: $(BUILD_DIR)/uart_test.json $(FPGA_CST)
	nextpnr-himbaechel --json $< --write $@ --device $(FPGA_DEVICE) \
		--vopt family=$(FPGA_FAMILY) --vopt cst=$(FPGA_CST)

$(BUILD_DIR)/uart_test.fs: $(BUILD_DIR)/uart_test_pnr.json
	gowin_pack -d $(FPGA_FAMILY) -o $@ $<

uart-test: $(BUILD_DIR)/uart_test.fs
	openFPGALoader -b $(FPGA_BOARD) $<

# --- LED test (diagnostic) ---
$(BUILD_DIR)/led_test.json: rtl/led_test.v | $(BUILD_DIR)
	yosys -p "read_verilog -sv $<; synth_gowin -top led_test -json $@"

$(BUILD_DIR)/led_test_pnr.json: $(BUILD_DIR)/led_test.json $(FPGA_CST)
	nextpnr-himbaechel --json $< --write $@ --device $(FPGA_DEVICE) \
		--vopt family=$(FPGA_FAMILY) --vopt cst=$(FPGA_CST)

$(BUILD_DIR)/led_test.fs: $(BUILD_DIR)/led_test_pnr.json
	gowin_pack -d $(FPGA_FAMILY) -o $@ $<

led-test: $(BUILD_DIR)/led_test.fs
	openFPGALoader -b $(FPGA_BOARD) $<

# --- Pure wire-level UART loopback: proves CH340 chain works ---
$(BUILD_DIR)/loopback_test.json: rtl/loopback_test.v | $(BUILD_DIR)
	yosys -p "read_verilog -sv $<; synth_gowin -top loopback_test -json $@"
$(BUILD_DIR)/loopback_test_pnr.json: $(BUILD_DIR)/loopback_test.json $(FPGA_CST)
	nextpnr-himbaechel --json $< --write $@ --device $(FPGA_DEVICE) \
		--vopt family=$(FPGA_FAMILY) --vopt cst=$(FPGA_CST)
$(BUILD_DIR)/loopback_test.fs: $(BUILD_DIR)/loopback_test_pnr.json
	gowin_pack -d $(FPGA_FAMILY) -o $@ $<

loopback-test: $(BUILD_DIR)/loopback_test.fs
	openFPGALoader -b $(FPGA_BOARD) $<

# --- UART TX test without any dependence on btn_rst_n ---
$(BUILD_DIR)/uart_test_noreset.json: rtl/uart_test_noreset.v rtl/uart_tx.v | $(BUILD_DIR)
	yosys -p "read_verilog -sv $^; synth_gowin -top uart_test_noreset -json $@"
$(BUILD_DIR)/uart_test_noreset_pnr.json: $(BUILD_DIR)/uart_test_noreset.json $(FPGA_CST)
	nextpnr-himbaechel --json $< --write $@ --device $(FPGA_DEVICE) \
		--vopt family=$(FPGA_FAMILY) --vopt cst=$(FPGA_CST)
$(BUILD_DIR)/uart_test_noreset.fs: $(BUILD_DIR)/uart_test_noreset_pnr.json
	gowin_pack -d $(FPGA_FAMILY) -o $@ $<

uart-test-noreset: $(BUILD_DIR)/uart_test_noreset.fs
	openFPGALoader -b $(FPGA_BOARD) $<

# --- Cleanup ---
clean:
	rm -rf $(BUILD_DIR)
