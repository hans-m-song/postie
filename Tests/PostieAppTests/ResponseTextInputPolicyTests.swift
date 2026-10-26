import Foundation
import XCTest
@testable import PostieApp

final class ResponseTextInputPolicyTests: XCTestCase {
    func testLogicalLineThresholdUsesUTF16UnitsAndAllowsTheLimit() {
        let limit = ResponseTextInputPolicy.maximumLogicalLineUTF16Length
        let exactLimit = String(repeating: "x", count: limit - 2) + "🙂"
        let overLimit = String(repeating: "x", count: limit - 1) + "🙂"

        XCTAssertEqual(limit, 20_000)
        XCTAssertEqual((exactLimit as NSString).length, limit)
        XCTAssertEqual((overLimit as NSString).length, limit + 1)
        XCTAssertLessThan(exactLimit.utf8.count, overLimit.utf8.count)
        assertReady(ResponseTextInputPolicy.inspect(exactLimit), textUTF16Length: limit)
        assertLongLinePaused(ResponseTextInputPolicy.inspect(overLimit))
    }

    func testLFAndCRLFResetTheLogicalLineLength() {
        let line = String(repeating: "x", count: ResponseTextInputPolicy.maximumLogicalLineUTF16Length)
        let lfInput = line + "\n" + line
        let crlfInput = line + "\r\n" + line

        assertReady(ResponseTextInputPolicy.inspect(lfInput), textUTF16Length: (lfInput as NSString).length)
        assertReady(ResponseTextInputPolicy.inspect(crlfInput), textUTF16Length: (crlfInput as NSString).length)
    }

    func testByteLimitStillPausesManyShortLines() {
        let line = String(repeating: "x", count: 100) + "\n"
        let input = String(
            repeating: line,
            count: SyntaxHighlighting.maximumInputBytes / line.utf8.count + 1
        )

        XCTAssertGreaterThan(input.utf8.count, SyntaxHighlighting.maximumInputBytes)
        assertByteLimitPaused(ResponseTextInputPolicy.inspect(input))
    }

    private func assertReady(
        _ inspection: ResponseTextInputPolicy.Inspection,
        textUTF16Length: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .ready(actualLength) = inspection else {
            XCTFail("Expected ready input, received another inspection result", file: file, line: line)
            return
        }
        XCTAssertEqual(actualLength, textUTF16Length, file: file, line: line)
    }

    private func assertLongLinePaused(
        _ inspection: ResponseTextInputPolicy.Inspection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .paused(.longLine) = inspection else {
            XCTFail("Expected paused input, received another inspection result", file: file, line: line)
            return
        }
    }

    private func assertByteLimitPaused(
        _ inspection: ResponseTextInputPolicy.Inspection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .paused(.byteLimit) = inspection else {
            XCTFail("Expected paused input, received another inspection result", file: file, line: line)
            return
        }
    }
}
