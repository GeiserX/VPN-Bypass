// RulesPageBench.swift
// Opens Settings on the Rules page with a long list of made-up CIDR rules and prints how long
// the page takes to open, to redraw when RouteManager publishes, and to scroll, plus its memory.
// Skipped unless VPNB_RULES_BENCH names the number of rules:
//
//   VPNB_RULES_BENCH=1750 swift test --filter RulesPageBench
//
// It prints `BENCH ...` lines and asserts nothing about speed (a debug build on a busy runner
// is too noisy); read the numbers before and after a change to the Rules page. Nothing here
// touches the routing table: the config is the test-run temp copy.
import AppKit
import XCTest
@testable import VPNBypassCore

@MainActor
final class RulesPageBench: XCTestCase {
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    private func pump(_ view: NSView, _ n: Int = 5) {
        for _ in 0..<n {
            RunLoop.main.run(until: Date())
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }
    private func time(_ body: () -> Void) -> Double {
        let t = CFAbsoluteTimeGetCurrent(); body(); return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    func testRulesPage() throws {
        guard let value = ProcessInfo.processInfo.environment["VPNB_RULES_BENCH"], let count = Int(value), count > 0 else {
            throw XCTSkip("Set VPNB_RULES_BENCH to a number of rules, such as 1750.")
        }
        let rm = RouteManager.shared
        let saved = rm.config
        let savedOverride = rm.refreshStatusOverrideForTests
        defer {
            rm.config = saved
            rm.refreshStatusOverrideForTests = savedOverride
        }
        rm.refreshStatusOverrideForTests = {}
        let direct = Route(name: "Direct", egress: .direct)
        let vpn = Route(name: "Primary VPN", egress: .vpnDefault, vpnSelector: VPNSelector(kind: .primary))
        var cfg = rm.config
        cfg.routes = [direct, vpn]
        cfg.defaultRouteId = vpn.id
        cfg.schemaVersion = 2
        cfg.routingMode = .custom
        // Distinct /24s, as a bulk-imported country list would be.
        cfg.rules = (0..<count).map { i in
            Rule(matchType: .cidr, pattern: "\(40 + i / 65_536).\((i / 256) % 256).\(i % 256).0/24", routeId: direct.id, order: i)
        }
        rm.config = cfg
        let base = footprintMB()
        SettingsPageRequest.shared.page = .rules
        var window: NSWindow!
        let tOpen = time {
            window = SettingsWindowController.makeWindow(settingsUndo: nil)
            window.setContentSize(SettingsWindowController.defaultContentSize)
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFront(nil)
            pump(window.contentView!, 12)
        }
        let afterOpen = footprintMB()
        let tRedraw = time { for _ in 0..<20 { rm.lastUpdate = Date(); self.pump(window.contentView!, 2) } } / 20
        var tScroll = 0.0
        if let sv = scrollViews(in: window.contentView!).max(by: { $0.documentView!.frame.height < $1.documentView!.frame.height }) {
            let h = sv.documentView!.frame.height
            tScroll = time {
                for i in 1...10 {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: h * Double(i) / 12)); sv.reflectScrolledClipView(sv.contentView)
                    self.pump(window.contentView!, 2)
                }
            } / 10
            print("BENCH docHeight=\(Int(h))")
        }
        let end = footprintMB()
        print("BENCH rules=\(count) open=\(Int(tOpen))ms redraw/publish=\(Int(tRedraw))ms scroll/step=\(Int(tScroll))ms footprint base=\(Int(base))MB afterOpen=\(Int(afterOpen))MB end=\(Int(end))MB")
        window.close()
    }
}
