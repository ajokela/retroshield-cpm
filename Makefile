# CP/M for RetroShield Z80 - Build System
#
# Prerequisites:
#   - z80asm (from z88dk or similar)
#   - CCP and BDOS binaries (see README.md for sources)

ASM = z80asm
ASMFLAGS =

# Memory configuration
CCP_BASE  = 0xE000
BDOS_BASE = 0xE800
BIOS_BASE = 0xF600

# Output files
BOOT_BIN = boot.bin
BIOS_BIN = bios.bin
CPM_SYS  = CPM.SYS

# Source files
BOOT_SRC = boot.asm
BIOS_SRC = bios.asm

# External binaries (download these - see README.md)
CCP_BIN  = ccp.bin
BDOS_BIN = bdos.bin

# Blank disk image size (77 tracks * 26 sectors * 128 bytes)
DISK_SIZE = 256256

.PHONY: all clean disk test

all: $(BOOT_BIN) $(CPM_SYS)

# Assemble boot loader
$(BOOT_BIN): $(BOOT_SRC)
	$(ASM) $(ASMFLAGS) -o $@ $<

# Assemble BIOS
$(BIOS_BIN): $(BIOS_SRC)
	$(ASM) $(ASMFLAGS) -o $@ $<

# Build CPM.SYS from CCP + BDOS + BIOS
# The file must be exactly: CCP (2048) + BDOS (3584) + BIOS (rest)
$(CPM_SYS): $(CCP_BIN) $(BDOS_BIN) $(BIOS_BIN)
	@echo "Building CPM.SYS..."
	@# Pad CCP to exactly 2048 bytes
	dd if=$(CCP_BIN) of=ccp_padded.bin bs=2048 count=1 conv=sync 2>/dev/null
	@# Pad BDOS to exactly 3584 bytes
	dd if=$(BDOS_BIN) of=bdos_padded.bin bs=3584 count=1 conv=sync 2>/dev/null
	@# Concatenate: CCP + BDOS + BIOS
	cat ccp_padded.bin bdos_padded.bin $(BIOS_BIN) > $(CPM_SYS)
	@rm -f ccp_padded.bin bdos_padded.bin
	@echo "Created $(CPM_SYS) ($(shell wc -c < $(CPM_SYS)) bytes)"

# Create blank disk images
disk: A.DSK B.DSK

A.DSK B.DSK:
	dd if=/dev/zero of=$@ bs=$(DISK_SIZE) count=1 2>/dev/null
	@echo "Created $@"

# Test in emulator (copy files to storage directory first)
test: $(BOOT_BIN) $(CPM_SYS) A.DSK
	@mkdir -p ../emulator/rust/storage
	cp $(CPM_SYS) ../emulator/rust/storage/
	cp A.DSK ../emulator/rust/storage/
	cd ../emulator/rust && cargo run --release -- -d $(CURDIR)/$(BOOT_BIN)

# Test boot loader only
test-boot: $(BOOT_BIN)
	cd ../emulator/rust && cargo run --release -- -d $(CURDIR)/$(BOOT_BIN)

clean:
	rm -f $(BOOT_BIN) $(BIOS_BIN) $(CPM_SYS)
	rm -f ccp_padded.bin bdos_padded.bin
	rm -f *.lst *.sym

# Download CP/M 2.2 binaries (from cpm.z80.de or similar)
download-cpm:
	@echo "Downloading CP/M 2.2 binaries..."
	@echo "Note: You may need to relocate these for your memory map"
	@echo ""
	@echo "Option 1: Use pre-built binaries from:"
	@echo "  http://www.cpm.z80.de/"
	@echo ""
	@echo "Option 2: Build from source using cpmtools"
	@echo ""
	@echo "The binaries must be relocated to:"
	@echo "  CCP:  $(CCP_BASE)"
	@echo "  BDOS: $(BDOS_BASE)"

# Show memory map
map:
	@echo "CP/M Memory Map for RetroShield Z80"
	@echo "===================================="
	@echo ""
	@echo "0000-00FF  Page Zero (vectors, FCBs)"
	@echo "0100-DFFF  TPA (Transient Program Area) - 56KB"
	@echo "E000-E7FF  CCP (Console Command Processor)"
	@echo "E800-F5FF  BDOS (Basic Disk Operating System)"
	@echo "F600-FFFF  BIOS (RetroShield custom)"
	@echo ""
	@echo "Disk Format: 8\" SS/SD"
	@echo "  77 tracks x 26 sectors x 128 bytes = 250KB"
	@echo ""
	@echo "Drives: A:, B:, C:, D: (as A.DSK, B.DSK, etc.)"
