# CP/M 2.2 for RetroShield Z80

This directory contains everything needed to run CP/M 2.2 on the RetroShield Z80 - both in the Rust emulator and on **physical hardware** using an Arduino Mega with the KDRAM2560 DRAM shield.

## Quick Start (Physical Hardware)

### Hardware Required

- Arduino Mega 2560
- [Z80 RetroShield](https://www.8bitforce.com/projects/retroshield/)
- [KDRAM2560](https://gitlab.com/8bitforce/kdram2560) (1MB DRAM shield)
- MicroSD card module (wired to pins 4-7 for software SPI)
- MicroSD card (≤32GB, FAT32 formatted)

### Setup

1. Install Arduino libraries:
   - [KDRAM2560](https://gitlab.com/8bitforce/kdram2560) - clone to Arduino libraries folder
   - [SdFat](https://github.com/greiman/SdFat) - install via Library Manager
   - **Important**: Set `SPI_DRIVER_SELECT` to `2` in `SdFat/src/SdFatConfig.h`

2. Wire the MicroSD module:
   | MicroSD Pin | Arduino Pin |
   |-------------|-------------|
   | MISO | 4 |
   | MOSI | 5 |
   | SCK | 6 |
   | CS | 7 |
   | VCC | 5V |
   | GND | GND |

3. Copy files to SD card:
   - `boot.bin` - Boot loader
   - `CPM.SYS` - CP/M system
   - `A.DSK`, `B.DSK` - Disk images (create with `cpm_disk.py`)

4. Upload `kz80_cpm.ino` to Arduino Mega

5. Open Serial Monitor at 115200 baud

### Quick Start (Emulator)

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
| `kz80_cpm.ino` | Arduino sketch for physical hardware |
| `boot.asm` | Boot loader source (runs from 0x0000) |
| `boot.bin` | Assembled boot loader |
| `bios.asm` | CP/M BIOS source for RetroShield |
| `CPM.SYS` | Combined CCP + BDOS + BIOS system file |
| `cpm_disk.py` | Python tool for managing disk images |
| `Makefile` | Build system for Z80 assembly |

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

## Disk Image Tool (cpm_disk.py)

A Python tool for creating and managing CP/M disk images:

```bash
# Create an empty disk image
python3 cpm_disk.py create A.DSK

# List files on a disk
python3 cpm_disk.py list A.DSK

# Add a file to a disk
python3 cpm_disk.py add A.DSK PROGRAM.COM

# Extract a file from a disk
python3 cpm_disk.py extract A.DSK PROGRAM.COM
```

### Adding Classic Software (Zork, etc.)

```bash
# Clone the CP/M software collection
git clone https://github.com/skx/cpm-dist.git software/cpm-dist

# Add Zork to A.DSK
python3 cpm_disk.py add A.DSK software/cpm-dist/G/ZORK1.COM
python3 cpm_disk.py add A.DSK software/cpm-dist/G/ZORK1.DAT
python3 cpm_disk.py add A.DSK software/cpm-dist/G/ZORK2.COM
python3 cpm_disk.py add A.DSK software/cpm-dist/G/ZORK2.DAT

# Add Hitchhiker's Guide to B.DSK
python3 cpm_disk.py add B.DSK software/cpm-dist/G/HITCH.COM
python3 cpm_disk.py add B.DSK software/cpm-dist/G/HITCHHIK.DAT
```

## Creating Bootable Disk Images (Alternative: cpmtools)

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
