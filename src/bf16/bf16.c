#include "bf16.h"

/* Dummies: every function returns 0. Replace with the real routines. */
uint16_t bf16_from_f32(uint32_t f32bits)
{
    if (((f32bits >> 23) & 0xFF) == 0xFF) {
        return f32bits >> 16;
    }
    return (f32bits + 0x7FFF + ((f32bits >> 16) & 1)) >> 16;
}

uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    uint32_t sign = ((a ^ b) >> 15) & 1;
    uint32_t ea = (a >> 7) & 0xFF;
    uint32_t eb = (b >> 7) & 0xFF;
    uint32_t fa = a & 0x7F;
    uint32_t fb = b & 0x7F;

    if (ea == 0xFF) {
        if (fa != 0) {
            return a;
        }
        if (eb == 0 && fb == 0) {
            return 0x7FC0;
        }
        return (sign << 15) | 0x7F80;
    }
    if (eb == 0xFF) {
        if (fb != 0) {
            return b;
        }
        if (ea == 0 && fa == 0) {
            return 0x7FC0;
        }
        return (sign << 15) | 0x7F80;
    }
    if ((ea == 0 && fa == 0) || (eb == 0 && fb == 0)) {
        return sign << 15;
    }

    /* Significands with the leading one in bit 7. A denormal has exponent 1
     * for its scale; shifting the leading one up lowers it to match.
     */
    int32_t xa = ea;
    int32_t xb = eb;
    uint32_t ma = fa;
    uint32_t mb = fb;
    if (xa != 0) {
        ma |= 0x80;
    } else {
        xa = 1;
        while ((ma & 0x80) == 0) {
            ma <<= 1;
            xa--;
        }
    }
    if (xb != 0) {
        mb |= 0x80;
    } else {
        xb = 1;
        while ((mb & 0x80) == 0) {
            mb <<= 1;
            xb--;
        }
    }

    /* The product is in [2^14, 2^16): bit 15 set means [2, 4), so shift one
     * more and raise the exponent. The fraction is truncated.
     */
    int32_t e = xa + xb - 127;
    uint32_t m = ma * mb;
    uint32_t frac;
    if (m & 0x8000) {
        frac = (m >> 8) & 0x7F;
        e++;
    } else {
        frac = (m >> 7) & 0x7F;
    }

    if (e >= 0xFF) {
        return (sign << 15) | 0x7F80;
    }
    if (e <= 0) {
        if (e < -6) {
            return sign << 15;
        }
        return (sign << 15) | (frac >> (1 - e));
    }
    return (sign << 15) | ((uint32_t) e << 7) | frac;
}

uint16_t bf16_sqrt(uint16_t a)
{
    uint32_t sign = a >> 15;
    uint32_t ea = (a >> 7) & 0xFF;
    uint32_t fa = a & 0x7F;

    if (ea == 0xFF) {
        if (fa == 0 && sign) {
            return 0x7FC0;
        }
        return a;
    }
    if (ea == 0 && fa == 0) {
        return 0;
    }
    if (sign) {
        return 0x7FC0;
    }
    if (ea == 0) {
        return 0;
    }

    /* sqrt(2^e * m) = 2^(e / 2) * sqrt(m): make e even by doubling m. */
    int32_t e = (int32_t) ea - 127;
    uint32_t m = 0x80 | fa;
    if (e & 1) {
        m <<= 1;
        e--;
    }
    e /= 2;

    /* The largest mid in [90, 256] with mid * mid / 128 <= m, by binary
     * search. The result stays in [128, 256), so the exponent needs no
     * further adjustment.
     */
    uint32_t lo = 90;
    uint32_t hi = 256;
    while (lo < hi) {
        uint32_t mid = (lo + hi + 1) >> 1;
        if (((mid * mid) >> 7) <= m) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    e += 127;
    if (e >= 0xFF) {
        return 0x7F80;
    }
    if (e <= 0) {
        return 0;
    }
    return ((uint32_t) e << 7) | (lo & 0x7F);
}
