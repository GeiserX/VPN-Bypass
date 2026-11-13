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

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segmentedControls)
    }

    func testTheMatchControlFitsTheSheetAtItsNaturalWidth() {
        let sheet = RuleEditorSheet(editingRule: nil, services: [], onSave: { _ in }, onCancel: {})
            .environmentObject(RouteManager.shared)
        let hosting = NSHostingView(rootView: sheet)
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()

        let controls = segmentedControls(in: hosting)
        XCTAssertEqual(controls.count, 1)
        let rowWidth = SheetScaffold<EmptyView>.width - 2 * (Theme.Space.page - 4)
        for control in controls {
            XCTAssertLessThanOrEqual(control.intrinsicContentSize.width, rowWidth)
        }
    }
}
