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
            var reader = ProtoReader(bytes: self.body)
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
            var reader = ProtoReader(bytes: bytes)
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
            var list = ProtoReader(bytes: bytes)
            while let (field, wire) = list.nextTag() {
                guard field == 1, wire == 2 else {
                    if !list.skip(wire) { return }
                    continue
                }
                guard let body = list.lengthDelimited() else { return }
                var reader = ProtoReader(bytes: body)
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
}
