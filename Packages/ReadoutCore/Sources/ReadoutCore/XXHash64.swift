import Foundation

/// xxHash64 (seed 0). Used for block fingerprints and file-content change detection.
public enum XXHash64 {
    private static let p1: UInt64 = 11400714785074694791
    private static let p2: UInt64 = 14029467366897019727
    private static let p3: UInt64 = 1609587929392839161
    private static let p4: UInt64 = 9650029242287828579
    private static let p5: UInt64 = 2870177450012600261

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 {
        (x << r) | (x >> (64 - r))
    }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var acc = acc &+ input &* p2
        acc = rotl(acc, 31)
        return acc &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        var acc = acc ^ round(0, val)
        acc = acc &* p1 &+ p4
        return acc
    }

    public static func hash(_ string: String, seed: UInt64 = 0) -> UInt64 {
        var s = string
        return s.withUTF8 { hash(UnsafeRawBufferPointer($0), seed: seed) }
    }

    public static func hash(_ data: Data, seed: UInt64 = 0) -> UInt64 {
        data.withUnsafeBytes { hash($0, seed: seed) }
    }

    public static func hash(_ buf: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let len = buf.count
        var i = 0
        var h: UInt64

        func read64(_ off: Int) -> UInt64 { UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: off, as: UInt64.self)) }
        func read32(_ off: Int) -> UInt64 { UInt64(UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: off, as: UInt32.self))) }

        if len >= 32 {
            var v1 = seed &+ p1 &+ p2
            var v2 = seed &+ p2
            var v3 = seed
            var v4 = seed &- p1
            while i + 32 <= len {
                v1 = round(v1, read64(i)); i += 8
                v2 = round(v2, read64(i)); i += 8
                v3 = round(v3, read64(i)); i += 8
                v4 = round(v4, read64(i)); i += 8
            }
            h = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h = merge(h, v1); h = merge(h, v2); h = merge(h, v3); h = merge(h, v4)
        } else {
            h = seed &+ p5
        }
        h = h &+ UInt64(len)

        while i + 8 <= len {
            h ^= round(0, read64(i))
            h = rotl(h, 27) &* p1 &+ p4
            i += 8
        }
        if i + 4 <= len {
            h ^= read32(i) &* p1
            h = rotl(h, 23) &* p2 &+ p3
            i += 4
        }
        while i < len {
            h ^= UInt64(buf[i]) &* p5
            h = rotl(h, 11) &* p1
            i += 1
        }
        h ^= h >> 33
        h = h &* p2
        h ^= h >> 29
        h = h &* p3
        h ^= h >> 32
        return h
    }
}
