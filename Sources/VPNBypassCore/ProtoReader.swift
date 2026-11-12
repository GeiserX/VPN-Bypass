// ProtoReader.swift
// A cursor over protobuf wire data, for the geoip.dat and geosite.dat readers. It stops, rather
// than traps, on bad input: a length that runs past the end ends the read.

import Foundation

struct ProtoReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0
    /// A read ran past the end or met something that is not wire data. Reaching the end of the
    /// data between fields is not a failure; a field cut short is, so a truncated file shows.
    private(set) var failed = false

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < bytes.count, shift < 64 {
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        failed = true
        return nil
    }

    /// The next field number and wire type, nil at the end or on a malformed tag.
    mutating func nextTag() -> (field: UInt64, wire: UInt64)? {
        guard position < bytes.count, let tag = varint() else { return nil }
        return (tag >> 3, tag & 7)
    }

    mutating func lengthDelimited() -> UnsafeBufferPointer<UInt8>? {
        guard let length = varint() else { return nil }
        guard length <= UInt64(bytes.count - position) else {
            failed = true
            return nil
        }
        let start = position
        position += Int(length)
        return UnsafeBufferPointer(rebasing: bytes[start..<position])
    }

    /// Steps over a field of wire type `wire`; false when it is unknown or runs past the end.
    mutating func skip(_ wire: UInt64) -> Bool {
        switch wire {
        case 0: return varint() != nil
        case 1: return advance(8)
        case 2: return lengthDelimited() != nil
        case 5: return advance(4)
        default:
            failed = true
            return false
        }
    }

    private mutating func advance(_ count: Int) -> Bool {
        guard count <= bytes.count - position else {
            failed = true
            return false
        }
        position += count
        return true
    }
}
