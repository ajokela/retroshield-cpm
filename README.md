# CP/M 2.2 for RetroShield Z80

This directory contains the BIOS and boot loader for running CP/M 2.2 on the RetroShield Z80.

## Quick Start

1. Obtain CP/M 2.2 CCP and BDOS binaries (see below)
2. Build the system: `make`
3. Create disk images: `make disk`
4. Test in emulator: `make test`

## Memory Map

```
0000-00FF   Page Zero (jump vectors, FCBs, command buffer)
0100-DFFF   TPA (Transient Program Area) - 56KB
E000-E7FF   CCP (Console Command Processor)
E800-F5FF   BDOS (Basic Disk Operating System)
F600-FFFF   BIOS (this code)
```

## Hardware

| Component | Port(s) | Description |
|-----------|---------|-------------|
| Console | 0x80-0x81 | MC6850 ACIA serial |
| Disk | 0x10-0x18 | SD card with DMA |

## Disk Format

- **Sectors per track**: 26
- **Bytes per sector**: 128
- **Tracks per disk**: 77
- **Total capacity**: 256,256 bytes (~250KB)
- **Reserved tracks**: 2 (for system)
- **Directory entries**: 64
- **Block size**: 1KB

Disk images are stored as raw files on the SD card:
- `A.DSK`, `B.DSK`, `C.DSK`, `D.DSK`

## Files

| File | Description |
|------|-------------|
| `boot.asm` | Boot loader (runs from ROM at 0x0000) |
| `bios.asm` | CP/M BIOS for RetroShield hardware |
| `Makefile` | Build system |

## Building

### Prerequisites

- **z80asm**: Z80 assembler from z88dk or similar
- **CCP and BDOS binaries**: See "Obtaining CP/M" below

### Build Commands

```bash
# Build boot loader and BIOS
make

# Create blank disk images
make disk

# Test in Rust emulator
make test

# Show memory map
make map
```

## Obtaining CP/M

CP/M 2.2 was released to public domain by Lineo (successors to Digital Research). You need CCP and BDOS binaries relocated to the correct addresses.

### Option 1: Pre-built Binaries

Download from the [Unofficial CP/M Website](http://www.cpm.z80.de/):
- Look for "CP/M 2.2 source and binaries"
- You'll need to relocate to CCP=0xE000, BDOS=0xE800

### Option 2: Build from Source

1. Get CP/M 2.2 source from [cpm.z80.de](http://www.cpm.z80.de/)
2. Modify the base addresses:
   - CCP: Change `ORG` to 0xE000
   - BDOS: Change `ORG` to 0xE800
3. Assemble with z80asm

### Option 3: Use the Included Script

```bash
# Download and build CP/M binaries
./get_cpm.sh
```

## Creating CPM.SYS

The `CPM.SYS` file contains CCP + BDOS + BIOS concatenated:

```
Offset      Size    Content
0x0000      2048    CCP (Console Command Processor)
0x0800      3584    BDOS (Basic Disk Operating System)
0x1600      var     BIOS (this code)
```

The Makefile handles this automatically when you run `make`.

## SD Card Setup

1. Format SD card as FAT32
2. Copy files to root directory:
   - `CPM.SYS` - CP/M system (required)
   - `A.DSK` - Drive A disk image
   - `B.DSK` - Drive B disk image (optional)
   - etc.

## Testing in Emulator

The Rust emulator supports all the I/O ports used by CP/M:

```bash
# Build emulator (if needed)
cd ../emulator/rust
cargo build --release

# Run CP/M
make test
```

You should see:
```
RetroShield Z80 Boot Loader
Copyright (c) 2024 tinycomputers.io

Loading CPM.SYS................................................
Boot complete.

RetroShield CP/M 2.2
56K TPA

A>
```

## BIOS Entry Points

| Offset | Name | Description |
|--------|------|-------------|
| 0x00 | BOOT | Cold start |
| 0x03 | WBOOT | Warm start |
| 0x06 | CONST | Console status |
| 0x09 | CONIN | Console input |
| 0x0C | CONOUT | Console output |
| 0x0F | LIST | Printer output |
| 0x12 | PUNCH | Punch output |
| 0x15 | READER | Reader input |
| 0x18 | HOME | Home disk head |
| 0x1B | SELDSK | Select disk |
| 0x1E | SETTRK | Set track |
| 0x21 | SETSEC | Set sector |
| 0x24 | SETDMA | Set DMA address |
| 0x27 | READ | Read sector |
| 0x2A | WRITE | Write sector |
| 0x2D | LISTST | Printer status |
| 0x30 | SECTRAN | Sector translate |

## Troubleshooting

### "CPM.SYS not found"
- Ensure CPM.SYS is in the SD card root directory
- Check SD card is properly formatted (FAT32)

### "Read failed"
- Check SD card connection
- Verify CPM.SYS file is not corrupted

### Disk errors at A> prompt
- Ensure A.DSK exists and is the correct size (256,256 bytes)
- Disk images must be properly formatted (or blank)

### System hangs
- Check serial connection (115200 baud, 8N1)
- Verify memory map matches your configuration

## Creating Bootable Disk Images

To copy files to CP/M disk images, use cpmtools:

```bash
# Install cpmtools
brew install cpmtools  # macOS
apt install cpmtools   # Linux

# Create disk definition file
cat > retroshield.def << 'EOF'
diskdef retroshield
  seclen 128
  tracks 77
  sectrk 26
  blocksize 1024
  maxdir 64
  skew 0
  boottrk 2
  os 2.2
end
EOF

# Copy file to disk image
cpmcp -f retroshield A.DSK local_file.txt 0:FILE.TXT

# List files on disk
cpmls -f retroshield A.DSK

# Extract file from disk
cpmcp -f retroshield A.DSK 0:FILE.TXT extracted.txt
```

## License

- BIOS and boot loader: MIT License
- CP/M 2.2 CCP/BDOS: Public Domain (Lineo/Caldera)
