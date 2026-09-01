#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

#include "fpga_pci.h"
#include "fpga_mgmt.h"
#include "utils/lcd.h"

#include "cl_cva6_def.h"

static const struct logger *logger = &logger_stdout;

static void usage(const char *name)
{
    printf("usage: %s [--slot N] [--bin hello_world.bin] [--verify]\n", name);
}

/*
 * Pops UART bytes until the FIFO has been empty for idle_limit ms.
 * Returns the byte count, or -1 on a PCIe error.
 */
static int drain_uart(pci_bar_handle_t bar, int idle_limit, int echo)
{
    int idle = 0;
    int count = 0;

    while (idle < idle_limit) {
        uint32_t status = 0;
        if (fpga_pci_peek(bar, CL_CVA6_STATUS, &status))
            return -1;
        if (status & 1u) {
            uint32_t ch = 0;
            if (fpga_pci_peek(bar, CL_CVA6_UART_RX, &ch))
                return -1;
            if (echo) {
                putchar((int)(ch & 0xff));
                fflush(stdout);
            }
            count++;
            idle = 0;
        } else {
            usleep(1000);
            idle++;
        }
    }
    return count;
}

static int mem_store(pci_bar_handle_t bar, uint32_t addr, uint32_t data)
{
    int rc;
    rc = fpga_pci_poke(bar, CL_CVA6_MEM_ADDR, addr);
    fail_on(rc, out, "poke MEM_ADDR");
    rc = fpga_pci_poke(bar, CL_CVA6_MEM_WDATA, data);
    fail_on(rc, out, "poke MEM_WDATA");
    rc = fpga_pci_poke(bar, CL_CVA6_MEM_CMD, CL_CVA6_MEM_WRITE);
    fail_on(rc, out, "poke MEM_CMD");
    usleep(2);
out:
    return rc;
}

int main(int argc, char **argv)
{
    int rc;
    int slot_id = 0;
    int verify = 0;
    const char *bin_path = "../firmware/hello_world.bin";
    pci_bar_handle_t bar = PCI_BAR_HANDLE_INIT;
    uint32_t magic = 0;

    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--slot", 6) && i + 1 < argc)
            slot_id = atoi(argv[++i]);
        else if (!strncmp(argv[i], "--bin", 5) && i + 1 < argc)
            bin_path = argv[++i];
        else if (!strcmp(argv[i], "--verify"))
            verify = 1;
        else {
            usage(argv[0]);
            return 1;
        }
    }

    rc = log_init("hello_cva6");
    fail_on(rc, out, "log_init");
    rc = log_attach(logger, NULL, 0);
    fail_on(rc, out, "log_attach");
    rc = fpga_mgmt_init();
    fail_on(rc, out, "fpga_mgmt_init");

    rc = fpga_pci_attach(slot_id, FPGA_APP_PF, APP_PF_BAR0, 0, &bar);
    fail_on(rc, out, "fpga_pci_attach");

    rc = fpga_pci_peek(bar, CL_CVA6_MAGIC, &magic);
    fail_on(rc, out, "peek MAGIC");
    if (magic != CL_CVA6_MAGIC_VAL) {
        printf("Unexpected MAGIC 0x%08x (want 0x%08x). Is cl_cva6 loaded?\n",
               magic, CL_CVA6_MAGIC_VAL);
        rc = 1;
        goto out;
    }
    printf("cl_cva6 MAGIC ok\n");

    rc = fpga_pci_poke(bar, CL_CVA6_CTRL, 0);
    fail_on(rc, out, "hold reset");

    FILE *f = fopen(bin_path, "rb");
    fail_on(!f, out, "open %s", bin_path);
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = calloc(1, (sz + 3) & ~3L);
    fail_on(!buf, out, "calloc");
    if (fread(buf, 1, sz, f) != (size_t)sz) {
        fclose(f);
        rc = 1;
        goto out;
    }
    fclose(f);

    printf("Loading %ld bytes from %s\n", sz, bin_path);
    for (long i = 0; i < ((sz + 3) & ~3L); i += 4) {
        uint32_t w;
        memcpy(&w, buf + i, 4);
        rc = mem_store(bar, (uint32_t)i, w);
        fail_on(rc, out, "mem_store 0x%lx", i);
    }
    free(buf);

    if (verify) {
        int stale = drain_uart(bar, 200, 0);
        rc = (stale < 0);
        fail_on(rc, out, "flush stale UART bytes");
        printf("Flushed %d stale UART byte(s)\n", stale);

        printf("--- phase A: image loaded, core STILL HELD IN RESET ---\n");
        int quiet = drain_uart(bar, 2000, 1);
        rc = (quiet < 0);
        fail_on(rc, out, "phase A drain");
        printf("phase A bytes: %d  ->  %s\n", quiet,
               quiet == 0 ? "PASS (silent, nothing but the core can drive the UART)"
                          : "FAIL (UART traffic without an executing core)");
    }

    printf("Releasing CVA6 reset\n");
    rc = fpga_pci_poke(bar, CL_CVA6_CTRL, 1);
    fail_on(rc, out, "run");

    printf("--- UART from CVA6 ---\n");
    int got = drain_uart(bar, 2000, 1);
    rc = (got < 0);
    fail_on(rc, out, "uart drain");
    printf("\n--- done, %d byte(s) ---\n", got);

    if (verify)
        printf("phase B bytes: %d  ->  %s\n", got,
               got > 0 ? "PASS (traffic appeared only after reset release)"
                       : "FAIL (no UART traffic from the core)");

out:
    if (bar != PCI_BAR_HANDLE_INIT)
        fpga_pci_detach(bar);
    return rc;
}
