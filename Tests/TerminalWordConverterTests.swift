import XCTest
import AppKit

final class TerminalWordConverterTests: XCTestCase {

    // MARK: - parseLastLine

    func testParseLastLine_simple() {
        let result = TerminalWordConverter.parseLastLine(from: "hello\nworld")
        XCTAssertEqual(result, "world")
    }

    func testParseLastLine_skipsBlank() {
        let result = TerminalWordConverter.parseLastLine(from: "hello\nworld\n  \n")
        XCTAssertEqual(result, "world")
    }

    func testParseLastLine_allBlank() {
        XCTAssertNil(TerminalWordConverter.parseLastLine(from: "\n  \n\t"))
    }

    func testParseLastLine_singleLine() {
        let result = TerminalWordConverter.parseLastLine(from: "prompt > руддщ")
        XCTAssertEqual(result, "prompt > руддщ")
    }

    func testParseLastLine_withTerminalPrompt() {
        let result = TerminalWordConverter.parseLastLine(from: "gluck@gluckBook ~ % руддщ\n")
        XCTAssertEqual(result, "gluck@gluckBook ~ % руддщ")
    }

    // MARK: - extractLastWord

    func testExtractLastWord_simple() {
        let result = TerminalWordConverter.extractLastWord(from: "hello world")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1, "world")
    }

    func testExtractLastWord_singleWord() {
        let result = TerminalWordConverter.extractLastWord(from: "hello")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1, "hello")
    }

    func testExtractLastWord_trailingSpace() {
        let result = TerminalWordConverter.extractLastWord(from: "hello ")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1, "hello")
    }

    func testExtractLastWord_empty() {
        XCTAssertNil(TerminalWordConverter.extractLastWord(from: ""))
    }

    func testExtractLastWord_onlySpaces() {
        XCTAssertNil(TerminalWordConverter.extractLastWord(from: "   "))
    }

    func testExtractLastWord_rangeCorrectness() {
        let line = "echo руддщ"
        guard let (range, word) = TerminalWordConverter.extractLastWord(from: line) else {
            XCTFail("expected word"); return
        }
        let chars = Array(line)
        XCTAssertEqual(String(chars[range]), word)
    }

    func testExtractLastWord_cyrillic() {
        let result = TerminalWordConverter.extractLastWord(from: "gluck@gluckBook ~ % руддщ")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1, "руддщ")
    }
}
