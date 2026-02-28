#include "Vbus.h"

#include <verilated.h>
#include <cstdio>

static int pass_count = 0;
static int fail_count = 0;

static void check(bool cond, const char* msg) {
    if (cond) {
        pass_count++;
    } else {
        fail_count++;
        printf("  FAIL: %s\n", msg);
    }
}

// Helper: set address and device read data, then eval
static void probe(Vbus* d, uint16_t addr, uint8_t rom_rd = 0xAA,
                  uint8_t wram_rd = 0xBB, uint8_t hram_rd = 0xCC,
                  uint8_t io_rd = 0xDD, uint8_t ie_rd = 0xEE) {
    d->cpu_addr   = addr;
    d->cpu_rd     = 1;
    d->cpu_wr     = 0;
    d->cpu_wdata  = 0;
    d->rom_rdata  = rom_rd;
    d->wram_rdata = wram_rd;
    d->hram_rdata = hram_rd;
    d->io_rdata   = io_rd;
    d->ie_rdata   = ie_rd;
    d->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* d = new Vbus;

    // Test 1: ROM at 0x0000
    printf("Test 1: ROM at 0x0000\n");
    {
        probe(d, 0x0000);
        bool ok = d->rom_cs && !d->wram_cs && !d->hram_cs && !d->io_cs && !d->ie_cs;
        ok = ok && (d->rom_addr == 0x0000) && (d->cpu_rdata == 0xAA);
        check(ok, "ROM select at 0x0000");
    }

    // Test 2: ROM at 0x7FFF
    printf("Test 2: ROM at 0x7FFF\n");
    {
        probe(d, 0x7FFF);
        bool ok = d->rom_cs && (d->rom_addr == 0x7FFF) && (d->cpu_rdata == 0xAA);
        check(ok, "ROM select at 0x7FFF");
    }

    // Test 3: ROM at 0x4000
    printf("Test 3: ROM at 0x4000\n");
    {
        probe(d, 0x4000);
        check(d->rom_cs && (d->rom_addr == 0x4000), "ROM addr mapping at 0x4000");
    }

    // Test 4: VRAM stub (0x8000)
    printf("Test 4: VRAM stub\n");
    {
        probe(d, 0x8000);
        bool ok = !d->rom_cs && !d->wram_cs && !d->hram_cs && !d->io_cs && !d->ie_cs;
        ok = ok && (d->cpu_rdata == 0xFF);
        check(ok, "VRAM stub returns 0xFF");
    }

    // Test 5: ExtRAM stub (0xA000)
    printf("Test 5: ExtRAM stub\n");
    {
        probe(d, 0xA000);
        check(!d->rom_cs && !d->wram_cs && (d->cpu_rdata == 0xFF), "ExtRAM stub returns 0xFF");
    }

    // Test 6: WRAM at 0xC000
    printf("Test 6: WRAM at 0xC000\n");
    {
        probe(d, 0xC000);
        bool ok = d->wram_cs && !d->rom_cs && !d->hram_cs;
        ok = ok && (d->wram_addr == 0x0000) && (d->cpu_rdata == 0xBB);
        check(ok, "WRAM select at 0xC000");
    }

    // Test 7: WRAM address mapping (0xC100 → 0x0100)
    printf("Test 7: WRAM at 0xC100\n");
    {
        probe(d, 0xC100);
        check(d->wram_cs && (d->wram_addr == 0x0100), "WRAM addr at 0xC100");
    }

    // Test 8: WRAM top (0xDFFF → 0x1FFF)
    printf("Test 8: WRAM at 0xDFFF\n");
    {
        probe(d, 0xDFFF);
        check(d->wram_cs && (d->wram_addr == 0x1FFF), "WRAM addr at 0xDFFF");
    }

    // Test 9: Echo RAM (0xE000 → WRAM 0x0000)
    printf("Test 9: Echo RAM at 0xE000\n");
    {
        probe(d, 0xE000);
        check(d->wram_cs && (d->wram_addr == 0x0000) && (d->cpu_rdata == 0xBB),
              "Echo RAM 0xE000 → WRAM");
    }

    // Test 10: Echo RAM top (0xFDFF)
    printf("Test 10: Echo RAM at 0xFDFF\n");
    {
        probe(d, 0xFDFF);
        check(d->wram_cs && (d->wram_addr == 0x1DFF) && (d->cpu_rdata == 0xBB),
              "Echo RAM 0xFDFF → WRAM");
    }

    // Test 11: OAM stub (0xFE00)
    printf("Test 11: OAM stub\n");
    {
        probe(d, 0xFE00);
        check(!d->wram_cs && (d->cpu_rdata == 0xFF), "OAM stub returns 0xFF");
    }

    // Test 12: Unusable (0xFEA0)
    printf("Test 12: Unusable region\n");
    {
        probe(d, 0xFEA0);
        check(d->cpu_rdata == 0xFF, "Unusable returns 0xFF");
    }

    // Test 13: I/O at 0xFF00
    printf("Test 13: I/O at 0xFF00\n");
    {
        probe(d, 0xFF00);
        bool ok = d->io_cs && !d->wram_cs && !d->hram_cs;
        ok = ok && (d->io_addr == 0x00) && (d->cpu_rdata == 0xDD) && d->io_rd;
        check(ok, "I/O select at 0xFF00");
    }

    // Test 14: I/O at 0xFF7F
    printf("Test 14: I/O at 0xFF7F\n");
    {
        probe(d, 0xFF7F);
        check(d->io_cs && (d->io_addr == 0x7F) && (d->cpu_rdata == 0xDD),
              "I/O select at 0xFF7F");
    }

    // Test 15: HRAM at 0xFF80
    printf("Test 15: HRAM at 0xFF80\n");
    {
        probe(d, 0xFF80);
        bool ok = d->hram_cs && !d->io_cs && !d->wram_cs;
        ok = ok && (d->hram_addr == 0x00) && (d->cpu_rdata == 0xCC);
        check(ok, "HRAM select at 0xFF80");
    }

    // Test 16: HRAM at 0xFFFE
    printf("Test 16: HRAM at 0xFFFE\n");
    {
        probe(d, 0xFFFE);
        check(d->hram_cs && (d->hram_addr == 0x7E) && (d->cpu_rdata == 0xCC),
              "HRAM select at 0xFFFE");
    }

    // Test 17: IE at 0xFFFF
    printf("Test 17: IE at 0xFFFF\n");
    {
        probe(d, 0xFFFF);
        bool ok = d->ie_cs && !d->hram_cs && !d->io_cs;
        ok = ok && (d->cpu_rdata == 0xEE);
        check(ok, "IE register at 0xFFFF");
    }

    // Test 18: WRAM write
    printf("Test 18: WRAM write\n");
    {
        d->cpu_addr = 0xC042; d->cpu_rd = 0; d->cpu_wr = 1;
        d->cpu_wdata = 0x55; d->wram_rdata = 0; d->eval();
        bool ok = d->wram_cs && d->wram_we && (d->wram_wdata == 0x55) && (d->wram_addr == 0x0042);
        check(ok, "WRAM write routing");
    }

    // Test 19: I/O write
    printf("Test 19: I/O write\n");
    {
        d->cpu_addr = 0xFF46; d->cpu_rd = 0; d->cpu_wr = 1;
        d->cpu_wdata = 0x99; d->io_rdata = 0; d->eval();
        bool ok = d->io_cs && d->io_wr && !d->io_rd && (d->io_wdata == 0x99) && (d->io_addr == 0x46);
        check(ok, "I/O write routing");
    }

    // Test 20: IE write
    printf("Test 20: IE write\n");
    {
        d->cpu_addr = 0xFFFF; d->cpu_rd = 0; d->cpu_wr = 1;
        d->cpu_wdata = 0x1F; d->ie_rdata = 0; d->eval();
        check(d->ie_cs && d->ie_we && (d->ie_wdata == 0x1F), "IE write routing");
    }

    printf("\n--- Results: %d passed, %d failed ---\n", pass_count, fail_count);
    delete d;
    return fail_count > 0 ? 1 : 0;
}
