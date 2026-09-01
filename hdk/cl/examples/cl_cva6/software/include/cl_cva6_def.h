#pragma once

#define CL_CVA6_CTRL      0x00
#define CL_CVA6_STATUS    0x04
#define CL_CVA6_UART_RX   0x08
#define CL_CVA6_MAGIC     0x0C
#define CL_CVA6_MEM_ADDR  0x10
#define CL_CVA6_MEM_WDATA 0x14
#define CL_CVA6_MEM_RDATA 0x18
#define CL_CVA6_MEM_CMD   0x1C

#define CL_CVA6_MAGIC_VAL 0xC6A60001u
#define CL_CVA6_MEM_WRITE 1u
#define CL_CVA6_MEM_READ  2u
