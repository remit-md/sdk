import Foundation

/// Pure Swift Keccak-256 (Ethereum variant - NOT SHA-3).
/// Used for Ethereum address derivation from secp256k1 public keys.
///
/// Reference: https://keccak.team/keccak_specs_summary.html
/// Rate = 1088 bits (136 bytes), Capacity = 512 bits, Output = 256 bits.
internal func keccak256(_ data: Data) -> Data {
    var msg = [UInt8](data)
    let rateBytes = 136 // (1600 - 512) / 8

    // Keccak padding (0x01 then 0x00... then 0x80) - differs from SHA-3 (0x06)
    let q = rateBytes - (msg.count % rateBytes)
    if q == 1 {
        msg.append(0x81)
    } else {
        msg.append(0x01)
        msg.append(contentsOf: [UInt8](repeating: 0, count: q - 2))
        msg.append(0x80)
    }

    // Absorb
    var state = [UInt64](repeating: 0, count: 25)
    let blocks = msg.count / rateBytes
    for b in 0..<blocks {
        for i in 0..<(rateBytes / 8) {
            var lane: UInt64 = 0
            let base = b * rateBytes + i * 8
            for j in 0..<8 {
                lane |= UInt64(msg[base + j]) << (j * 8)
            }
            state[i] ^= lane
        }
        keccakF1600(&state)
    }

    // Squeeze first 256 bits (32 bytes)
    var output = Data(count: 32)
    for i in 0..<4 {
        var lane = state[i]
        for j in 0..<8 {
            output[i * 8 + j] = UInt8(lane & 0xff)
            lane >>= 8
        }
    }
    return output
}

// MARK: - Keccak-f[1600] permutation

private let keccakRC: [UInt64] = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

// ρ rotation offsets for the 24 non-identity positions
private let keccakRho: [Int] = [
     1,  3,  6, 10, 15, 21, 28, 36, 45, 55,
     2, 14, 27, 41, 56,  8, 25, 43, 62, 18,
    39, 61, 20, 44,
]

// π permutation indices - PIL[i] is the destination lane for step i
// (lane index = x + 5*y)
private let keccakPi: [Int] = [
    10,  7, 11, 17, 18,  3,  5, 16,  8, 21,
    24,  4, 15, 23, 19, 13, 12,  2, 20, 14,
    22,  9,  6,  1,
]

@inline(__always)
private func rotl64(_ v: UInt64, _ n: Int) -> UInt64 {
    (v << n) | (v >> (64 - n))
}

private func keccakF1600(_ state: inout [UInt64]) {
    for round in 0..<24 {
        // θ: column parity + XOR diffusion
        var c0 = state[0] ^ state[5]  ^ state[10] ^ state[15] ^ state[20]
        var c1 = state[1] ^ state[6]  ^ state[11] ^ state[16] ^ state[21]
        var c2 = state[2] ^ state[7]  ^ state[12] ^ state[17] ^ state[22]
        var c3 = state[3] ^ state[8]  ^ state[13] ^ state[18] ^ state[23]
        var c4 = state[4] ^ state[9]  ^ state[14] ^ state[19] ^ state[24]

        let d0 = c4 ^ rotl64(c1, 1)
        let d1 = c0 ^ rotl64(c2, 1)
        let d2 = c1 ^ rotl64(c3, 1)
        let d3 = c2 ^ rotl64(c4, 1)
        let d4 = c3 ^ rotl64(c0, 1)

        for y in 0..<5 {
            state[0 + y*5] ^= d0
            state[1 + y*5] ^= d1
            state[2 + y*5] ^= d2
            state[3 + y*5] ^= d3
            state[4 + y*5] ^= d4
        }

        // ρ + π combined: traverse the off-diagonal cycle, rotate, and scatter
        var b = [UInt64](repeating: 0, count: 25)
        b[0] = state[0] // (0,0) → (0,0) with rotation 0
        var current = state[1]
        for i in 0..<24 {
            let dst = keccakPi[i]
            let tmp = state[dst]
            b[dst] = rotl64(current, keccakRho[i])
            current = tmp
        }

        // χ: non-linear step
        for y in 0..<5 {
            let base = y * 5
            let b0 = b[base + 0], b1 = b[base + 1], b2 = b[base + 2]
            let b3 = b[base + 3], b4 = b[base + 4]
            state[base + 0] = b0 ^ (~b1 & b2)
            state[base + 1] = b1 ^ (~b2 & b3)
            state[base + 2] = b2 ^ (~b3 & b4)
            state[base + 3] = b3 ^ (~b4 & b0)
            state[base + 4] = b4 ^ (~b0 & b1)
        }

        // ι: round constant
        state[0] ^= keccakRC[round]
    }
}
