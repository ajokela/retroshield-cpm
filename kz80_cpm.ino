////////////////////////////////////////////////////////////////////
// Z80 RetroShield CP/M 2.2
// 2026/01/07
//
// Copyright (c) 2019, 2023 Erturk Kocalar, 8Bitforce.com
// Copyright (c) 2025, 2026 Alex Jokela, tinycomputers.io
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Hardware:
//   - Arduino Mega 2560
//   - 8bitforce KDRAM2560 (1MB DRAM shield)
//   - Z80 RetroShield
//   - MicroSD card (software SPI on pins 4-7)
//
////////////////////////////////////////////////////////////////////

#define __AVR_ATmega2560__
#include <avr/io.h>
#include <avr/iomxx0_1.h>
#include <Arduino.h>
#include <pins_arduino.h>
#include <avr/pgmspace.h>

////////////////////////////////////////////////////////////////////
// KDRAM2560 Configuration
// Use Timer 1 for DRAM refresh (96ms cycle)
////////////////////////////////////////////////////////////////////
#define DRAM_REFRESH_USE_TIMER_1
#include <kdram2560.h>

////////////////////////////////////////////////////////////////////
// SdFat with Software SPI
// Hardware SPI (pins 50-53) is used by RetroShield
// NOTE: SPI_DRIVER_SELECT must be set to 2 in SdFat/SdFatConfig.h
////////////////////////////////////////////////////////////////////
#include "SdFat.h"

// Software SPI pins (avoid RetroShield conflict)
const uint8_t SOFT_MISO_PIN = 4;
const uint8_t SOFT_MOSI_PIN = 5;
const uint8_t SOFT_SCK_PIN  = 6;
const uint8_t SD_CS_PIN     = 7;

// SdFat software SPI template
SoftSpiDriver<SOFT_MISO_PIN, SOFT_MOSI_PIN, SOFT_SCK_PIN> softSpi;
#define SD_CONFIG SdSpiConfig(SD_CS_PIN, DEDICATED_SPI, SD_SCK_MHZ(0), &softSpi)

// Use SdFs for FAT16/FAT32 and exFAT support
SdFs sd;

////////////////////////////////////////////////////////////////////
// Configuration
////////////////////////////////////////////////////////////////////
#define outputDEBUG     0       // Set to 1 for debug output

////////////////////////////////////////////////////////////////////
// Z80 Pin Definitions
////////////////////////////////////////////////////////////////////

#define DATA_OUT (PORTL)
#define DATA_IN  (PINL)
#define ADDR_H   (PINC)
#define ADDR_L   (PINA)
#define ADDR     ((unsigned int) (ADDR_H << 8 | ADDR_L))

#define uP_RESET_N  38
#define uP_MREQ_N   41
#define uP_IORQ_N   39
#define uP_RD_N     53
#define uP_WR_N     40
#define uP_NMI_N    51
#define uP_INT_N    50
#define uP_CLK      52

// Fast clock control
#define CLK_HIGH      (PORTB = PORTB | 0x02)
#define CLK_LOW       (PORTB = PORTB & 0xFC)
#define STATE_RD_N    (PINB & 0x01)
#define STATE_WR_N    (PING & 0x02)
#define STATE_MREQ_N  (PING & 0x01)
#define STATE_IORQ_N  (PING & 0x04)

#define DIR_IN  0x00
#define DIR_OUT 0xFF
#define DATA_DIR   DDRL
#define ADDR_H_DIR DDRC
#define ADDR_L_DIR DDRA

////////////////////////////////////////////////////////////////////
// MC6850 ACIA (Console)
////////////////////////////////////////////////////////////////////
#define ADDR_6850_DATA        0x81
#define ADDR_6850_CONTROL     0x80
#define CONTROL_RTS_STATE     (reg6850_CONTROL & 0b01000000)
#define CONTROL_TX_INT_ENABLE (reg6850_CONTROL & 0b00100000)
#define CONTROL_RX_INT_ENABLE (reg6850_CONTROL & 0b10000000)

byte reg6850_DATA_RX    = 0x00;
byte reg6850_DATA_TX    = 0x00;
byte reg6850_CONTROL    = 0x00;
byte reg6850_STATUS     = 0x00;

void mc6850_init() {
    reg6850_DATA_RX    = 0x00;
    reg6850_DATA_TX    = 0x00;
    reg6850_CONTROL    = 0b01010100;  // RTS HIGH, TX INT Disabled, RX INT Disabled
    reg6850_STATUS     = 0b00000010;  // CTS LOW, DCD LOW, TX EMPTY 1, RX FULL 0
}

////////////////////////////////////////////////////////////////////
// SD Card I/O Ports
////////////////////////////////////////////////////////////////////
#define SD_CMD_PORT      0x10   // Command register
#define SD_STATUS_PORT   0x11   // Status register
#define SD_DATA_PORT     0x12   // Data byte
#define SD_FNAME_PORT    0x13   // Filename input
#define SD_SEEK_LO       0x14   // Seek position low byte
#define SD_SEEK_HI       0x15   // Seek position middle byte
#define SD_DMA_LO        0x16   // DMA address low byte
#define SD_DMA_HI        0x17   // DMA address high byte
#define SD_BLOCK_CMD     0x18   // Block command
#define SD_SEEK_EX       0x19   // Seek position high byte (bits 16-23)

// SD Commands
#define SD_CMD_OPEN_READ   0x01
#define SD_CMD_CREATE      0x02
#define SD_CMD_OPEN_APPEND 0x03
#define SD_CMD_SEEK_START  0x04
#define SD_CMD_CLOSE       0x05
#define SD_CMD_DIR         0x06
#define SD_CMD_OPEN_RW     0x07
#define SD_CMD_SEEK        0x08

// SD Status bits
#define SD_STATUS_READY    0x01
#define SD_STATUS_ERROR    0x02
#define SD_STATUS_DATA     0x80

// Block size for DMA
#define SD_BLOCK_SIZE      128

////////////////////////////////////////////////////////////////////
// SD Card State
////////////////////////////////////////////////////////////////////
String sdFilename;
FsFile sdFile;
FsFile sdDir;
bool sdDirActive = false;
String sdDirEntry;
uint8_t sdDirEntryPos = 0;
uint8_t sdStatus = SD_STATUS_READY;
uint32_t sdSeekPos = 0;          // 24-bit seek position
uint16_t sdDmaAddr = 0x0080;     // DMA address
uint8_t sdBlockStatus = 0;
bool sdInitialized = false;

////////////////////////////////////////////////////////////////////
// SD Card Functions
////////////////////////////////////////////////////////////////////

bool sd_handles_port(uint8_t port) {
    return (port >= SD_CMD_PORT && port <= SD_SEEK_EX);
}

uint8_t sd_read_port(uint8_t port) {
    switch (port) {
        case SD_STATUS_PORT: {
            uint8_t s = sdStatus;
            if (sdFile || sdDirActive) {
                s |= SD_STATUS_DATA;
            }
            return s;
        }

        case SD_DATA_PORT: {
            if (sdFile) {
                int b = sdFile.read();
                if (b < 0) {
                    sdFile.close();
                    sdStatus = SD_STATUS_READY;
                    return 0;
                }
                return (uint8_t)b;
            } else if (sdDirActive) {
                return sd_read_dir_byte();
            }
            return 0;
        }

        case SD_BLOCK_CMD:
            return sdBlockStatus;

        default:
            return 0xFF;
    }
}

void sd_write_port(uint8_t port, uint8_t val) {
    switch (port) {
        case SD_CMD_PORT:
            sd_handle_command(val);
            break;

        case SD_DATA_PORT:
            if (sdFile) {
                sdFile.write(val);
            }
            break;

        case SD_FNAME_PORT:
            if (val == 0) {
#if outputDEBUG
                Serial.print("[SD] Filename: ");
                Serial.println(sdFilename);
#endif
            } else {
                sdFilename += (char)val;
            }
            break;

        case SD_SEEK_LO:
            sdSeekPos = (sdSeekPos & 0xFFFF00) | val;
            break;

        case SD_SEEK_HI:
            sdSeekPos = (sdSeekPos & 0xFF00FF) | ((uint32_t)val << 8);
            break;

        case SD_SEEK_EX:
            sdSeekPos = (sdSeekPos & 0x00FFFF) | ((uint32_t)val << 16);
            break;

        case SD_DMA_LO:
            sdDmaAddr = (sdDmaAddr & 0xFF00) | val;
            break;

        case SD_DMA_HI:
            sdDmaAddr = (sdDmaAddr & 0x00FF) | ((uint16_t)val << 8);
            break;

        case SD_BLOCK_CMD:
            if (val == 0) {
                sd_do_block_read();
            } else {
                sd_do_block_write();
            }
            break;
    }
}

void sd_handle_command(uint8_t cmd) {
    switch (cmd) {
        case SD_CMD_OPEN_READ:
            if (sdFile) sdFile.close();
            sdFile = sd.open(sdFilename.c_str(), O_READ);
            if (sdFile) {
                sdStatus = SD_STATUS_READY;
#if outputDEBUG
                Serial.print("[SD] Opened for read: ");
                Serial.println(sdFilename);
#endif
            } else {
                sdStatus = SD_STATUS_ERROR | SD_STATUS_READY;
#if outputDEBUG
                Serial.print("[SD] Failed to open: ");
                Serial.println(sdFilename);
#endif
            }
            sdFilename = "";
            break;

        case SD_CMD_CREATE:
            if (sdFile) sdFile.close();
            if (sd.exists(sdFilename.c_str())) {
                sd.remove(sdFilename.c_str());
            }
            sdFile = sd.open(sdFilename.c_str(), O_WRITE | O_CREAT);
            if (sdFile) {
                sdStatus = SD_STATUS_READY;
            } else {
                sdStatus = SD_STATUS_ERROR | SD_STATUS_READY;
            }
            sdFilename = "";
            break;

        case SD_CMD_OPEN_APPEND:
            if (sdFile) sdFile.close();
            sdFile = sd.open(sdFilename.c_str(), O_WRITE | O_APPEND);
            if (sdFile) {
                sdStatus = SD_STATUS_READY;
            } else {
                sdStatus = SD_STATUS_ERROR | SD_STATUS_READY;
            }
            sdFilename = "";
            break;

        case SD_CMD_SEEK_START:
            if (sdFile) {
                sdFile.seek(0);
                sdStatus = SD_STATUS_READY;
            } else {
                sdStatus = SD_STATUS_ERROR | SD_STATUS_READY;
            }
            break;

        case SD_CMD_CLOSE:
            if (sdFile) {
                sdFile.close();
            }
            if (sdDirActive) {
                sdDir.close();
                sdDirActive = false;
            }
            sdStatus = SD_STATUS_READY;
            break;

        case SD_CMD_DIR:
            if (sdFile) sdFile.close();
            if (sdDirActive) sdDir.close();
            sdDir = sd.open("/");
            if (sdDir) {
                sdDirActive = true;
                sdDirEntry = "";
                sdDirEntryPos = 0;
                sdStatus = SD_STATUS_READY;
            } else {
                sdDirActive = false;
                sdStatus = SD_STATUS_ERROR | SD_STATUS_READY;
            }
            break;

        case SD_CMD_OPEN_RW:
            if (sdFile) sdFile.close();
            sdFile = sd.open(sdFilename.c_str(), O_RDWR);
            if (sdFile) {
                sdStatus = SD_STATUS_READY;
#if outputDEBUG
                Serial.print("[SD] Opened for R/W: ");
                Serial.println(sdFilename);
#endif
            } else {
                sdStatus = SD_STATUS_ERROR | SD_STATUS_READY;
            }
            sdFilename = "";
            break;

        case SD_CMD_SEEK:
            if (sdFile) {
                sdFile.seek(sdSeekPos);
                sdStatus = SD_STATUS_READY;
#if outputDEBUG
                Serial.print("[SD] Seek to: ");
                Serial.println(sdSeekPos);
#endif
            } else {
                sdStatus = SD_STATUS_ERROR | SD_STATUS_READY;
            }
            break;
    }
}

uint8_t sd_read_dir_byte() {
    if (!sdDirActive) return 0;

    while (sdDirEntryPos >= sdDirEntry.length()) {
        FsFile entry = sdDir.openNextFile();
        if (!entry) {
            sdDir.close();
            sdDirActive = false;
            sdStatus = SD_STATUS_READY;
            return 0;
        }

        char name[64];
        entry.getName(name, sizeof(name));

        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
            entry.close();
            continue;
        }

        sdDirEntry = String(name) + "\r\n";
        sdDirEntryPos = 0;
        entry.close();
        break;
    }

    if (sdDirEntryPos < sdDirEntry.length()) {
        return sdDirEntry[sdDirEntryPos++];
    }
    return 0;
}

void sd_do_block_read() {
    if (!sdFile) {
#if outputDEBUG
        Serial.println("[SD] Block read: no file open");
#endif
        sdBlockStatus = 1;
        return;
    }

    uint8_t buffer[SD_BLOCK_SIZE];
    int bytesRead = sdFile.read(buffer, SD_BLOCK_SIZE);

    if (bytesRead < 0) {
        sdBlockStatus = 1;
        return;
    }

    // Zero-fill remainder
    for (int i = bytesRead; i < SD_BLOCK_SIZE; i++) {
        buffer[i] = 0;
    }

    // Copy to DRAM
    for (int i = 0; i < SD_BLOCK_SIZE; i++) {
        DRAM.write8((unsigned long)(sdDmaAddr + i), buffer[i]);
    }

    sdBlockStatus = 0;
#if outputDEBUG
    Serial.print("[SD] Block read: ");
    Serial.print(bytesRead);
    Serial.print(" bytes to ");
    Serial.println(sdDmaAddr, HEX);
#endif
}

void sd_do_block_write() {
    if (!sdFile) {
#if outputDEBUG
        Serial.println("[SD] Block write: no file open");
#endif
        sdBlockStatus = 1;
        return;
    }

    uint8_t buffer[SD_BLOCK_SIZE];

    // Copy from DRAM
    for (int i = 0; i < SD_BLOCK_SIZE; i++) {
        buffer[i] = DRAM.read8((unsigned long)(sdDmaAddr + i));
    }

    size_t written = sdFile.write(buffer, SD_BLOCK_SIZE);

    if (written != SD_BLOCK_SIZE) {
        sdBlockStatus = 1;
        return;
    }

    sdFile.sync();
    sdBlockStatus = 0;
#if outputDEBUG
    Serial.print("[SD] Block write: ");
    Serial.print(SD_BLOCK_SIZE);
    Serial.print(" bytes from ");
    Serial.println(sdDmaAddr, HEX);
#endif
}

////////////////////////////////////////////////////////////////////
// Processor Variables
////////////////////////////////////////////////////////////////////
unsigned long clock_cycle_count;
unsigned int uP_ADDR;
byte uP_DATA;
byte prevIORQ = 0;
byte prevMREQ = 0;
byte prevDATA = 0;

////////////////////////////////////////////////////////////////////
// Processor Initialization
////////////////////////////////////////////////////////////////////
void uP_init() {
    DATA_DIR = DIR_IN;
    ADDR_H_DIR = DIR_IN;
    ADDR_L_DIR = DIR_IN;

    pinMode(uP_RESET_N, OUTPUT);
    pinMode(uP_WR_N, INPUT);
    pinMode(uP_RD_N, INPUT);
    pinMode(uP_MREQ_N, INPUT);
    pinMode(uP_IORQ_N, INPUT);
    pinMode(uP_INT_N, OUTPUT);
    pinMode(uP_NMI_N, OUTPUT);
    pinMode(uP_CLK, OUTPUT);

    uP_assert_reset();
    digitalWrite(uP_CLK, LOW);

    clock_cycle_count = 0;
}

void uP_assert_reset() {
    digitalWrite(uP_RESET_N, LOW);
    digitalWrite(uP_INT_N, HIGH);
    digitalWrite(uP_NMI_N, HIGH);
}

void uP_release_reset() {
    digitalWrite(uP_RESET_N, HIGH);
}

////////////////////////////////////////////////////////////////////
// CPU Tick - Main Processing Loop
////////////////////////////////////////////////////////////////////
inline __attribute__((always_inline))
void cpu_tick() {
    // Check for serial input (ACIA RX)
    if (!CONTROL_RTS_STATE && Serial.available()) {
        reg6850_STATUS = reg6850_STATUS | 0b00000001;
        if (CONTROL_RX_INT_ENABLE) {
            digitalWrite(uP_INT_N, LOW);
        } else {
            digitalWrite(uP_INT_N, HIGH);
        }
    } else {
        reg6850_STATUS = reg6850_STATUS & 0b11111110;
        digitalWrite(uP_INT_N, HIGH);
    }

    CLK_HIGH;
    uP_ADDR = ADDR;

    //////////////////////////////////////////////////////////////////////
    // Memory Access
    if (!STATE_MREQ_N) {
        // Memory Read
        if (!STATE_RD_N) {
            DATA_DIR = DIR_OUT;
            // All memory comes from DRAM (64KB)
            DATA_OUT = DRAM.read8((unsigned long)uP_ADDR);
        }
        // Memory Write
        else if (!STATE_WR_N) {
            DRAM.write8((unsigned long)uP_ADDR, DATA_IN);
        }
    }
    //////////////////////////////////////////////////////////////////////
    // IO Access
    else if (!STATE_IORQ_N) {
        // IO Read
        if (!STATE_RD_N && prevIORQ) {
            DATA_DIR = DIR_OUT;

            // SD Card ports (0x10-0x19)
            if (sd_handles_port(ADDR_L)) {
                prevDATA = sd_read_port(ADDR_L);
            }
            // 6850 ACIA
            else if (ADDR_L == ADDR_6850_DATA) {
                prevDATA = reg6850_DATA_RX = Serial.read();
            }
            else if (ADDR_L == ADDR_6850_CONTROL) {
                prevDATA = reg6850_STATUS;
            }

            DATA_OUT = prevDATA;
        }
        else if (!STATE_RD_N && !prevIORQ) {
            DATA_DIR = DIR_OUT;
            DATA_OUT = prevDATA;
        }
        // IO Write
        else if (!STATE_WR_N && prevIORQ) {
            DATA_DIR = DIR_IN;

            // SD Card ports (0x10-0x19)
            if (sd_handles_port(ADDR_L)) {
                sd_write_port(ADDR_L, DATA_IN);
                prevDATA = DATA_IN;
            }
            // 6850 ACIA
            else if (ADDR_L == ADDR_6850_DATA) {
                prevDATA = reg6850_DATA_TX = DATA_IN;
                reg6850_STATUS = reg6850_STATUS & 0b11111101;
                Serial.write(reg6850_DATA_TX);
                reg6850_STATUS = reg6850_STATUS | 0b00000010;
            }
            else if (ADDR_L == ADDR_6850_CONTROL) {
                prevDATA = reg6850_CONTROL = DATA_IN;
            }

            DATA_IN = prevDATA;
        }
        else {
            DATA_DIR = DIR_OUT;
            DATA_OUT = 0;
        }
    }

    prevIORQ = STATE_IORQ_N;
    prevMREQ = STATE_MREQ_N;

    CLK_LOW;
    clock_cycle_count++;
    DATA_DIR = DIR_IN;
}

////////////////////////////////////////////////////////////////////
// Load boot.bin from SD card into DRAM at address 0x0000
////////////////////////////////////////////////////////////////////
bool loadBootLoader() {
    Serial.println("Loading boot.bin...");

    FsFile bootFile = sd.open("boot.bin", O_READ);
    if (!bootFile) {
        Serial.println("ERROR: boot.bin not found on SD card!");
        return false;
    }

    uint32_t addr = 0;
    while (bootFile.available()) {
        uint8_t b = bootFile.read();
        DRAM.write8(addr++, b);
    }
    bootFile.close();

    Serial.print("Loaded ");
    Serial.print(addr);
    Serial.println(" bytes to DRAM at 0x0000");

    return true;
}

////////////////////////////////////////////////////////////////////
// Setup
////////////////////////////////////////////////////////////////////
void setup() {
    Serial.begin(115200);
    while (!Serial) {}  // Wait for serial connection

    Serial.println();
    Serial.println("======================================");
    Serial.println("RetroShield Z80 CP/M 2.2");
    Serial.println("======================================");
    Serial.println();

    // Initialize DRAM
    Serial.print("KDRAM2560:  ");
    if (DRAM.begin(&Serial)) {
        Serial.println("OK (1MB DRAM)");
    } else {
        Serial.println("FAILED!");
        while (1) {}  // Halt
    }

    // Initialize SD card (software SPI)
    Serial.print("SD Card:    ");
    if (sd.begin(SD_CONFIG)) {
        Serial.println("OK (Software SPI)");
        sdInitialized = true;
    } else {
        Serial.println("FAILED!");
        Serial.println("Check SD card and wiring:");
        Serial.println("  MISO=Pin 4, MOSI=Pin 5, SCK=Pin 6, CS=Pin 7");
        while (1) {}  // Halt
    }

    // Load boot loader from SD card
    if (!loadBootLoader()) {
        Serial.println("Cannot continue without boot.bin");
        while (1) {}  // Halt
    }

    // Initialize processor GPIO
    uP_init();

    // Initialize ACIA
    mc6850_init();

    // Reset processor
    uP_assert_reset();
    for (int i = 0; i < 25; i++) cpu_tick();

    Serial.println();
    Serial.println("Starting Z80...");
    Serial.println();

    // Release reset
    uP_release_reset();
}

////////////////////////////////////////////////////////////////////
// Loop
////////////////////////////////////////////////////////////////////
void loop() {
    cpu_tick();
}
