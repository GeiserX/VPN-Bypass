import XCTest
@testable import VPNBypassCore

/// The Lookups count column is sized from the biggest count shown, so a long count never
/// pushes its bar out of line and a short one never leaves a gap between bar and number.
final class LookupCountColumnTests: XCTestCase {
    private func width(_ top: Int) -> (column: CGFloat, number: CGFloat) {
        LookupRow.countColumnWidth(top: top, header: "LOOKUPS")
    }

    private func drawn(_ count: Int) -> CGFloat {
        (LookupRow.format(count) as NSString).size(withAttributes: [.font: LookupRow.countFont]).width
    }

    func testTheNumberIsAsWideAsTheBiggestCountAndNoWider() {
        for top in [3, 48, 755, 1602, 98_765, 1_234_567] {
            let number = width(top).number
            XCTAssertGreaterThanOrEqual(number, drawn(top), "\(top) must fit without shrinking")
            XCTAssertLessThan(number - drawn(top), 2, "\(top): no slack beside the number")
        }
    }

    func testEveryCountBelowTheTopFitsTheSameSlot() {
        let number = width(1602).number
        for count in [1, 9, 48, 755, 1602] {
            XCTAssertLessThanOrEqual(drawn(count), number, "\(count) under a top of 1602")
        }
    }

    func testSmallCountsGetATightSlot() {
        XCTAssertLessThan(width(48).number, width(1602).number)
        XCTAssertEqual(width(3).number, width(7).number, "same digit count, same slot")
    }

    func testTheColumnHoldsBarNumberAndHeader() {
        let header = NSAttributedString(string: "LOOKUPS", attributes: [.font: LookupRow.headerFont, .kern: 1]).size().width
        for top in [3, 48, 1602, 1_234_567] {
            let w = width(top)
            XCTAssertGreaterThanOrEqual(w.column, LookupRow.barWidth + LookupRow.barGap + w.number)
            XCTAssertGreaterThanOrEqual(w.column, header, "the header fits over a column for top \(top)")
        }
        XCTAssertEqual(width(1_234_567).column, LookupRow.barWidth + LookupRow.barGap + width(1_234_567).number,
                       "a wide count, not the header, sets the column")
    }
}
