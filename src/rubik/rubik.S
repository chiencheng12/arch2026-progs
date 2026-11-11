# rubik_solve_asm: optimal 2x2x2 cube solver, hand-written RV32I.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#                                   a0 = state, a1 = out, a2 = cap; result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions, no heap, no recursion. Tests: tests/trubik.c.
#
# IDA* with pattern databases. The state is three coordinates (the same as
# rubik.c):
#   perm   0..5039  Lehmer rank of the 7 cubies
#   orient 0..728   base-3 value of the first 6 twists
#   place  0..209   positions of cubies 0, 1, 2
# Heuristic h = max(h_perm, pdb_ol[place * 729 + orient]).
#
# Table layout (rubik_tables.S, from gen_tables.c): registers hold byte
# offsets (perm * 2, orient * 4, place * 4) so that no lookup needs a shift,
# and each perm move entry carries h_perm of its target in bits 13..15. The
# three turns of a face are unrolled (no turn counter in the hot path), both
# prunes compare the raw value against a threshold shifted to the same bit
# position (no decode before the branch), and pdb_ol uses swapped nibbles so
# that one offset yields the shift amount.
#
# The search state lives on the stack: 12 frames of 12 bytes, one per depth.
#   +0 perm * 2 (half)  +2 orient * 4 (half)  +4 place * 4 (half)
#   +6 face  +7 turns  +8 last face
# Returns the number of moves, -1 for an invalid state (out untouched), -2 when
# the text does not fit in cap bytes (out[0] cleared when cap is not zero).

.equ PM_FACE, 10080                 # bytes per face in pmh (5040 halves)
.equ OM_FACE, 2916                  # bytes per face in om4 (729 words)
.equ LM_FACE, 840                   # bytes per face in lm4 (210 words)
.equ NO_FACE, 3
.equ FRAME, 12

# Stack frame of rubik_solve_asm.
.equ SAVED_OUT, 60                  # out and cap, needed after the search
.equ SAVED_CAP, 64
.equ PBUF, 68                       # parsed cubie digits
.equ WHERE, 76                      # where[c] = position of cubie c
.equ FACE_PTR, 84                   # per face: &pmh[f], &om4[f], &lm4[f]
.equ FRAMES, 120
.equ STACK_SIZE, 272

    .section .rodata
    .align 2
lehmer_w:
    .half   720, 120, 24, 6, 2, 1
# move index = face * 3 + turns - 1; its name is 2 chars at move_name + 2 * idx
move_name:
    .ascii  "R R2R'B B2B'D D2D'"

    .text
    .globl  rubik_solve_asm
    .type   rubik_solve_asm, @function
    .align  2
rubik_solve_asm:
    addi    sp, sp, -STACK_SIZE
    sw      ra, 0(sp)
    sw      s0, 4(sp)
    sw      s1, 8(sp)
    sw      s2, 12(sp)
    sw      s3, 16(sp)
    sw      s4, 20(sp)
    sw      s5, 24(sp)
    sw      s6, 28(sp)
    sw      s7, 32(sp)
    sw      s8, 36(sp)
    sw      s9, 40(sp)
    sw      s10, 44(sp)
    sw      s11, 48(sp)
    sw      gp, 52(sp)
    sw      tp, 56(sp)
    sw      a1, SAVED_OUT(sp)
    sw      a2, SAVED_CAP(sp)
    mv      a7, a0                  # state

    # ---- table bases kept in saved registers for the whole search ----
    la      s1, rubik_pmh
    la      s2, rubik_om4
    la      s3, rubik_lm4
    la      s4, rubik_pdb_perm
    la      s5, rubik_pdb_ol_sw
    la      s6, rubik_place_base4
    addi    s8, sp, FRAMES
    addi    gp, sp, FACE_PTR        # gp, tp are free in this bare-metal program
    li      tp, 3

    # face_ptr[f] = (pm + f * PM_FACE, om + f * OM_FACE, lm + f * LM_FACE)
    mv      t0, gp
    mv      t1, s1
    mv      t2, s2
    mv      t3, s3
    li      t4, 3
.Lfp_loop:
    sw      t1, 0(t0)
    sw      t2, 4(t0)
    sw      t3, 8(t0)
    li      t5, PM_FACE
    add     t1, t1, t5
    li      t5, OM_FACE
    add     t2, t2, t5
    addi    t3, t3, LM_FACE
    addi    t0, t0, 12
    addi    t4, t4, -1
    bnez    t4, .Lfp_loop

# ---- parse and validate ----
    mv      t0, a7
    li      t1, 0                   # i
    li      t2, 0                   # bit mask of cubies seen
    addi    t3, sp, PBUF
    addi    t4, sp, WHERE
.Lparse_perm:
    lbu     t5, 0(t0)
    addi    t5, t5, -49             # digit - '1'
    li      t6, 6
    bgtu    t5, t6, .Linvalid       # also catches characters below '1'
    srl     t6, t2, t5
    andi    t6, t6, 1
    bnez    t6, .Linvalid           # duplicate cubie
    li      t6, 1
    sll     t6, t6, t5
    or      t2, t2, t6
    sb      t5, 0(t3)               # pbuf[i] = cubie
    add     t6, t4, t5
    sb      t1, 0(t6)               # where[cubie] = i
    addi    t0, t0, 1
    addi    t3, t3, 1
    addi    t1, t1, 1
    li      t6, 7
    blt     t1, t6, .Lparse_perm

    li      a0, 0                   # sum of twists
    li      a1, 0                   # orient coordinate
    li      t1, 0
.Lparse_twist:
    lbu     t5, 0(t0)
    addi    t5, t5, -49
    li      t6, 2
    bgtu    t5, t6, .Linvalid
    add     a0, a0, t5
    li      t6, 6
    bge     t1, t6, .Ltwist_done    # the 7th twist is implied
    slli    t6, a1, 1               # orient = orient * 3 + twist
    add     a1, a1, t6
    add     a1, a1, t5
.Ltwist_done:
    addi    t0, t0, 1
    addi    t1, t1, 1
    li      t6, 7
    blt     t1, t6, .Lparse_twist
    lbu     t5, 0(t0)
    bnez    t5, .Linvalid           # exactly 14 characters
    li      t6, 3
.Lsum_mod3:                         # sum % 3 without division (sum <= 14)
    blt     a0, t6, .Lsum_done
    addi    a0, a0, -3
    j       .Lsum_mod3
.Lsum_done:
    bnez    a0, .Linvalid           # twist invariant violated

    # Lehmer rank: sum over i of smaller(i) * (6-i)!, smaller(i) <= 6,
    # multiplied by selecting 1x, 2x, 4x of the weight with masks.
    li      a2, 0                   # rank
    addi    t0, sp, PBUF
    la      t1, lehmer_w
    li      t2, 0                   # i
.Llehmer_i:
    lbu     t3, 0(t0)               # p[i]
    li      t4, 0                   # smaller
    addi    t5, t0, 1
    addi    t6, sp, PBUF + 7        # end of pbuf
.Llehmer_j:
    lbu     a3, 0(t5)
    sltu    a3, a3, t3
    add     t4, t4, a3
    addi    t5, t5, 1
    blt     t5, t6, .Llehmer_j
    lhu     a3, 0(t1)               # weight
    andi    a4, t4, 1
    neg     a4, a4
    and     a4, a4, a3
    add     a2, a2, a4
    slli    a3, a3, 1
    andi    a4, t4, 2
    srli    a4, a4, 1
    neg     a4, a4
    and     a4, a4, a3
    add     a2, a2, a4
    slli    a3, a3, 1
    andi    a4, t4, 4
    srli    a4, a4, 2
    neg     a4, a4
    and     a4, a4, a3
    add     a2, a2, a4
    addi    t0, t0, 1
    addi    t1, t1, 2
    addi    t2, t2, 1
    li      a3, 6
    blt     t2, a3, .Llehmer_i

    # place = a * 30 + b' * 5 + c', a, b, c = positions of cubies 0, 1, 2
    addi    t0, sp, WHERE
    lbu     t1, 0(t0)               # a
    lbu     t2, 1(t0)               # b
    lbu     t3, 2(t0)               # c
    sltu    t4, t1, t2
    sub     t4, t2, t4              # b' = b - (b > a)
    sltu    t5, t1, t3
    sub     t5, t3, t5
    sltu    t6, t2, t3
    sub     t5, t5, t6              # c' = c - (c > a) - (c > b)
    slli    a3, t1, 5
    slli    t1, t1, 1
    sub     a3, a3, t1              # 30a = 32a - 2a
    slli    t6, t4, 2
    add     t4, t4, t6              # 5b'
    add     a3, a3, t4
    add     a3, a3, t5              # place

    # frame 0 = start state, stored as byte offsets
    slli    t0, a2, 1
    sh      t0, 0(s8)               # perm * 2
    slli    t0, a1, 2
    sh      t0, 2(s8)               # orient * 4
    slli    t0, a3, 2
    sh      t0, 4(s8)               # place * 4
    li      t0, NO_FACE
    sb      t0, 8(s8)

    # h of the start state; 0 means already solved
    srli    t0, a2, 1               # h_perm from the packed pdb_perm
    add     t0, s4, t0
    lbu     t0, 0(t0)
    andi    t1, a2, 1
    slli    t1, t1, 2
    srl     t0, t0, t1
    andi    t0, t0, 15
    lhu     t1, 4(s8)               # h_ol, same access as in the search
    add     t1, s6, t1
    lw      t1, 0(t1)
    lhu     t2, 2(s8)
    add     t1, t1, t2
    srli    t2, t1, 3
    add     t2, s5, t2
    lbu     t2, 0(t2)
    ori     t1, t1, 24
    sll     t2, t2, t1
    srli    t2, t2, 28
    bgeu    t0, t2, .Lh0_max
    mv      t0, t2
.Lh0_max:
    beqz    t0, .Lsolved
    mv      s7, t0                  # bound = h(start)

# ---- IDA* ----
# Registers during the search:
#   s0  frame of the node being expanded (depth d)
#   s7  bound          s9  face f being expanded
#   s10 turns of f (1..3 = X, X2, X'), written only on descend / found
#   s11 bound - d: a child is pruned if its h >= s11
#   t5  s11 << 13  (compared with the raw pmh entry: h_perm sits in 13..15)
#   t6  s11 << 28  (compared with the pdb_ol nibble shifted to 28..31)
#   a1, a2, a3  &pmh[f], &om4[f], &lm4[f]
#   a4, a5, a6  child perm*2, orient*4, place*4
#   gp  face_ptr       tp  constant 3
.Lnew_bound:
    mv      s0, s8
    mv      s11, s7
    slli    t5, s11, 13
    slli    t6, s11, 28
    li      s9, 0

.Lface_setup:                       # start face s9 of the node at s0
    lbu     t0, 8(s0)
    bne     s9, t0, .Lface_ok
    addi    s9, s9, 1               # skip the face that led here
.Lface_ok:
    bgeu    s9, tp, .Lbacktrack
    slli    t0, s9, 3
    slli    t1, s9, 2
    add     t0, t0, t1              # f * 12
    add     t0, t0, gp
    lw      a1, 0(t0)
    lw      a2, 4(t0)
    lw      a3, 8(t0)
    lhu     a4, 0(s0)               # child starts as a copy of the node
    lhu     a5, 2(s0)
    lhu     a6, 4(s0)

# Each turn block applies one quarter turn to the child (X, then X2,
# then X') and falls through to the next block when the child is pruned.
.Lturn1:
    add     t0, a1, a4
    lhu     t0, 0(t0)               # next perm | h_perm << 13
    add     t1, a2, a5
    lw      a5, 0(t1)               # next orient * 4
    add     t1, a3, a6
    lw      a6, 0(t1)               # next place * 4
    slli    a4, t0, 19
    srli    a4, a4, 18              # (perm & 0x1fff) * 2
    bgeu    t0, t5, .Lturn2         # prune on h_perm
    add     t1, s6, a6
    lw      t1, 0(t1)               # place * 729 * 4
    add     t1, t1, a5              # 4 * nibble index
    srli    t2, t1, 3
    add     t2, s5, t2
    lbu     t2, 0(t2)
    ori     t1, t1, 24              # shift: 24 (even entry) or 28 (odd)
    sll     t2, t2, t1              # entry now in bits 28..31
    bgeu    t2, t6, .Lturn2         # prune on h_ol
    or      t0, a4, a5
    li      s10, 1
    beqz    t0, .Lfound
    j       .Ldescend

.Lturn2:
    add     t0, a1, a4
    lhu     t0, 0(t0)
    add     t1, a2, a5
    lw      a5, 0(t1)
    add     t1, a3, a6
    lw      a6, 0(t1)
    slli    a4, t0, 19
    srli    a4, a4, 18
    bgeu    t0, t5, .Lturn3
    add     t1, s6, a6
    lw      t1, 0(t1)
    add     t1, t1, a5
    srli    t2, t1, 3
    add     t2, s5, t2
    lbu     t2, 0(t2)
    ori     t1, t1, 24
    sll     t2, t2, t1
    bgeu    t2, t6, .Lturn3
    or      t0, a4, a5
    li      s10, 2
    beqz    t0, .Lfound
    j       .Ldescend

.Lturn3:
    add     t0, a1, a4
    lhu     t0, 0(t0)
    add     t1, a2, a5
    lw      a5, 0(t1)
    add     t1, a3, a6
    lw      a6, 0(t1)
    slli    a4, t0, 19
    srli    a4, a4, 18
    bgeu    t0, t5, .Lnext_face
    add     t1, s6, a6
    lw      t1, 0(t1)
    add     t1, t1, a5
    srli    t2, t1, 3
    add     t2, s5, t2
    lbu     t2, 0(t2)
    ori     t1, t1, 24
    sll     t2, t2, t1
    bgeu    t2, t6, .Lnext_face
    or      t0, a4, a5
    li      s10, 3
    beqz    t0, .Lfound
    j       .Ldescend

.Lnext_face:
    addi    s9, s9, 1
    j       .Lface_setup

.Ldescend:
    sb      s9, 6(s0)               # remember where we were
    sb      s10, 7(s0)
    addi    s0, s0, FRAME
    sh      a4, 0(s0)
    sh      a5, 2(s0)
    sh      a6, 4(s0)
    sb      s9, 8(s0)               # last face of the new node
    addi    s11, s11, -1
    slli    t5, s11, 13
    slli    t6, s11, 28
    li      s9, 0
    j       .Lface_setup

.Lbacktrack:
    beq     s0, s8, .Lbound_up
    addi    s0, s0, -FRAME
    addi    s11, s11, 1
    slli    t5, s11, 13
    slli    t6, s11, 28
    lbu     s9, 6(s0)
    lbu     s10, 7(s0)
    slli    t0, s9, 3               # restore face pointers and the child
    slli    t1, s9, 2
    add     t0, t0, t1
    add     t0, t0, gp
    lw      a1, 0(t0)
    lw      a2, 4(t0)
    lw      a3, 8(t0)
    lhu     a4, FRAME(s0)
    lhu     a5, 14(s0)
    lhu     a6, 16(s0)
    li      t0, 1                   # resume after turn s10
    beq     s10, t0, .Lturn2
    li      t0, 2
    beq     s10, t0, .Lturn3
    j       .Lnext_face

.Lbound_up:
    addi    s7, s7, 1
    j       .Lnew_bound

.Lsolved:
    mv      s0, s8                  # no moves
    j       .Loutput

.Lfound:
    sb      s9, 6(s0)
    sb      s10, 7(s0)
    addi    s0, s0, FRAME           # s0 = end of the solution frames

# ---- output ----
# The solution frames are s8 .. s0. Each move takes 2 characters when it is a
# half or a reverse turn and 1 for a quarter turn, plus a space between moves
# and the NUL: the text needs 2 * moves + (number of non-quarter turns) bytes,
# or 1 byte for no moves.
.Loutput:
    lw      a1, SAVED_OUT(sp)
    lw      a2, SAVED_CAP(sp)
    li      t0, 0
    mv      t3, s8
.Lneed_loop:
    beq     t3, s0, .Lneed_done
    lbu     t1, 7(t3)
    addi    t1, t1, -1
    snez    t1, t1                  # 1 unless it is a quarter turn
    addi    t0, t0, 2
    add     t0, t0, t1
    addi    t3, t3, FRAME
    j       .Lneed_loop
.Lneed_done:
    bnez    t0, .Lneed_have
    li      t0, 1
.Lneed_have:
    bgeu    a2, t0, .Lwrite         # cap >= need
    beqz    a2, .Ltoo_small
    sb      zero, 0(a1)
.Ltoo_small:
    li      a0, -2
    j       .Lepilogue

.Lwrite:
    la      t4, move_name
    mv      t3, s8
    li      a0, 0                   # moves written
.Lwrite_loop:
    beq     t3, s0, .Lwrite_end
    beq     t3, s8, .Lno_sep
    li      t0, 32
    sb      t0, 0(a1)
    addi    a1, a1, 1
.Lno_sep:
    lbu     t0, 6(t3)               # face
    lbu     t1, 7(t3)               # turns
    slli    t2, t0, 1
    add     t0, t0, t2
    add     t0, t0, t1
    addi    t0, t0, -1              # face * 3 + turns - 1
    slli    t0, t0, 1
    add     t5, t4, t0
    lbu     t0, 0(t5)
    sb      t0, 0(a1)
    addi    a1, a1, 1
    lbu     t0, 1(t5)
    li      t6, 32
    beq     t0, t6, .Lname_done
    sb      t0, 0(a1)
    addi    a1, a1, 1
.Lname_done:
    addi    a0, a0, 1
    addi    t3, t3, FRAME
    j       .Lwrite_loop
.Lwrite_end:
    sb      zero, 0(a1)
    j       .Lepilogue

.Linvalid:
    li      a0, -1

.Lepilogue:
    lw      ra, 0(sp)
    lw      s0, 4(sp)
    lw      s1, 8(sp)
    lw      s2, 12(sp)
    lw      s3, 16(sp)
    lw      s4, 20(sp)
    lw      s5, 24(sp)
    lw      s6, 28(sp)
    lw      s7, 32(sp)
    lw      s8, 36(sp)
    lw      s9, 40(sp)
    lw      s10, 44(sp)
    lw      s11, 48(sp)
    lw      gp, 52(sp)
    lw      tp, 56(sp)
    addi    sp, sp, STACK_SIZE
    ret
    .size   rubik_solve_asm, .-rubik_solve_asm
