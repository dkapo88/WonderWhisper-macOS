import XCTest
@testable import WonderWhisper

final class OverlapDeduperTests: XCTestCase {
    func test_dropCount_detectsSimpleOverlap() {
        let prev = OverlapDeduper.tokens("hello world this is a test")
        let next = OverlapDeduper.tokens("this is a test of overlap")
        let drop = OverlapDeduper.dropCount(prevTokens: prev, nextTokens: next, maxK: 24)
        XCTAssertEqual(drop, 4) // "this is a test"
    }

    func test_merge_removesOverlap() {
        let prev = "We will now begin the meeting today"
        let next = "the meeting today will cover quarterly results"
        let merged = OverlapDeduper.merge(prev: prev, next: next, maxK: 24)
        XCTAssertEqual(merged, "We will now begin the meeting today will cover quarterly results")
    }

    func test_merge_handlesNoOverlap() {
        let prev = "alpha beta gamma"
        let next = "delta epsilon"
        let merged = OverlapDeduper.merge(prev: prev, next: next, maxK: 24)
        XCTAssertEqual(merged, "alpha beta gamma delta epsilon")
    }
}
