    .section .text
    .globl _start
# The human readable code
_start:
    lui   t0, 0x10000       # t0 = GPIO address 0x1000_0000
    addi  t1, zero, 1       # start with LED on

toggle:
    sw    t1, 0(t0)         # write bit zero to GPIO
    xori  t1, t1, 1         # choose opposite state next time
    lui   t2, 0x00100       # hardware delay = 1,048,576 iterations

delay:
    addi  t2, t2, -1
    bne   t2, zero, delay
    jal   zero, toggle
