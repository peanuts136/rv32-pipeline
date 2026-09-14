YOSYS          ?= yosys
NEXTPNR_ECP5   ?= nextpnr-ecp5
ECPPACK        ?= ecppack
OPENFPGALOADER ?= openFPGALoader

BUILD_DIR := build
TOP       := lattice_top
JSON      := $(BUILD_DIR)/$(TOP).json
CONFIG    := $(BUILD_DIR)/$(TOP).config
BIT       := $(BUILD_DIR)/$(TOP).bit

.PHONY: all program flash clean

all: $(BIT)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(JSON): fpga.f | $(BUILD_DIR)
	cd ../.. && $(YOSYS) -p 'read_slang --single-unit --top $(TOP) $(shell cat fpga.f); \
		synth_ecp5 -top $(TOP) -json fpga/ecp5/$(JSON)'

$(CONFIG): $(JSON) pins.lpf
	$(NEXTPNR_ECP5) --um5g-85k --package CABGA381 --speed 8 --freq 12 \
		--json $(JSON) --lpf pins.lpf --textcfg $(CONFIG)

$(BIT): $(CONFIG)
	$(ECPPACK) --compress $(CONFIG) $(BIT)

#Volatile programming, should dissapear at power off
program: $(BIT)
	$(OPENFPGALOADER) --board ecp5_evn $(BIT)

#Nonvolatile flash, should maintain programs after power off/on
flash: $(BIT)
	$(OPENFPGALOADER) --board ecp5_evn --write-flash $(BIT)

clean:
	rm -rf $(BUILD_DIR)
