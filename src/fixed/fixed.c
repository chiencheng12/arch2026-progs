#include "fixed.h"

/* Dummies: every function returns 0. Replace with the real routines. */
uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    *n = 0;
    while (b != 0) {
        uint32_t c = (a & b) << 1;
        a = a ^ b;
        b = c;
        (*n)++;
    }
    return a;
}

uint32_t op2(uint32_t a, uint32_t b)
{
    return a - b;
}

uint32_t op3(uint32_t a, uint32_t b)
{
    return (a & b) + ((a ^ b) >> 1);
}

/* Shift-and-add multiply: a 32 x 32 -> 64 bit unsigned product without
 * __muldi3, which the freestanding runtime does not provide.
 */
static uint64_t umul32(uint32_t a, uint32_t b)
{
    uint64_t r = 0;
    uint64_t x = a;
    while (b != 0) {
        /* Select the addend by table. Written as "if (b & 1) r += x", or
         * as a mask, the compiler turns it into x * (b & 1) at -Os, which
         * calls __muldi3.
         */
        const uint64_t addend[2] = {0, x};
        r += addend[b & 1];
        x <<= 1;
        b >>= 1;
    }
    return r;
}

int32_t q_mul(int32_t a, int32_t b)
{
    uint32_t ua = a < 0 ? 0u - (uint32_t) a : (uint32_t) a;
    uint32_t ub = b < 0 ? 0u - (uint32_t) b : (uint32_t) b;
    uint64_t u = umul32(ua, ub);
    if ((a < 0) != (b < 0)) {
        u = 0u - u;
    }
    int64_t p = (int64_t) u;
    p += 1 << 19;
    p >>= 20;
    return (int32_t) p;
}
