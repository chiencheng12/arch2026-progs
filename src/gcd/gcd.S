# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2
gcd_u32_asm:
    beqz    a0, .Lreturn_b
    beqz    a1, .Lreturn_a
    li      t0, 0               # shift = 0
.Lshift_loop:
    or      t1, a0, a1
    andi    t1, t1, 1
    bnez    t1, .Lshift_done    # one of them is odd
    srli    a0, a0, 1
    srli    a1, a1, 1
    addi    t0, t0, 1
    j       .Lshift_loop
.Lshift_done:
.Lstrip_a:
    andi    t1, a0, 1
    bnez    t1, .Lmain_loop     # a is odd
    srli    a0, a0, 1
    j       .Lstrip_a
.Lmain_loop:
.Lstrip_b:
    andi    t1, a1, 1
    bnez    t1, .Lcompare       # b is odd
    srli    a1, a1, 1
    j       .Lstrip_b
.Lcompare:
    bgeu    a1, a0, .Lsub       # a <= b, no swap
    mv      t2, a0
    mv      a0, a1
    mv      a1, t2
.Lsub:
    sub     a1, a1, a0
    bnez    a1, .Lmain_loop
    sll     a0, a0, t0          # restore the common factors of two
    ret

.Lreturn_b:
    mv      a0, a1
.Lreturn_a:
    ret
    .size   gcd_u32_asm, .-gcd_u32_asm
