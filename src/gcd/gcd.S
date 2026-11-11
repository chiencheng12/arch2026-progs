# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.
#
# Method: strip the common factors of two (counted in t0), make a odd, then
# repeat "strip b, subtract the smaller from the larger" until b is zero.
# After the first pass both operands are odd, so b - a (or a - b) is even and
# non-zero, and every strip loop can shift before it tests. The loop exists in
# two copies with the roles of a0 and a1 exchanged: swapping the operands then
# costs no move, the difference is written straight into the register that
# held the larger one.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2
gcd_u32_asm:
    beqz    a0, .Lreturn_b
    beqz    a1, .Lreturn_a
    li      t0, 0                   # shift = 0
    or      t1, a0, a1
    andi    t1, t1, 1
    bnez    t1, .Lcommon_done       # not both even
.Lcommon_loop:
    srli    a0, a0, 1
    srli    a1, a1, 1
    addi    t0, t0, 1
    or      t1, a0, a1
    andi    t1, t1, 1
    beqz    t1, .Lcommon_loop
.Lcommon_done:
    andi    t1, a0, 1
    bnez    t1, .Lstrip_a_done      # a is odd
.Lstrip_a:
    srli    a0, a0, 1
    andi    t1, a0, 1
    beqz    t1, .Lstrip_a
.Lstrip_a_done:
    andi    t1, a1, 1
    bnez    t1, .Lcmp1              # b is odd

    # Copy 1: a is in a0, b is in a1.
.Lstrip1:                           # b is even and non-zero here
    srli    a1, a1, 1
    andi    t1, a1, 1
    beqz    t1, .Lstrip1
.Lcmp1:                             # a and b are odd
    bltu    a1, a0, .Lswap1
    sub     a1, a1, a0
    bnez    a1, .Lstrip1
    sll     a0, a0, t0              # restore the common factors of two
    ret
.Lswap1:                            # b < a: the new a is a1, the new b is a0 - a1
    sub     a0, a0, a1

    # Copy 2: a is in a1, b is in a0.
.Lstrip2:                           # b is even and non-zero here
    srli    a0, a0, 1
    andi    t1, a0, 1
    beqz    t1, .Lstrip2
.Lcmp2:                             # a and b are odd
    bltu    a0, a1, .Lswap2
    sub     a0, a0, a1
    bnez    a0, .Lstrip2
    sll     a0, a1, t0
    ret
.Lswap2:                            # b < a: the new a is a0, the new b is a1 - a0
    sub     a1, a1, a0
    j       .Lstrip1

.Lreturn_b:
    mv      a0, a1
.Lreturn_a:
    ret
    .size   gcd_u32_asm, .-gcd_u32_asm
