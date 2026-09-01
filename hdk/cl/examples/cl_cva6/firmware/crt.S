  .section .text.init
  .globl _start
_start:
  la sp, _sp
  la t0, _bss_start
  la t1, _bss_end
1:
  bgeu t0, t1, 2f
  sw zero, 0(t0)
  addi t0, t0, 4
  j 1b
2:
  jal ra, main
3:
  j 3b
