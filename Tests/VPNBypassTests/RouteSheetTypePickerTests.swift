// RouteSheetTypePickerTests.swift
// The Add Route sheet's Type control must fit the sheet at its natural width. A segmented
// control is first drawn at that width, so one wider than the sheet showed past its edge for a
// moment before SwiftUI narrowed it. Drawn offscreen; nothing is routed.

import AppKit
import SwiftUI
import XCTest
@testable import VPNBypassCore

@MainActor
final class RouteSheetTypePickerTests: XCTestCase {

    /// The Type control in whichever form the sheet shows: segments, or the menu fallback.
    /// The sheet has no other of either until a type that brings its own picker is chosen.
    private func typeControls(in view: NSView) -> [NSControl] {
        if view is NSSegmentedControl || view is NSPopUpButton { return [view as! NSControl] }
        return view.subviews.flatMap(typeControls)
    }

    /// Draws the sheet and returns its one Type control, after checking it fits the row.
    private func typeControl(editing route: Route?, file: StaticString = #filePath, line: UInt = #line) -> NSControl? {
        let sheet = RouteEditorSheet(editingRoute: route, selectableLinks: [], onSave: { _ in }, onCancel: {})
        let hosting = NSHostingView(rootView: sheet)
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()

        let controls = typeControls(in: hosting)
        XCTAssertEqual(controls.count, 1, file: file, line: line)
        let rowWidth = SheetScaffold<EmptyView>.width - 2 * (Theme.Space.page - 4)
        for control in controls {
            XCTAssertLessThanOrEqual(control.intrinsicContentSize.width, rowWidth, file: file, line: line)
        }
        return controls.first
    }

    // The test runner has no translations, so these are the English sheet.

    /// All five types stay in view as small segments; the menu is the fallback for a sixth
    /// type or a longer translation.
    func testTheTypeControlFitsTheSheetAtItsNaturalWidth() {
        let segments = typeControl(editing: nil) as? NSSegmentedControl
        XCTAssertNotNil(segments, "English shows the Type choices as segments, not a menu")
        XCTAssertEqual(segments?.segmentCount, 5)
        XCTAssertEqual(segments?.controlSize, .small)
    }

    /// A route from a newer version adds a sixth choice, Unknown. Six small segments do not
    /// fit, so this rare sheet shows the menu, inside the sheet.
    func testTheTypeControlFitsWhenEditingAnUnsupportedRoute() {
        let control = typeControl(editing: Route(name: "Newer", egress: .unsupported))
        XCTAssertTrue(control is NSPopUpButton, "six types fall back to the menu")
    }
}
