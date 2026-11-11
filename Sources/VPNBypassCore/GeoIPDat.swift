// GeoIPDat.swift
// Reads the v2ray `geoip.dat` format: a protobuf list of country code -> CIDR ranges that
// Loyalsoldier/v2ray-rules-dat, MetaCubeX/meta-rules-dat, Chocolate4U/Iran-v2ray-rules and
// OpenWrt Passwall2 all publish and read. Pure and I/O-free, so it is tested in isolation.
//
//   message CIDR     { bytes ip = 1; uint32 prefix = 2; }          // ip is 4 (IPv4) or 16 (IPv6) bytes
//   message GeoIP    { string country_code = 1; repeated CIDR cidr = 2; bool reverse_match = 3; }
//   message GeoIPList { repeated GeoIP entry = 1; }
//
// Only IPv4 ranges are read, because the kernel engine routes IPv4 only (RuleResolver.ipv4).
// An entry with `reverse_match` ("everything except these") is skipped: it cannot be written as
// a list of routes. The reader never trusts a length: a field that runs past the end of the data
// ends the read instead of crashing, so a truncated or hostile file gives less, not a trap.

import Foundation

enum GeoIPDat {

    /// The IPv4 ranges of each country in `codes` (lower case, "ir"), as "a.b.c.d/p" strings in
    /// file order. A code the file does not hold is absent from the result.
    static func ranges(for codes: Set<String>, in data: Data) -> [String: [String]] {
        guard !codes.isEmpty else { return [:] }
        var found: [String: [String]] = [:]
        scan(data) { entry in
            let code = entry.code.lowercased()
            guard codes.contains(code), !entry.reverse else { return }
            found[code, default: []] += entry.ranges()
        }
        return found
    }

    /// Every country in the file with its number of IPv4 ranges, for the Country picker.
    static func countries(in data: Data) -> [String: Int] {
        var counts: [String: Int] = [:]
        scan(data) { entry in
            guard !entry.reverse else { return }
            let count = entry.rangeCount()
            if count > 0 { counts[entry.code.lowercased(), default: 0] += count }
        }
        return counts
    }

    /// True when `data` reads as a geoip list with at least one country and one IPv4 range: what
    /// a download must be before it replaces the copy in use.
    static func isUsable(_ data: Data) -> Bool {
        var usable = false
        scan(data) { entry in
            if !usable, !entry.code.isEmpty, !entry.reverse, entry.rangeCount() > 0 { usable = true }
        }
        return usable
    }

    // MARK: - Protobuf reading

    /// One `GeoIP` message: its code, its flag, and a way to walk its ranges.
    fileprivate struct Entry {
        let code: String
        let reverse: Bool
        fileprivate let body: UnsafeBufferPointer<UInt8>

        func rangeCount() -> Int {
            var n = 0
            forEachRange { _ in n += 1 }
            return n
        }

        func ranges() -> [String] {
            var out: [String] = []
            forEachRange { out.append($0) }
            return out
        }

        private func forEachRange(_ body: (String) -> Void) {
            var reader = Reader(bytes: self.body)
            while let (field, wire) = reader.nextTag() {
                if field == 2, wire == 2 {
                    guard let slice = reader.lengthDelimited() else { return }
                    if let range = Entry.cidr(in: slice) { body(range) }
                } else if !reader.skip(wire) {
                    return
                }
            }
        }

        /// "a.b.c.d/p" for one `CIDR` message, nil for IPv6 or a prefix past 32.
        private static func cidr(in bytes: UnsafeBufferPointer<UInt8>) -> String? {
            var reader = Reader(bytes: bytes)
            var ip: UnsafeBufferPointer<UInt8>?
            var prefix: UInt64?
            while let (field, wire) = reader.nextTag() {
                if field == 1, wire == 2 {
                    guard let value = reader.lengthDelimited() else { return nil }
                    ip = value
                } else if field == 2, wire == 0 {
                    guard let value = reader.varint() else { return nil }
                    prefix = value
                } else if !reader.skip(wire) {
                    return nil
                }
            }
            guard let ip, ip.count == 4, let prefix, prefix <= 32 else { return nil }
            return "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])/\(prefix)"
        }
    }

    /// Calls `visit` for each `GeoIP` entry. The entry is valid only inside the call.
    private static func scan(_ data: Data, _ visit: (Entry) -> Void) {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var list = Reader(bytes: bytes)
            while let (field, wire) = list.nextTag() {
                guard field == 1, wire == 2 else {
                    if !list.skip(wire) { return }
                    continue
                }
                guard let body = list.lengthDelimited() else { return }
                var reader = Reader(bytes: body)
                var code = ""
                var reverse = false
                while let (f, w) = reader.nextTag() {
                    if f == 1, w == 2 {
                        guard let s = reader.lengthDelimited() else { break }
                        code = String(decoding: s, as: UTF8.self)
                    } else if f == 3, w == 0 {
                        guard let flag = reader.varint() else { break }
                        reverse = flag != 0
                    } else if !reader.skip(w) {
                        break
                    }
                }
                visit(Entry(code: code, reverse: reverse, body: body))
            }
        }
    }

    /// A cursor over protobuf wire data that stops, rather than traps, on bad input.
    fileprivate struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0

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
            return nil
        }

        /// The next field number and wire type, nil at the end or on a malformed tag.
        mutating func nextTag() -> (field: UInt64, wire: UInt64)? {
            guard position < bytes.count, let tag = varint() else { return nil }
            return (tag >> 3, tag & 7)
        }

        mutating func lengthDelimited() -> UnsafeBufferPointer<UInt8>? {
            guard let length = varint(), length <= UInt64(bytes.count - position) else { return nil }
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
            default: return false
            }
        }

        private mutating func advance(_ count: Int) -> Bool {
            guard count <= bytes.count - position else { return false }
            position += count
            return true
        }
    }
}
