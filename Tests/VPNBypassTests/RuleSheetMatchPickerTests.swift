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

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The Match choices in each language the app ships; `.main` has no translations here.
    private func bundles() throws -> [(String, Bundle)] {
        try [("en", .main)] + ["es", "fr"].map { language in
            (language, try XCTUnwrap(Bundle(url: Self.root.appendingPathComponent("Sources/VPNBypassCore/Resources/\(language).lproj"))))
        }
    }

    /// The Match control in whichever form the sheet shows: segments, or a menu when no
    /// segmented form fits (a language with long labels). The sheet has no other of either,
    /// except the list sheet's own menu, which comes after it.
    private func matchControls(in view: NSView) -> [NSControl] {
        if view is NSSegmentedControl || view is NSPopUpButton { return [view as! NSControl] }
        return view.subviews.flatMap(matchControls)
    }

    /// Draws the sheet and returns its Match control, after checking every control fits the row.
    private func matchControl(newList: UUID? = nil, bundle: Bundle, language: String,
                              file: StaticString = #filePath, line: UInt = #line) -> NSControl? {
        let sheet = RuleEditorSheet(editingRule: nil, services: [], newList: newList, bundle: bundle,
                                    onSave: { _ in }, onCancel: {})
            .environmentObject(RouteManager.shared)
        let hosting = NSHostingView(rootView: sheet)
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()

        let controls = matchControls(in: hosting)
        XCTAssertFalse(controls.isEmpty, file: file, line: line)
        let rowWidth = SheetScaffold<EmptyView>.width - 2 * (Theme.Space.page - 4)
        for control in controls {
            XCTAssertLessThanOrEqual(control.intrinsicContentSize.width, rowWidth,
                                     "\(language): a control is wider than the sheet", file: file, line: line)
        }
        return controls.first
    }

    func testTheMatchControlFitsTheSheetAtItsNaturalWidth() throws {
        // English keeps all six choices in view as small segments; only longer translations fall
        // back to the menu.
        let segments = matchControl(bundle: .main, language: "en") as? NSSegmentedControl
        XCTAssertNotNil(segments, "English shows the Match choices as segments, not a menu")
        XCTAssertEqual(segments?.segmentCount, 6, "List is not a choice of the Add Rule sheet")
        XCTAssertEqual(segments?.controlSize, .small)

        for (language, bundle) in try bundles() {
            _ = matchControl(bundle: bundle, language: language)
        }
    }

    /// Add List… opens on a list: List is a seventh choice there, and the control still fits, in
    /// every language.
    func testTheListSheetsMatchControlFitsInEveryLanguage() throws {
        for (language, bundle) in try bundles() {
            let control = matchControl(newList: UUID(), bundle: bundle, language: language)
            if let segments = control as? NSSegmentedControl {
                XCTAssertEqual(segments.segmentCount, 7, language)
            } else {
                XCTAssertTrue(control is NSPopUpButton, "\(language): no Match control")
            }
        }
    }
}
