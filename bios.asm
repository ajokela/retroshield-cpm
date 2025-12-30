;========================================================================
; CP/M 2.2 BIOS for RetroShield Z80
;
; Hardware:
;   Console: MC6850 ACIA at ports 0x80-0x81
;   Disk:    SD card at ports 0x10-0x18 (with DMA block transfers)
;
; Memory Map (62KB TPA):
;   0000-00FF   Page Zero (jump vectors, FCBs, command buffer)
;   0100-F1FF   TPA (Transient Program Area) - 61.75KB
;   F200-F9FF   CCP (Console Command Processor) - 2KB
;   FA00-FEFF   BDOS (Basic Disk Operating System) - 1.25KB approx
;   FF00-FFFF   BIOS (this code) - 256 bytes (minimal)
;
; For a smaller system (56KB TPA), use:
;   0100-DFFF   TPA
;   E000-E7FF   CCP
;   E800-F5FF   BDOS
;   F600-FFFF   BIOS
;
; Disk Format:
;   Single file per drive: A.DSK, B.DSK, C.DSK, D.DSK
;   128 bytes per sector (CP/M standard)
;   26 sectors per track
;   77 tracks per disk
;   = 256,256 bytes per disk image (~250KB)
;
; Copyright (c) 2025 Alex Jokela, tinycomputers.io
; MIT License
;========================================================================

;------------------------------------------------------------------------
; Configuration - adjust for your memory size
;------------------------------------------------------------------------

; For 56KB TPA (standard):
CCP_BASE:       equ     0xE000          ; CCP starts here
BDOS_BASE:      equ     0xE800          ; BDOS starts here
BIOS_BASE:      equ     0xF600          ; BIOS starts here

; Alternative: 62KB TPA (maximum):
; CCP_BASE:     equ     0xF200
; BDOS_BASE:    equ     0xFA00
; BIOS_BASE:    equ     0xFE00

;------------------------------------------------------------------------
; Hardware Port Definitions
;------------------------------------------------------------------------

; MC6850 ACIA (Console)
ACIA_CTRL:      equ     0x80            ; Control/Status register
ACIA_DATA:      equ     0x81            ; Data register
ACIA_RDRF:      equ     0x01            ; Receive Data Register Full
ACIA_TDRE:      equ     0x02            ; Transmit Data Register Empty

; SD Card
SD_CMD:         equ     0x10            ; Command register
SD_STATUS:      equ     0x11            ; Status register
SD_DATA:        equ     0x12            ; Data byte
SD_FNAME:       equ     0x13            ; Filename (write chars, then null)
SD_SEEK_LO:     equ     0x14            ; Seek position low byte
SD_SEEK_HI:     equ     0x15            ; Seek position middle byte
SD_SEEK_EX:     equ     0x19            ; Seek position high byte (bits 16-23)
SD_DMA_LO:      equ     0x16            ; DMA address low byte
SD_DMA_HI:      equ     0x17            ; DMA address high byte
SD_BLOCK:       equ     0x18            ; Block command: 0=read, 1=write

; SD Commands
CMD_OPEN_READ:  equ     0x01
CMD_CREATE:     equ     0x02
CMD_OPEN_RW:    equ     0x07
CMD_SEEK:       equ     0x08
CMD_CLOSE:      equ     0x05

; SD Status bits
SD_READY:       equ     0x01
SD_ERROR:       equ     0x02

;------------------------------------------------------------------------
; Disk Parameters
;------------------------------------------------------------------------

SECT_SIZE:      equ     128             ; Bytes per sector
SPT:            equ     26              ; Sectors per track
TRACKS:         equ     77              ; Tracks per disk
DSM:            equ     242             ; Disk size in blocks - 1 (1K blocks)
DRM:            equ     63              ; Directory entries - 1
OFF:            equ     2               ; Reserved tracks for system

NDISKS:         equ     4               ; Number of drives (A-D)

;------------------------------------------------------------------------
; BIOS Jump Table - must be at BIOS_BASE
;------------------------------------------------------------------------

                org     BIOS_BASE

                jp      BOOT            ; 00 - Cold boot
WBOOTE:         jp      WBOOT           ; 03 - Warm boot
                jp      CONST           ; 06 - Console status
                jp      CONIN           ; 09 - Console input
                jp      CONOUT          ; 0C - Console output
                jp      LIST            ; 0F - List output
                jp      PUNCH           ; 12 - Punch output
                jp      READER          ; 15 - Reader input
                jp      HOME            ; 18 - Home disk
                jp      SELDSK          ; 1B - Select disk
                jp      SETTRK          ; 1E - Set track
                jp      SETSEC          ; 21 - Set sector
                jp      SETDMA          ; 24 - Set DMA address
                jp      READ            ; 27 - Read sector
                jp      WRITE           ; 2A - Write sector
                jp      LISTST          ; 2D - List status
                jp      SECTRAN         ; 30 - Sector translate

;------------------------------------------------------------------------
; BOOT - Cold start
;------------------------------------------------------------------------
BOOT:
                ld      sp, CCP_BASE    ; Stack just below CCP (grows down into TPA)
                xor     a
                ld      (CDISK), a      ; Select disk A
                ld      (ITEFLAG), a    ; Clear flags

                ; Initialize disk variables
                ld      hl, 0
                ld      (TRACK), hl
                ld      (SECTOR), hl
                ld      (SEEKPOS), hl       ; Low 2 bytes
                xor     a
                ld      (SEEKPOS+2), a      ; High byte
                ld      hl, 0x0080
                ld      (DMAADR), hl

                ; Print boot message
                ld      hl, BOOTMSG
                call    PRTSTR

                jp      GOCPM           ; Jump to CP/M

;------------------------------------------------------------------------
; WBOOT - Warm start (reload CCP)
;------------------------------------------------------------------------
WBOOT:
                ld      sp, CCP_BASE    ; Stack just below CCP

                ; Open system file
                ld      hl, SYSFILE
                call    SD_SETNAME
                ld      a, CMD_OPEN_READ
                out     (SD_CMD), a

                ; Check status
                in      a, (SD_STATUS)
                and     SD_ERROR
                jr      nz, WBOOT_ERR

                ; Load CCP+BDOS (CCP is 2K, BDOS is ~3.5K, total ~6K = 48 sectors)
                ld      hl, CCP_BASE
                ld      b, 53           ; Sectors to load (53 * 128 = 6784 bytes)
WBOOT_LOOP:
                push    bc
                push    hl

                ; Set DMA address
                ld      a, l
                out     (SD_DMA_LO), a
                ld      a, h
                out     (SD_DMA_HI), a

                ; Read block
                xor     a
                out     (SD_BLOCK), a

                ; Check status
                in      a, (SD_BLOCK)
                or      a
                jr      nz, WBOOT_ERR2

                pop     hl
                ld      de, SECT_SIZE
                add     hl, de          ; Next DMA address
                pop     bc
                djnz    WBOOT_LOOP

                ; Close file
                ld      a, CMD_CLOSE
                out     (SD_CMD), a

                ; Fall through to GOCPM

;------------------------------------------------------------------------
; GOCPM - Initialize page zero and jump to CCP
;------------------------------------------------------------------------
GOCPM:
                ld      a, 0xC3         ; JP instruction
                ld      (0x0000), a
                ld      hl, WBOOTE
                ld      (0x0001), hl    ; Warm boot vector

                xor     a
                ld      (0x0003), a     ; IOBYTE

                ld      a, (CDISK)
                ld      (0x0004), a     ; Current disk (0=A, 1=B, etc)

                ld      a, 0xC3
                ld      (0x0005), a
                ld      hl, BDOS_BASE + 6
                ld      (0x0006), hl    ; BDOS entry vector

                ld      bc, 0x0080
                call    SETDMA          ; Default DMA

                ld      a, (CDISK)
                ld      c, a
                jp      CCP_BASE        ; Enter CCP

WBOOT_ERR:
                ld      hl, ERRMSG1
                call    PRTSTR
                halt

WBOOT_ERR2:
                pop     hl
                pop     bc
                ld      hl, ERRMSG2
                call    PRTSTR
                halt

;------------------------------------------------------------------------
; CONST - Console status
; Returns: A = 0xFF if character ready, 0x00 if not
;------------------------------------------------------------------------
CONST:
                in      a, (ACIA_CTRL)
                and     ACIA_RDRF
                ret     z               ; Return 0 if no char
                ld      a, 0xFF
                ret

;------------------------------------------------------------------------
; CONIN - Console input (wait for character)
; Returns: A = character
;------------------------------------------------------------------------
CONIN:
                in      a, (ACIA_CTRL)
                and     ACIA_RDRF
                jr      z, CONIN        ; Wait for character
                in      a, (ACIA_DATA)
                and     0x7F            ; Strip parity
                ret

;------------------------------------------------------------------------
; CONOUT - Console output
; Entry: C = character to output
;------------------------------------------------------------------------
CONOUT:
                ; Simple output - no TDRE check needed in emulator
                ld      a, c
                out     (ACIA_DATA), a
                ret

;------------------------------------------------------------------------
; LIST - List (printer) output
; Entry: C = character
;------------------------------------------------------------------------
LIST:
                ret                     ; Not implemented

;------------------------------------------------------------------------
; PUNCH - Punch output
; Entry: C = character
;------------------------------------------------------------------------
PUNCH:
                ret                     ; Not implemented

;------------------------------------------------------------------------
; READER - Reader input
; Returns: A = character (0x1A = EOF)
;------------------------------------------------------------------------
READER:
                ld      a, 0x1A         ; Return EOF
                ret

;------------------------------------------------------------------------
; LISTST - List status
; Returns: A = 0xFF if ready, 0x00 if not
;------------------------------------------------------------------------
LISTST:
                xor     a               ; Not ready
                ret

;------------------------------------------------------------------------
; HOME - Home selected disk (track 0)
;------------------------------------------------------------------------
HOME:
                ld      bc, 0
                ; Fall through to SETTRK

;------------------------------------------------------------------------
; SETTRK - Set track number
; Entry: BC = track number
;------------------------------------------------------------------------
SETTRK:
                ld      (TRACK), bc
                ret

;------------------------------------------------------------------------
; SETSEC - Set sector number
; Entry: BC = sector number (1-based from SECTRAN, or 0-based raw)
;------------------------------------------------------------------------
SETSEC:
                ld      (SECTOR), bc
                ret

;------------------------------------------------------------------------
; SETDMA - Set DMA address for disk operations
; Entry: BC = DMA address
;------------------------------------------------------------------------
SETDMA:
                ld      (DMAADR), bc
                ret

;------------------------------------------------------------------------
; SELDSK - Select disk
; Entry: C = disk number (0=A, 1=B, etc.)
;        E = 0 if first select, non-zero if already logged in
; Returns: HL = DPH address, or 0 if invalid disk
;------------------------------------------------------------------------
SELDSK:
                ld      a, c
                cp      NDISKS
                jr      nc, SELDSK_ERR  ; Invalid disk

                ld      (CDISK), a

                ; Calculate DPH address: DPH0 + (disk * 16)
                ld      l, c
                ld      h, 0
                add     hl, hl          ; *2
                add     hl, hl          ; *4
                add     hl, hl          ; *8
                add     hl, hl          ; *16
                ld      de, DPH0
                add     hl, de

                ; Open disk image file (preserve HL = DPH address)
                push    hl
                call    OPENDISK
                pop     hl              ; Restore DPH address for return
                ret

SELDSK_ERR:
                ld      hl, 0
                ret

;------------------------------------------------------------------------
; SECTRAN - Translate sector number (logical to physical)
; Entry: BC = logical sector, DE = translate table address
; Returns: HL = physical sector
;------------------------------------------------------------------------
SECTRAN:
                ; No translation (1:1 mapping)
                ld      h, b
                ld      l, c
                ret

;------------------------------------------------------------------------
; READ - Read one sector
; Returns: A = 0 if OK, 1 if error
;------------------------------------------------------------------------
READ:
                call    CALC_OFFSET     ; Calculate file offset
                call    SD_SEEK         ; Seek to position

                ; Set DMA address
                ld      hl, (DMAADR)
                ld      a, l
                out     (SD_DMA_LO), a
                ld      a, h
                out     (SD_DMA_HI), a

                ; Issue block read
                xor     a
                out     (SD_BLOCK), a

                ; Check status
                in      a, (SD_BLOCK)
                ret                     ; Return status (0=OK)

;------------------------------------------------------------------------
; WRITE - Write one sector
; Entry: C = write type (0=normal, 1=directory, 2=first block of new file)
; Returns: A = 0 if OK, 1 if error
;------------------------------------------------------------------------
WRITE:
                push    bc              ; Save write type
                call    CALC_OFFSET
                call    SD_SEEK

                ; Set DMA address
                ld      hl, (DMAADR)
                ld      a, l
                out     (SD_DMA_LO), a
                ld      a, h
                out     (SD_DMA_HI), a

                ; Issue block write
                ld      a, 1
                out     (SD_BLOCK), a

                ; Check status
                in      a, (SD_BLOCK)
                pop     bc
                ret

;------------------------------------------------------------------------
; CALC_OFFSET - Calculate byte offset in disk image
; Uses: TRACK, SECTOR
; Returns: offset in SEEKPOS (24-bit for full disk support)
;------------------------------------------------------------------------
CALC_OFFSET:
                ; offset = (track * SPT + sector) * 128
                ; Result can be up to 256,256 bytes (requires 18 bits)

                ld      hl, (TRACK)
                ld      de, SPT
                call    MULT16          ; HL = track * SPT (max 77*26=2002)

                ld      de, (SECTOR)
                add     hl, de          ; HL = track * SPT + sector (max 2027)

                ; Multiply by 128 (shift left 7 times)
                ; Use A as high byte for overflow
                xor     a               ; Clear high byte
                add     hl, hl          ; *2
                adc     a, 0            ; Carry to A
                add     hl, hl          ; *4
                adc     a, a            ; Carry to A
                add     hl, hl          ; *8
                adc     a, a
                add     hl, hl          ; *16
                adc     a, a
                add     hl, hl          ; *32
                adc     a, a
                add     hl, hl          ; *64
                adc     a, a
                add     hl, hl          ; *128
                adc     a, a

                ld      (SEEKPOS), hl
                ld      (SEEKPOS+2), a
                ret

;------------------------------------------------------------------------
; MULT16 - 16x16 multiply (only low 16 bits)
; Entry: HL = multiplicand, DE = multiplier
; Returns: HL = product (low 16 bits)
;------------------------------------------------------------------------
MULT16:
                ld      b, h
                ld      c, l
                ld      hl, 0
MULT_LOOP:
                ld      a, d
                or      e
                ret     z               ; Done if DE = 0
                srl     d
                rr      e               ; DE = DE >> 1
                jr      nc, MULT_NOADD
                add     hl, bc          ; Add if carry
MULT_NOADD:
                sla     c
                rl      b               ; BC = BC << 1
                jr      MULT_LOOP

;------------------------------------------------------------------------
; SD_SEEK - Seek to position in SEEKPOS (24-bit)
;------------------------------------------------------------------------
SD_SEEK:
                ld      hl, (SEEKPOS)
                ld      a, l
                out     (SD_SEEK_LO), a
                ld      a, h
                out     (SD_SEEK_HI), a
                ld      a, (SEEKPOS+2)
                out     (SD_SEEK_EX), a
                ld      a, CMD_SEEK
                out     (SD_CMD), a
                ret

;------------------------------------------------------------------------
; SD_SETNAME - Send filename to SD card
; Entry: HL = pointer to null-terminated filename
;------------------------------------------------------------------------
SD_SETNAME:
                ld      a, (hl)
                out     (SD_FNAME), a
                or      a
                ret     z               ; Done on null
                inc     hl
                jr      SD_SETNAME

;------------------------------------------------------------------------
; OPENDISK - Open disk image file for current drive
;------------------------------------------------------------------------
OPENDISK:
                ; Build filename: "A.DSK" for drive 0, etc.
                ld      a, (CDISK)
                add     a, 'A'
                ld      (DSKNAME), a

                ; Send filename
                ld      hl, DSKNAME
                call    SD_SETNAME

                ; Open for read/write
                ld      a, CMD_OPEN_RW
                out     (SD_CMD), a

                ; Check status
                in      a, (SD_STATUS)
                and     SD_ERROR
                ret     z               ; OK

                ; If error, try creating the file
                ld      hl, DSKNAME
                call    SD_SETNAME
                ld      a, CMD_CREATE
                out     (SD_CMD), a
                ret

;------------------------------------------------------------------------
; PRTSTR - Print null-terminated string
; Entry: HL = string address
;------------------------------------------------------------------------
PRTSTR:
                ld      a, (hl)
                or      a
                ret     z
                push    hl
                ld      c, a
                call    CONOUT
                pop     hl
                inc     hl
                jr      PRTSTR

;------------------------------------------------------------------------
; Data Area
;------------------------------------------------------------------------

BOOTMSG:        defb    13, 10
                defb    "RetroShield CP/M 2.2", 13, 10
                defb    "56K TPA", 13, 10, 0

ERRMSG1:        defb    "Boot error: Cannot open CPM.SYS", 13, 10, 0
ERRMSG2:        defb    "Boot error: Read failed", 13, 10, 0

SYSFILE:        defb    "CPM.SYS", 0
DSKNAME:        defb    "A.DSK", 0

;------------------------------------------------------------------------
; Variables (in RAM above BIOS, or use reserved space)
;------------------------------------------------------------------------

CDISK:          defb    0               ; Current disk
TRACK:          defw    0               ; Current track
SECTOR:         defw    0               ; Current sector
DMAADR:         defw    0x0080          ; DMA address
SEEKPOS:        defb    0, 0, 0         ; File seek position (24-bit)
ITEFLAG:        defb    0               ; Interleave flag

;------------------------------------------------------------------------
; Disk Parameter Headers (DPH) - one per drive
; Each DPH is 16 bytes
;------------------------------------------------------------------------

DPH0:           ; Drive A
                defw    0               ; XLT - sector translate table (0=none)
                defw    0, 0, 0         ; Scratch area
                defw    DIRBUF          ; DIRBUF - directory buffer
                defw    DPB             ; DPB - disk parameter block
                defw    CSV0            ; CSV - checksum vector
                defw    ALV0            ; ALV - allocation vector

DPH1:           ; Drive B
                defw    0
                defw    0, 0, 0
                defw    DIRBUF
                defw    DPB
                defw    CSV1
                defw    ALV1

DPH2:           ; Drive C
                defw    0
                defw    0, 0, 0
                defw    DIRBUF
                defw    DPB
                defw    CSV2
                defw    ALV2

DPH3:           ; Drive D
                defw    0
                defw    0, 0, 0
                defw    DIRBUF
                defw    DPB
                defw    CSV3
                defw    ALV3

;------------------------------------------------------------------------
; Disk Parameter Block (DPB) - shared by all drives
; 8" SS/SD format: 77 tracks, 26 sectors/track, 128 bytes/sector
;------------------------------------------------------------------------

DPB:
                defw    SPT             ; SPT - sectors per track (26)
                defb    3               ; BSH - block shift (1K blocks)
                defb    7               ; BLM - block mask
                defb    0               ; EXM - extent mask
                defw    DSM             ; DSM - disk size in blocks - 1 (242)
                defw    DRM             ; DRM - directory entries - 1 (63)
                defb    0xC0            ; AL0 - allocation bitmap
                defb    0x00            ; AL1
                defw    16              ; CKS - checksum size (DRM+1)/4
                defw    OFF             ; OFF - reserved tracks (2)

;------------------------------------------------------------------------
; Buffers and Vectors
;------------------------------------------------------------------------

; Directory buffer (shared) - 128 bytes
DIRBUF:
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; Checksum vectors (16 bytes each for 64 directory entries)
CSV0:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
CSV1:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
CSV2:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
CSV3:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; Allocation vectors ((DSM/8)+1 = 31 bytes each)
ALV0:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
ALV1:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
ALV2:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
ALV3:           defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                defb    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

;------------------------------------------------------------------------
; End of BIOS
;------------------------------------------------------------------------

BIOS_END:       equ     $

                end
