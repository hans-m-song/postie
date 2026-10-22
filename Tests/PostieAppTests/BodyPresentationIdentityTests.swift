import Foundation
import XCTest
import PostieCore
@testable import PostieApp

final class BodyPresentationIdentityTests: XCTestCase {
    func testIdentityIncludesBodySyntaxAndPrettyEligibility() {
        let bodyID = BodyPresentationBodyID(runID: UUID(), url: URL(fileURLWithPath: "/tmp/response.body"))
        let identity = BodyPresentationIdentity(
            bodyID: bodyID,
            syntax: .html,
            isPrettySelected: true,
            isBinary: false
        )

        XCTAssertTrue(identity.isEligible)
        XCTAssertNotEqual(
            identity,
            BodyPresentationIdentity(
                bodyID: BodyPresentationBodyID(runID: UUID(), url: bodyID.url),
                syntax: .html,
                isPrettySelected: true,
                isBinary: false
            )
        )
        XCTAssertNotEqual(
            identity,
            BodyPresentationIdentity(
                bodyID: bodyID,
                syntax: .xml,
                isPrettySelected: true,
                isBinary: false
            )
        )
        XCTAssertNotEqual(
            identity,
            BodyPresentationIdentity(
                bodyID: bodyID,
                syntax: .html,
                isPrettySelected: false,
                isBinary: false
            )
        )
    }

    func testPrettyEligibilityRequiresSupportedSyntaxAndTextPreview() {
        let bodyID = BodyPresentationBodyID(runID: UUID(), url: URL(fileURLWithPath: "/tmp/response.body"))

        XCTAssertFalse(
            BodyPresentationIdentity(
                bodyID: bodyID,
                syntax: .none,
                isPrettySelected: true,
                isBinary: false
            ).isEligible
        )
        XCTAssertFalse(
            BodyPresentationIdentity(
                bodyID: bodyID,
                syntax: .xml,
                isPrettySelected: true,
                isBinary: true
            ).isEligible
        )
        XCTAssertFalse(
            BodyPresentationIdentity(
                bodyID: bodyID,
                syntax: .json,
                isPrettySelected: true,
                isBinary: nil
            ).isEligible
        )
    }

    func testSupportedSyntaxDefaultsToPretty() {
        for syntax in [BodySyntax.json, .html, .xml] {
            XCTAssertTrue(BodyPresentationPolicy.defaultsToPretty(for: syntax))
        }
        XCTAssertFalse(BodyPresentationPolicy.defaultsToPretty(for: .none))
    }
}
