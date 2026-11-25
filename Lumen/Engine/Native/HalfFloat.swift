#if arch(x86_64)
/// Swift's `Float16` exists only on Apple silicon. The native wallpapers fill half-float buffers
/// that their shaders read as `half`, so Intel builds store the same IEEE 754 binary16 bits here.
/// Only construction is needed: the values are written once per frame and uploaded as bytes.
struct Float16: ExpressibleByIntegerLiteral {
    var bits: UInt16

    init(integerLiteral value: Int) { self.init(Float(value)) }

    /// Rounds to nearest, ties to even, like the hardware conversion.
    init(_ value: Float) {
        let f = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: (f >> 16) & 0x8000)
        let exponent = Int((f >> 23) & 0xff) - 127 + 15
        let mantissa = f & 0x7f_ffff
        if f & 0x7fff_ffff > 0x7f80_0000 { bits = sign | 0x7e00; return }   // NaN
        if exponent >= 31 { bits = sign | 0x7c00; return }                 // overflow and infinity
        if exponent <= 0 {                                                  // subnormal or zero
            guard exponent >= -10 else { bits = sign; return }
            let full = mantissa | 0x80_0000
            let shift = UInt32(14 - exponent)
            var half = full >> shift
            let rest = full & ((1 << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if rest > halfway || (rest == halfway && half & 1 == 1) { half += 1 }
            bits = sign | UInt16(truncatingIfNeeded: half)
            return
        }
        var half = UInt32(exponent) << 10 | mantissa >> 13
        let rest = mantissa & 0x1fff
        // A carry out of the mantissa correctly rounds up into the exponent.
        if rest > 0x1000 || (rest == 0x1000 && half & 1 == 1) { half += 1 }
        bits = sign | UInt16(truncatingIfNeeded: half)
    }
}
#endif
