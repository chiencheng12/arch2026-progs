# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.

    .text

# op1: a + b from xor, and, shift. Each pass moves every carry one bit up, so
# the loop ends when the carry word is zero. t0 counts the passes.
    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    li      t0, 0
    beqz    a1, .Lop1_done
.Lop1_loop:
    and     t1, a0, a1              # bits that carry
    xor     a0, a0, a1              # sum without the carries
    slli    a1, t1, 1               # carries move one bit up
    addi    t0, t0, 1
    bnez    a1, .Lop1_loop
.Lop1_done:
    sw      t0, 0(a2)
    ret
    .size   op1_asm, .-op1_asm

# op2: a - b modulo 2^32.
    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub     a0, a0, a1
    ret
    .size   op2_asm, .-op2_asm

# op3: floor((a + b) / 2) without overflow, from a + b = (a ^ b) + 2 (a & b).
    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    and     t0, a0, a1
    xor     t1, a0, a1
    srli    t1, t1, 1
    add     a0, t0, t1
    ret
    .size   op3_asm, .-op3_asm

# q_mul: Q11.20 product, (a * b + 2^19) >> 20, low 32 bits.
#
# The signs are split off, the magnitudes are multiplied by shift and add into
# a 64-bit pair, and the sign is put back as a 64-bit two's complement. The
# result is bits 51..20 of the rounded product.
#
#   a0 = multiplicand low word, then the result
#   a1 = multiplier, shifted right until it is zero
#   t2 = sign mask of the product (all ones when negative)
#   t3 = multiplicand high word
#   t4, t5 = product low, high word
    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    srai    t0, a0, 31
    srai    t1, a1, 31
    xor     t2, t0, t1              # sign of the product
    xor     a0, a0, t0              # |a| = (a ^ s) - s
    sub     a0, a0, t0
    xor     a1, a1, t1              # |b|
    sub     a1, a1, t1
    li      t3, 0
    li      t4, 0
    li      t5, 0
    beqz    a1, .Lq_sign
.Lq_loop:
    andi    t6, a1, 1
    beqz    t6, .Lq_shift
    add     t4, t4, a0              # product += multiplicand (64-bit)
    sltu    t6, t4, a0              # carry out of the low word
    add     t5, t5, t3
    add     t5, t5, t6
.Lq_shift:
    srli    t6, a0, 31              # multiplicand <<= 1 (64-bit)
    slli    t3, t3, 1
    or      t3, t3, t6
    slli    a0, a0, 1
    srli    a1, a1, 1
    bnez    a1, .Lq_loop
.Lq_sign:
    xor     t4, t4, t2              # negate the product when the signs differ:
    xor     t5, t5, t2              # (p ^ s) - s over 64 bits
    andi    t0, t2, 1
    add     t4, t4, t0
    sltu    t1, t4, t0
    add     t5, t5, t1
    lui     t0, 0x80                # + 2^19, half a unit
    add     t4, t4, t0
    sltu    t1, t4, t0
    add     t5, t5, t1
    srli    t0, t4, 20              # bits 51..20
    slli    t1, t5, 12
    or      a0, t0, t1
    ret
    .size   q_mul_asm, .-q_mul_asm
