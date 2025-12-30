;========================================================================
; CP/M Boot Loader for RetroShield Z80
;
; This code runs from ROM at 0x0000.
; It loads CPM.SYS from the SD card into memory and jumps to the BIOS.
;
; Copyright (c) 2025 Alex Jokela, tinycomputers.io
; MIT License
;========================================================================

;------------------------------------------------------------------------
; Configuration - must match bios.asm
;------------------------------------------------------------------------

CCP_BASE:       equ     0xE000
BIOS_BASE:      equ     0xF600
LOAD_SIZE:      equ     53              ; Sectors to load (53 * 128 = 6784 bytes)
SECT_SIZE:      equ     128

;------------------------------------------------------------------------
; Hardware Ports
;------------------------------------------------------------------------

ACIA_CTRL:      equ     0x80
ACIA_DATA:      equ     0x81
ACIA_TDRE:      equ     0x02

SD_CMD:         equ     0x10
SD_STATUS:      equ     0x11
SD_FNAME:       equ     0x13
SD_DMA_LO:      equ     0x16
SD_DMA_HI:      equ     0x17
SD_BLOCK:       equ     0x18

CMD_OPEN_READ:  equ     0x01
CMD_CLOSE:      equ     0x05
SD_ERROR:       equ     0x02

;------------------------------------------------------------------------
; Boot Code - starts at 0x0000
;------------------------------------------------------------------------

                org     0x0000

BOOT:
                di
                ld      sp, 0x0400          ; Stack above boot code (code is ~320 bytes)

                ; Initialize ACIA
                ld      a, 0x03
                out     (ACIA_CTRL), a
                ld      a, 0x15
                out     (ACIA_CTRL), a

                ; Print boot message
                ld      hl, MSG_BOOT
                call    PRINT_STR

                ; Open CPM.SYS
                ld      hl, FILENAME
                call    SD_SEND_NAME
                ld      a, CMD_OPEN_READ
                out     (SD_CMD), a

                ; Check for error
                in      a, (SD_STATUS)
                and     SD_ERROR
                jr      nz, BOOT_ERROR

                ; Print loading message
                ld      hl, MSG_LOAD
                call    PRINT_STR

                ; Load CP/M system to memory
                ld      hl, CCP_BASE
                ld      b, LOAD_SIZE

LOAD_LOOP:
                push    bc
                push    hl

                ; Set DMA address
                ld      a, l
                out     (SD_DMA_LO), a
                ld      a, h
                out     (SD_DMA_HI), a

                ; Read 128-byte block
                xor     a
                out     (SD_BLOCK), a

                ; Check for read error
                in      a, (SD_BLOCK)
                or      a
                jr      nz, READ_ERROR

                ; Print progress dot
                ld      a, '.'
                call    PRINT_CHAR

                pop     hl
                ld      de, SECT_SIZE
                add     hl, de
                pop     bc
                djnz    LOAD_LOOP

                ; Close file
                ld      a, CMD_CLOSE
                out     (SD_CMD), a

                ; Print done message
                ld      hl, MSG_DONE
                call    PRINT_STR

                ; Jump to BIOS cold start
                jp      BIOS_BASE

;------------------------------------------------------------------------
; Error handlers
;------------------------------------------------------------------------

BOOT_ERROR:
                ld      hl, MSG_NO_FILE
                call    PRINT_STR
                jr      HALT

READ_ERROR:
                pop     hl
                pop     bc
                ld      hl, MSG_READ_ERR
                call    PRINT_STR

HALT:
                ld      hl, MSG_HALT
                call    PRINT_STR
HALT_LOOP:
                halt
                jr      HALT_LOOP

;------------------------------------------------------------------------
; SD Card Routines
;------------------------------------------------------------------------

SD_SEND_NAME:
                ld      a, (hl)
                out     (SD_FNAME), a
                or      a
                ret     z
                inc     hl
                jr      SD_SEND_NAME

;------------------------------------------------------------------------
; Console Routines
;------------------------------------------------------------------------

; Simple print - no TDRE check needed in emulator
PRINT_CHAR:
                out     (ACIA_DATA), a
                ret

PRINT_STR:
                ld      a, (hl)
                or      a
                ret     z
                out     (ACIA_DATA), a
                inc     hl
                jr      PRINT_STR

;------------------------------------------------------------------------
; Data
;------------------------------------------------------------------------

MSG_BOOT:       defb    13, 10
                defb    "RetroShield Z80 Boot Loader", 13, 10
                defb    "Copyright (c) 2025 Alex Jokela, tinycomputers.io", 13, 10
                defb    13, 10, 0

MSG_LOAD:       defb    "Loading CPM.SYS", 0

MSG_DONE:       defb    13, 10
                defb    "Boot complete.", 13, 10, 13, 10, 0

MSG_NO_FILE:    defb    13, 10
                defb    "Error: CPM.SYS not found!", 13, 10, 0

MSG_READ_ERR:   defb    13, 10
                defb    "Error: Read failed!", 13, 10, 0

MSG_HALT:       defb    "System halted.", 13, 10, 0

FILENAME:       defb    "CPM.SYS", 0

                end
