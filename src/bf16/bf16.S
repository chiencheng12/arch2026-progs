# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.

    .text

# from_f32: round to nearest even by adding 0x7FFF plus bit 16 and keeping the
# top half. An exponent field of 0xFF (Inf and NaN) keeps the top half as is.
    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    lui     t0, 0x7F800             # exponent mask
    and     t1, a0, t0
    beq     t1, t0, .Lf32_special
    srli    t1, a0, 16
    andi    t1, t1, 1               # bit 16, breaks ties to even
    lui     t2, 8
    addi    t2, t2, -1              # 0x7FFF
    add     t1, t1, t2
    add     a0, a0, t1
.Lf32_special:
    srli    a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# mul: sign xor, special values in the order a then b, zeros, denormals
# normalized, an 8 x 8 bit product by shift and add, truncated fraction.
#
#   t0 = sign of the product in bit 15
#   t1, t2 = exponent and fraction (then significand) of a
#   t3, t4 = exponent and fraction (then significand) of b
    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    xor     t0, a0, a1
    lui     t5, 8                   # 0x8000
    and     t0, t0, t5
    srli    t1, a0, 7
    andi    t1, t1, 0xFF
    andi    t2, a0, 0x7F
    srli    t3, a1, 7
    andi    t3, t3, 0xFF
    andi    t4, a1, 0x7F
    li      t5, 0xFF
    beq     t1, t5, .Lmul_a_special
    beq     t3, t5, .Lmul_b_special

    or      t5, t1, t2              # a is zero
    beqz    t5, .Lmul_zero
    or      t5, t3, t4              # b is zero
    beqz    t5, .Lmul_zero

    bnez    t1, .Lmul_a_normal      # a denormal: shift the leading one up
    li      t1, 1
.Lmul_a_shift:
    slli    t2, t2, 1
    addi    t1, t1, -1
    andi    t5, t2, 0x80
    beqz    t5, .Lmul_a_shift
    j       .Lmul_b_start
.Lmul_a_normal:
    ori     t2, t2, 0x80
.Lmul_b_start:
    bnez    t3, .Lmul_b_normal
    li      t3, 1
.Lmul_b_shift:
    slli    t4, t4, 1
    addi    t3, t3, -1
    andi    t5, t4, 0x80
    beqz    t5, .Lmul_b_shift
    j       .Lmul_product
.Lmul_b_normal:
    ori     t4, t4, 0x80

.Lmul_product:                      # t5 = t2 * t4, both in [128, 255]
    li      t5, 0
.Lmul_loop:
    andi    t6, t4, 1
    beqz    t6, .Lmul_skip
    add     t5, t5, t2
.Lmul_skip:
    slli    t2, t2, 1
    srli    t4, t4, 1
    bnez    t4, .Lmul_loop

    add     t1, t1, t3              # exponent = ea + eb - 127
    addi    t1, t1, -127
    lui     t6, 8
    and     t6, t5, t6              # bit 15: the product is in [2, 4)
    beqz    t6, .Lmul_lt2
    srli    t5, t5, 8
    addi    t1, t1, 1
    j       .Lmul_frac
.Lmul_lt2:
    srli    t5, t5, 7
.Lmul_frac:
    andi    t5, t5, 0x7F            # truncated fraction

    li      t6, 0xFF
    bge     t1, t6, .Lmul_inf
    blez    t1, .Lmul_under
    slli    t1, t1, 7
    or      t5, t5, t1
    or      a0, t0, t5
    ret

.Lmul_under:                        # exponent <= 0: denormal, or zero below -6
    li      t6, -6
    blt     t1, t6, .Lmul_zero
    li      t6, 1
    sub     t6, t6, t1
    srl     t5, t5, t6              # the fraction shifted right by 1 - exponent
    or      a0, t0, t5
    ret

.Lmul_a_special:
    bnez    t2, .Lmul_ret_a         # NaN a is returned unchanged
    or      t5, t3, t4
    beqz    t5, .Lmul_nan           # Inf times zero
    j       .Lmul_inf
.Lmul_b_special:
    bnez    t4, .Lmul_ret_b         # NaN b is returned unchanged
    or      t5, t1, t2
    beqz    t5, .Lmul_nan           # zero times Inf
.Lmul_inf:
    li      t5, 0x7F80
    or      a0, t0, t5
    ret
.Lmul_nan:
    li      a0, 0x7FC0
    ret
.Lmul_zero:
    mv      a0, t0
    ret
.Lmul_ret_b:
    mv      a0, a1
.Lmul_ret_a:
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

# sqrt: NaN and +Inf are returned unchanged, negative values give the quiet NaN,
# zeros and denormals give +0. For a normal value the exponent is made even by
# doubling the significand m, and the result is the largest mid with
# mid * mid / 128 <= m. That is floor(sqrt(128 m + 127)), found by the bitwise
# integer square root, so no multiply is needed. A normal input never overflows
# or underflows: the result exponent lies in [64, 190].
    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    srli    t0, a0, 15              # sign
    srli    t1, a0, 7
    andi    t1, t1, 0xFF            # exponent
    andi    t2, a0, 0x7F            # fraction
    li      t3, 0xFF
    beq     t1, t3, .Lsqrt_special
    or      t4, t1, t2
    beqz    t4, .Lsqrt_zero
    bnez    t0, .Lsqrt_nan          # negative and not zero
    beqz    t1, .Lsqrt_zero         # positive denormal

    addi    t1, t1, -127
    ori     t2, t2, 0x80            # significand
    andi    t3, t1, 1
    beqz    t3, .Lsqrt_even
    slli    t2, t2, 1               # odd exponent: double m
    addi    t1, t1, -1
.Lsqrt_even:
    srai    t1, t1, 1               # half the exponent
    addi    t1, t1, 127

    slli    t3, t2, 7
    ori     t3, t3, 127             # n = 128 m + 127
    li      t4, 0                   # root
    lui     t5, 4                   # bit = 0x4000
.Lsqrt_loop:
    add     t6, t4, t5
    bltu    t3, t6, .Lsqrt_no
    sub     t3, t3, t6
    srli    t4, t4, 1
    add     t4, t4, t5
    srli    t5, t5, 2
    bnez    t5, .Lsqrt_loop
    j       .Lsqrt_done
.Lsqrt_no:
    srli    t4, t4, 1
    srli    t5, t5, 2
    bnez    t5, .Lsqrt_loop
.Lsqrt_done:
    andi    t4, t4, 0x7F
    slli    t1, t1, 7
    or      a0, t1, t4
    ret

.Lsqrt_special:
    bnez    t2, .Lsqrt_ret          # NaN
    beqz    t0, .Lsqrt_ret          # +Inf
.Lsqrt_nan:
    li      a0, 0x7FC0
    ret
.Lsqrt_zero:
    li      a0, 0
.Lsqrt_ret:
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm
