import Darwin
import dnssd
import Foundation
import VPNBypassPolicy

/// Resolves a claimed connect-by-name flow's host name on the physical interface, before anything
/// is dialled (design 3.5 step 4), so `NameAnswer.check` can refuse a name that points at a
/// protected address. `DNSServiceGetAddrInfo` with the interface's index asks that interface's own
/// resolvers, the ones a connection scoped to it would use. IPv4 only, as the re-emit path dials
/// IPv4 only. The name lives in this object until the answer arrives; it is never logged or stored.
///
/// Created, answered and cancelled on one serial queue (the relay's): `DNSServiceRefDeallocate`
/// must run on the queue the service delivers on.
@available(macOS 15, *)
final class NameLookup {
    /// A lookup that takes longer than this is answered with what arrived so far (often nothing).
    static let timeoutSeconds: Double = 5

    private let queue: DispatchQueue
    private var ref: DNSServiceRef?
    private var answers: [UInt32] = []
    /// A resolver answered, with records or a negative answer; false for a timeout or a failure.
    private var answered = false
    private var done: (([UInt32], Bool) -> Void)?
    private var retainSelf: NameLookup?

    private init(queue: DispatchQueue, done: @escaping ([UInt32], Bool) -> Void) {
        self.queue = queue
        self.done = done
    }

    /// Starts the lookup; `done` runs once on `queue` with the IPv4 answers in the order they came,
    /// empty when there were none, the lookup failed or it timed out, and whether a resolver
    /// answered at all (a negative answer counts; a timeout or a failure does not). Call on `queue`.
    static func start(_ name: String, interfaceIndex: UInt32, queue: DispatchQueue,
                      done: @escaping ([UInt32], Bool) -> Void) -> NameLookup {
        let lookup = NameLookup(queue: queue, done: done)
        lookup.retainSelf = lookup
        let context = Unmanaged.passUnretained(lookup).toOpaque()
        var ref: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
        let err = DNSServiceGetAddrInfo(&ref, flags, interfaceIndex, DNSServiceProtocol(kDNSServiceProtocol_IPv4),
                                        name, NameLookup.reply, context)
        guard err == kDNSServiceErr_NoError, let ref else {
            queue.async { lookup.finish() }
            return lookup
        }
        lookup.ref = ref
        guard DNSServiceSetDispatchQueue(ref, queue) == kDNSServiceErr_NoError else {
            // No answer would ever arrive: end now, as a lookup with no answer.
            queue.async { lookup.finish() }
            return lookup
        }
        queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak lookup] in lookup?.finish() }
        return lookup
    }

    /// Drops the lookup without calling `done`. Call on `queue`.
    func cancel() {
        done = nil
        finish()
    }

    private static let reply: DNSServiceGetAddrInfoReply = { _, flags, _, error, _, address, _, context in
        guard let context else { return }
        let lookup = Unmanaged<NameLookup>.fromOpaque(context).takeUnretainedValue()
        if error == kDNSServiceErr_NoError || error == kDNSServiceErr_NoSuchRecord || error == kDNSServiceErr_NoSuchName {
            lookup.answered = true
        }
        if error == kDNSServiceErr_NoError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
           let address, address.pointee.sa_family == sa_family_t(AF_INET) {
            let v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            lookup.answers.append(UInt32(bigEndian: v4))
        }
        // A negative answer (`NoSuchRecord`) or a failure ends the lookup too; so does the last
        // record of a batch. An answer that only arrives in a later batch is not seen; that never
        // lets a protected address be dialled, since only an answer that was checked is dialled.
        if error != kDNSServiceErr_NoError || flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
            lookup.finish()
        }
    }

    private func finish() {
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        let callback = done
        done = nil
        retainSelf = nil
        callback?(answers, answered)
    }

    /// The IPv4 addresses of the Mac's interfaces now, for `NameAnswer.tunnelNetworks`; nil when
    /// they cannot be read, so the caller fails closed rather than checking against no tunnels.
    static func interfaceAddresses() -> [InterfaceAddress]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        func v4(_ sa: UnsafeMutablePointer<sockaddr>?) -> UInt32? {
            guard let sa, sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        }
        var out: [InterfaceAddress] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let address = v4(ifa.ifa_addr) else { continue }
            let pointToPoint = Int32(ifa.ifa_flags) & IFF_POINTOPOINT != 0
            out.append(InterfaceAddress(name: String(cString: ifa.ifa_name), address: address,
                                        netmask: v4(ifa.ifa_netmask) ?? ~0,
                                        destination: pointToPoint ? v4(ifa.ifa_dstaddr) : nil))
        }
        return out
    }
}
