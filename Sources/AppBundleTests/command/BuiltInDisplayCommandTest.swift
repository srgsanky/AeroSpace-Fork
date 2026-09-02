@testable import AppBundle
import XCTest

final class BuiltInDisplayCommandTest: XCTestCase {
    func testParseBuiltInDisplayCommand() {
        assertNil(parseCommand("built-in-display").errorOrNil)
        assertNil(parseCommand("built-in-display on").errorOrNil)
        assertNil(parseCommand("built-in-display off").errorOrNil)
        assertEquals(
            parseCommand("built-in-display invalid").errorOrNil,
            "ERROR: Can't parse 'invalid'. Possible values: on|off",
        )
    }
}
