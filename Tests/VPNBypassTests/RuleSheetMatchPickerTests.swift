// RuleSheetMatchPickerTests.swift
// The Add Rule sheet's Match control must fit the sheet at its natural width. A segmented
// control is first drawn at that width, so one wider than the sheet showed past its edge for a
// moment before SwiftUI narrowed it. Drawn offscreen; nothing is routed.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class RuleSheetMatchPickerTests: XCTestCase {

    /// The Match control in whichever form the sheet shows: segments, or a menu when no
    /// segmented form fits (a language with long labels). The sheet has no other of either.
    private func matchControls(in view: NSView) -> [NSControl] {
        if view is NSSegmentedControl || view is NSPopUpButton { return [view as! NSControl] }
        return view.subviews.flatMap(matchControls)
    }

    func testTheMatchControlFitsTheSheetAtItsNaturalWidth() {
        let sheet = RuleEditorSheet(editingRule: nil, services: [], onSave: { _ in }, onCancel: {})
            .environmentObject(RouteManager.shared)
        let hosting = NSHostingView(rootView: sheet)
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()

        let controls = matchControls(in: hosting)
        XCTAssertEqual(controls.count, 1)
        let rowWidth = SheetScaffold<EmptyView>.width - 2 * (Theme.Space.page - 4)
        for control in controls {
            XCTAssertLessThanOrEqual(control.intrinsicContentSize.width, rowWidth)
        }
    }
}
