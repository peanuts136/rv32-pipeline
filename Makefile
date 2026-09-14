VERILATOR ?= verilator

CORE_BUILD   := build/core
PHASE1_BUILD := build/phase1
PHASE1_TRACE := build/phase1_trace

.PHONY: lint lint_phase1 test phase1 phase1_waves clean

#Check the synthesizable processor RTL.
lint:
	$(VERILATOR) --lint-only --sv --Wall -Wno-fatal \
		--top-module rv32_core \
		-f rtl.f

#Check the core and Phase 1 testbench together.
lint_phase1:
	$(VERILATOR) --lint-only --timing --sv --Wall -Wno-fatal \
		--top-module rv32_phase1_tb \
		-f rtl.f \
		tb/core/rv32_phase1_tb.sv

#Run the smaller test
test:
	mkdir -p $(CORE_BUILD)
	$(VERILATOR) --binary --timing --sv --Wall -Wno-fatal \
		--top-module rv32_core_tb \
		-f rtl.f \
		tb/core/rv32_core_tb.sv \
		--Mdir $(CORE_BUILD)
	./$(CORE_BUILD)/Vrv32_core_tb

#Run the comprehensive Phase 1 test
phase1:
	mkdir -p $(PHASE1_BUILD)
	$(VERILATOR) --binary --timing --sv --Wall -Wno-fatal \
		--top-module rv32_phase1_tb \
		-f rtl.f \
		tb/core/rv32_phase1_tb.sv \
		--Mdir $(PHASE1_BUILD)
	./$(PHASE1_BUILD)/Vrv32_phase1_tb

# Run Phase 1 and generate a VCD waveform
phase1_waves:
	mkdir -p $(PHASE1_BUILD) $(PHASE1_TRACE)
	$(VERILATOR) --binary --timing --trace --sv --Wall -Wno-fatal \
		--top-module rv32_phase1_tb \
		-f rtl.f \
		tb/core/rv32_phase1_tb.sv \
		--Mdir $(PHASE1_TRACE)
	./$(PHASE1_TRACE)/Vrv32_phase1_tb +trace

clean:
	rm -rf build