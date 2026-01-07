#!/usr/bin/env python3
"""
CP/M Disk Image Tool for RetroShield Z80

Creates and manages CP/M 2.2 disk images compatible with the RetroShield
Z80 emulator and physical hardware.

Disk Format (256KB):
  - Total size: 262,144 bytes (256KB)
  - Block size: 1KB (1024 bytes)
  - Sectors per track: 26
  - Tracks: 77
  - Bytes per sector: 128
  - Reserved tracks: 2 (for system)
  - Directory entries: 64
  - Directory offset: 6656 bytes (0x1A00)
  - Data area start: 8704 bytes (0x2200)

Directory Entry Format (32 bytes):
  Byte 0:      User number (0-15 valid, 0xE5 = deleted/empty)
  Bytes 1-8:   Filename (space-padded ASCII)
  Bytes 9-11:  Extension (space-padded ASCII)
  Byte 12:     Extent number (low byte)
  Byte 13:     Reserved
  Byte 14:     Extent number (high byte)
  Byte 15:     Record count (number of 128-byte records in this extent)
  Bytes 16-31: Block allocation map (16 block numbers)

Usage:
  python3 cpm_disk.py create A.DSK           # Create empty disk
  python3 cpm_disk.py list A.DSK             # List files on disk
  python3 cpm_disk.py add A.DSK file.com     # Add file to disk
  python3 cpm_disk.py extract A.DSK file.com # Extract file from disk

Copyright (c) 2025 Alex Jokela, tinycomputers.io
MIT License
"""

import sys
import os
import struct

# Disk geometry constants
DISK_SIZE = 256 * 1024      # 256KB total
SECTOR_SIZE = 128           # CP/M sector size
SECTORS_PER_TRACK = 26
TRACKS = 77
RESERVED_TRACKS = 2         # System tracks
BLOCK_SIZE = 1024           # 1KB blocks
DIR_ENTRIES = 64
ENTRY_SIZE = 32

# Calculated offsets
DIR_OFFSET = RESERVED_TRACKS * SECTORS_PER_TRACK * SECTOR_SIZE  # 6656 = 0x1A00
DATA_OFFSET = DIR_OFFSET + (DIR_ENTRIES * ENTRY_SIZE)           # 8704 = 0x2200
TOTAL_BLOCKS = (DISK_SIZE - DATA_OFFSET) // BLOCK_SIZE          # ~247 usable blocks

# Directory entry constants
EMPTY_ENTRY = 0xE5


def create_disk(filename):
    """Create an empty, properly formatted CP/M disk image."""
    disk = bytearray(DISK_SIZE)

    # Initialize all directory entries as empty (0xE5)
    for i in range(DIR_ENTRIES):
        offset = DIR_OFFSET + (i * ENTRY_SIZE)
        disk[offset] = EMPTY_ENTRY

    with open(filename, 'wb') as f:
        f.write(disk)

    print(f"Created {filename}")
    print(f"  Size: {DISK_SIZE} bytes ({DISK_SIZE // 1024}KB)")
    print(f"  Directory at: 0x{DIR_OFFSET:04X} ({DIR_OFFSET} bytes)")
    print(f"  Data area at: 0x{DATA_OFFSET:04X} ({DATA_OFFSET} bytes)")
    print(f"  Directory entries: {DIR_ENTRIES}")
    print(f"  Usable blocks: {TOTAL_BLOCKS}")


def list_disk(filename):
    """List files on a CP/M disk image."""
    with open(filename, 'rb') as f:
        disk = f.read()

    files = {}

    for i in range(DIR_ENTRIES):
        offset = DIR_OFFSET + (i * ENTRY_SIZE)
        entry = disk[offset:offset + ENTRY_SIZE]

        user = entry[0]
        if user == EMPTY_ENTRY or user > 15:
            continue

        # Extract filename and extension
        name = bytes(entry[1:9]).decode('ascii', errors='replace').rstrip()
        ext = bytes(entry[9:12]).decode('ascii', errors='replace').rstrip()
        extent = entry[12] + (entry[14] << 5)
        records = entry[15]

        fullname = f"{name}.{ext}" if ext else name
        key = (user, fullname)

        if key not in files:
            files[key] = {'extents': 0, 'records': 0, 'blocks': []}

        files[key]['extents'] += 1
        files[key]['records'] += records

        # Collect block numbers
        for b in range(16):
            block = entry[16 + b]
            if block > 0:
                files[key]['blocks'].append(block)

    if not files:
        print(f"No files on {filename}")
        return

    print(f"Directory of {filename}:")
    print("-" * 50)
    print(f"{'User':<5} {'Filename':<12} {'Size':<10} {'Blocks'}")
    print("-" * 50)

    total_size = 0
    for (user, name), info in sorted(files.items()):
        size = info['records'] * SECTOR_SIZE
        total_size += size
        blocks = len(info['blocks'])
        print(f"{user:<5} {name:<12} {size:>6} bytes  {blocks} blocks")

    print("-" * 50)
    print(f"Total: {len(files)} file(s), {total_size} bytes")
    free_blocks = TOTAL_BLOCKS - sum(len(f['blocks']) for f in files.values())
    print(f"Free: {free_blocks * BLOCK_SIZE // 1024}KB ({free_blocks} blocks)")


def find_free_blocks(disk, count):
    """Find 'count' free blocks on the disk."""
    used = set()

    # Scan directory for used blocks
    for i in range(DIR_ENTRIES):
        offset = DIR_OFFSET + (i * ENTRY_SIZE)
        entry = disk[offset:offset + ENTRY_SIZE]

        if entry[0] != EMPTY_ENTRY and entry[0] <= 15:
            for b in range(16):
                block = entry[16 + b]
                if block > 0:
                    used.add(block)

    # Find free blocks (blocks 0 and 1 are reserved for directory)
    free = []
    for b in range(2, TOTAL_BLOCKS):
        if b not in used:
            free.append(b)
            if len(free) >= count:
                break

    return free


def find_free_dir_entry(disk):
    """Find a free directory entry."""
    for i in range(DIR_ENTRIES):
        offset = DIR_OFFSET + (i * ENTRY_SIZE)
        if disk[offset] == EMPTY_ENTRY:
            return i
    return None


def add_file(diskname, filename):
    """Add a file to the CP/M disk image."""
    # Read the file to add
    with open(filename, 'rb') as f:
        data = f.read()

    # Read the disk
    with open(diskname, 'rb') as f:
        disk = bytearray(f.read())

    # Parse filename (convert to CP/M 8.3 format)
    basename = os.path.basename(filename).upper()
    if '.' in basename:
        name, ext = basename.rsplit('.', 1)
    else:
        name, ext = basename, ''

    name = name[:8].ljust(8)
    ext = ext[:3].ljust(3)

    # Calculate blocks needed
    records = (len(data) + SECTOR_SIZE - 1) // SECTOR_SIZE
    blocks_needed = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE

    # Find free blocks
    free_blocks = find_free_blocks(disk, blocks_needed)
    if len(free_blocks) < blocks_needed:
        print(f"Error: Not enough space. Need {blocks_needed} blocks, have {len(free_blocks)}")
        return False

    # Write data to blocks
    for i, block in enumerate(free_blocks):
        block_offset = DATA_OFFSET + (block - 2) * BLOCK_SIZE
        start = i * BLOCK_SIZE
        end = min(start + BLOCK_SIZE, len(data))
        chunk = data[start:end]

        # Pad with 0x1A (CP/M EOF) if needed
        if len(chunk) < BLOCK_SIZE:
            chunk = chunk + bytes([0x1A] * (BLOCK_SIZE - len(chunk)))

        disk[block_offset:block_offset + BLOCK_SIZE] = chunk

    # Create directory entries (max 16 blocks per extent)
    extent = 0
    block_idx = 0

    while block_idx < len(free_blocks):
        dir_idx = find_free_dir_entry(disk)
        if dir_idx is None:
            print("Error: No free directory entries")
            return False

        offset = DIR_OFFSET + (dir_idx * ENTRY_SIZE)

        # Build directory entry
        entry = bytearray(ENTRY_SIZE)
        entry[0] = 0                    # User 0
        entry[1:9] = name.encode()      # Filename
        entry[9:12] = ext.encode()      # Extension
        entry[12] = extent & 0x1F       # Extent low
        entry[13] = 0                   # Reserved
        entry[14] = (extent >> 5) & 0x3F  # Extent high

        # Block allocation
        extent_blocks = free_blocks[block_idx:block_idx + 16]
        records_in_extent = min(records - (extent * 128), 128)
        entry[15] = records_in_extent   # Record count

        for j, blk in enumerate(extent_blocks):
            entry[16 + j] = blk

        disk[offset:offset + ENTRY_SIZE] = entry

        block_idx += 16
        extent += 1

    # Write disk back
    with open(diskname, 'wb') as f:
        f.write(disk)

    print(f"Added {basename} to {diskname}")
    print(f"  Size: {len(data)} bytes ({records} records, {blocks_needed} blocks)")
    return True


def extract_file(diskname, filename):
    """Extract a file from the CP/M disk image."""
    with open(diskname, 'rb') as f:
        disk = f.read()

    # Parse requested filename
    target = filename.upper()
    if '.' in target:
        tname, text = target.rsplit('.', 1)
    else:
        tname, text = target, ''

    tname = tname[:8].ljust(8)
    text = text[:3].ljust(3)

    # Find all extents for this file
    extents = []

    for i in range(DIR_ENTRIES):
        offset = DIR_OFFSET + (i * ENTRY_SIZE)
        entry = disk[offset:offset + ENTRY_SIZE]

        if entry[0] == EMPTY_ENTRY or entry[0] > 15:
            continue

        name = bytes(entry[1:9]).decode('ascii', errors='replace')
        ext = bytes(entry[9:12]).decode('ascii', errors='replace')

        if name == tname and ext == text:
            extent_num = entry[12] + (entry[14] << 5)
            records = entry[15]
            blocks = [entry[16 + b] for b in range(16) if entry[16 + b] > 0]
            extents.append((extent_num, records, blocks))

    if not extents:
        print(f"File not found: {filename}")
        return False

    # Sort by extent number and extract data
    extents.sort(key=lambda x: x[0])

    data = bytearray()
    for extent_num, records, blocks in extents:
        for block in blocks:
            block_offset = DATA_OFFSET + (block - 2) * BLOCK_SIZE
            data.extend(disk[block_offset:block_offset + BLOCK_SIZE])

    # Trim to actual size (based on record count from last extent)
    last_extent = extents[-1]
    total_records = (len(extents) - 1) * 128 + last_extent[1]
    data = data[:total_records * SECTOR_SIZE]

    # Remove trailing 0x1A (EOF markers)
    while data and data[-1] == 0x1A:
        data = data[:-1]

    # Write output file
    outname = filename.upper()
    with open(outname, 'wb') as f:
        f.write(data)

    print(f"Extracted {outname} ({len(data)} bytes)")
    return True


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        print("\nCommands:")
        print("  create <disk.dsk>              Create empty disk image")
        print("  list <disk.dsk>                List files on disk")
        print("  add <disk.dsk> <file>          Add file to disk")
        print("  extract <disk.dsk> <file>      Extract file from disk")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    diskname = sys.argv[2]

    if cmd == 'create':
        create_disk(diskname)
    elif cmd == 'list':
        list_disk(diskname)
    elif cmd == 'add':
        if len(sys.argv) < 4:
            print("Usage: cpm_disk.py add <disk.dsk> <file>")
            sys.exit(1)
        add_file(diskname, sys.argv[3])
    elif cmd == 'extract':
        if len(sys.argv) < 4:
            print("Usage: cpm_disk.py extract <disk.dsk> <file>")
            sys.exit(1)
        extract_file(diskname, sys.argv[3])
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == '__main__':
    main()
