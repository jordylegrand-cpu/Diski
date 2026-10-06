import XCTest
@testable import Diski

final class SmokeTests: XCTestCase {
    func testHostAppLoads() {
        XCTAssertNotNil(NSApp)
    }
}
