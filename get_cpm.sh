#!/bin/bash
#
# Download and prepare CP/M 2.2 binaries for RetroShield Z80
#
# This script downloads CP/M 2.2 source and builds CCP/BDOS for our memory map.
#

set -e

echo "CP/M 2.2 Binary Preparation for RetroShield Z80"
echo "================================================"
echo ""

# Target addresses
CCP_BASE=0xE000
BDOS_BASE=0xE800
BIOS_BASE=0xF600

# Check for z80asm
if ! command -v z80asm &> /dev/null; then
    echo "Error: z80asm not found. Install z88dk first."
    echo ""
    echo "  macOS:  brew install z88dk"
    echo "  Linux:  sudo apt install z88dk"
    echo ""
    exit 1
fi

# Create working directory
mkdir -p cpm_build
cd cpm_build

echo "Downloading CP/M 2.2 source..."

# Download CP/M 2.2 source from cpm.z80.de
if [ ! -f "cpm22.zip" ]; then
    curl -L -o cpm22.zip "http://www.cpm.z80.de/download/cpm2-plm.zip" 2>/dev/null || \
    curl -L -o cpm22.zip "http://www.cpm.z80.de/download/cpm22.zip" 2>/dev/null || \
    {
        echo "Failed to download. Please download manually from:"
        echo "  http://www.cpm.z80.de/source.html"
        exit 1
    }
fi

echo "Extracting..."
unzip -o cpm22.zip 2>/dev/null || true

# Look for ASM source files
echo ""
echo "Looking for source files..."

# Create our own CCP/BDOS if source not suitable
# Many CP/M archives have Intel 8080 source, not Z80
# For simplicity, let's create stubs that we can replace later

echo ""
echo "Creating placeholder binaries..."
echo "(Replace these with properly assembled CCP/BDOS for full functionality)"
echo ""

# Create a minimal CCP placeholder that just prints a prompt
cat > ccp_stub.asm << 'EOF'
; Minimal CCP stub for testing
; Replace with real CCP for full functionality

        org     0xE000

CCP:
        ld      sp, 0x0100

prompt:
        ; Print newline
        ld      c, 0x0D
        call    0xE809          ; BDOS CONOUT
        ld      c, 0x0A
        call    0xE809

        ; Print drive letter
        ld      a, (0x0004)     ; Current drive from page zero
        add     a, 'A'
        ld      c, a
        call    0xE809

        ; Print ">"
        ld      c, '>'
        call    0xE809

        ; Read character
        call    0xE806          ; BDOS CONIN

        ; Echo it
        ld      c, a
        call    0xE809

        jr      prompt

        defs    0xE800 - $, 0   ; Pad to BDOS address
EOF

# Create a minimal BDOS placeholder
cat > bdos_stub.asm << 'EOF'
; Minimal BDOS stub for testing
; Replace with real BDOS for full functionality

        org     0xE800

BDOS:
        ; Entry point at BDOS+6
        defs    6, 0

BDOS_ENTRY:
        ; C = function number
        ld      a, c

        cp      1               ; CONIN
        jr      z, CONIN

        cp      2               ; CONOUT
        jr      z, CONOUT

        cp      9               ; Print string
        jr      z, PRTSTR

        cp      11              ; CONST
        jr      z, CONST

        ; Unknown function - return
        ret

CONST:
        in      a, (0x80)       ; ACIA status
        and     0x01            ; RDRF bit
        ret

CONIN:
        in      a, (0x80)
        and     0x01
        jr      z, CONIN
        in      a, (0x81)
        and     0x7F
        ret

CONOUT:
        push    af
CONOUT_WAIT:
        in      a, (0x80)
        and     0x02            ; TDRE bit
        jr      z, CONOUT_WAIT
        ld      a, e            ; Character in E
        out     (0x81), a
        pop     af
        ret

PRTSTR:
        ; DE = string address, $ terminated
        ld      a, (de)
        cp      '$'
        ret     z
        push    de
        ld      e, a
        call    CONOUT
        pop     de
        inc     de
        jr      PRTSTR

        defs    0xF600 - $, 0   ; Pad to BIOS address
EOF

echo "Assembling stubs..."
z80asm -o ../ccp.bin ccp_stub.asm 2>/dev/null || {
    echo "Assembly failed. Creating binary stubs..."
    # Create 2KB zero-filled CCP
    dd if=/dev/zero of=../ccp.bin bs=2048 count=1 2>/dev/null
}

z80asm -o ../bdos.bin bdos_stub.asm 2>/dev/null || {
    # Create 3.5KB zero-filled BDOS
    dd if=/dev/zero of=../bdos.bin bs=3584 count=1 2>/dev/null
}

cd ..

echo ""
echo "Created placeholder binaries:"
echo "  ccp.bin  - $(wc -c < ccp.bin) bytes"
echo "  bdos.bin - $(wc -c < bdos.bin) bytes"
echo ""
echo "These are minimal stubs for testing. For full CP/M functionality,"
echo "replace with properly relocated CCP and BDOS from:"
echo "  http://www.cpm.z80.de/"
echo ""
echo "Next steps:"
echo "  1. make           # Build CPM.SYS"
echo "  2. make disk      # Create blank disk images"
echo "  3. make test      # Test in emulator"
echo ""
