import XCTest
import PostieCore
@testable import PostieApp

final class HeaderPresentationTests: XCTestCase {
    func testAuthenticationRowStaysMaskedUntilExplicitReveal() async throws {
        let revealProbe = RevealProbe()
        let authentication = RequestAuthentication(
            kind: .apiKey,
            apiKeyHeaderName: "X-Service-Key",
            apiKey: SecretEnvelope(combined: "encrypted-service-key")
        )

        let row = try XCTUnwrap(HeaderPresentation.authenticationRow(
            authentication: authentication,
            source: .collectionAuth,
            requestHeaders: [],
            availableVariables: ["region"],
            onReveal: { await revealProbe.reveal() },
            onOpenSource: {}
        ))

        XCTAssertEqual(row.name, "X-Service-Key")
        XCTAssertEqual(row.maskedValue, "••••••••")
        XCTAssertEqual(row.source, .collectionAuth)
        XCTAssertEqual(row.status, "Effective")
        XCTAssertNotNil(row.onReveal)

        let callsBeforeReveal = await revealProbe.callCount()
        XCTAssertEqual(callsBeforeReveal, 0)

        let reveal = try XCTUnwrap(row.onReveal)
        let revealedValue = try await reveal()
        let callsAfterReveal = await revealProbe.callCount()
        XCTAssertEqual(revealedValue, "synthetic decrypted key")
        XCTAssertEqual(callsAfterReveal, 1)
    }

    func testEnabledManualAuthHeaderOverridesDerivedAuthAndDisabledOneDoesNot() throws {
        let authentication = RequestAuthentication(
            kind: .bearer,
            token: SecretEnvelope(combined: "encrypted-token")
        )

        let overridden = try makeAuthenticationRow(
            authentication: authentication,
            requestHeaders: [HTTPField(name: "authorization", value: "manual value")]
        )
        let disabled = try makeAuthenticationRow(
            authentication: authentication,
            requestHeaders: [HTTPField(name: "Authorization", value: "manual value", isEnabled: false)]
        )

        XCTAssertEqual(overridden.source, .requestAuth)
        XCTAssertEqual(overridden.status, "Overridden")
        XCTAssertEqual(disabled.status, "Effective")
        XCTAssertEqual(disabled.maskedValue, "Bearer ••••••••")
    }

    func testTemplatedMissingAndInvalidAPIKeyNamesCannotReveal() throws {
        let templated = try makeAuthenticationRow(
            authentication: RequestAuthentication(
                kind: .apiKey,
                apiKeyHeaderName: "{{credentialHeader}}",
                apiKey: SecretEnvelope(combined: "encrypted-api-key")
            ),
            requestHeaders: []
        )
        let missing = try makeAuthenticationRow(
            authentication: RequestAuthentication(kind: .apiKey, apiKey: SecretEnvelope(combined: "encrypted-api-key")),
            requestHeaders: []
        )
        let invalid = try makeAuthenticationRow(
            authentication: RequestAuthentication(
                kind: .apiKey,
                apiKeyHeaderName: "X Service Key",
                apiKey: SecretEnvelope(combined: "encrypted-api-key")
            ),
            requestHeaders: []
        )

        XCTAssertEqual(templated.status, "Disabled")
        XCTAssertNil(templated.onReveal)
        XCTAssertEqual(missing.name, "API key header")
        XCTAssertEqual(missing.status, "Pending")
        XCTAssertNil(missing.onReveal)
        XCTAssertEqual(invalid.status, "Disabled")
        XCTAssertNil(invalid.onReveal)
    }

    func testResetKeyChangesAfterAuthenticationEditsAndRequestNavigation() {
        let identity = RequestIdentity(collectionID: UUID(), requestID: UUID())
        let request = HTTPRequestConfiguration(authentication: RequestAuthentication(
            kind: .bearer,
            token: SecretEnvelope(combined: "encrypted-token")
        ))
        let resetKey = makeResetKey(identity: identity, request: request)

        var editedRequest = request
        editedRequest.authentication.token = SecretEnvelope(combined: "updated-encrypted-token")
        let editedKey = makeResetKey(identity: identity, request: editedRequest)
        let navigatedKey = makeResetKey(
            identity: RequestIdentity(collectionID: UUID(), requestID: UUID()),
            request: request
        )

        XCTAssertNotEqual(resetKey, editedKey)
        XCTAssertNotEqual(resetKey, navigatedKey)
    }

    private func makeAuthenticationRow(
        authentication: RequestAuthentication,
        requestHeaders: [HTTPField]
    ) throws -> DerivedHeaderRowPresentation {
        try XCTUnwrap(HeaderPresentation.authenticationRow(
            authentication: authentication,
            source: .requestAuth,
            requestHeaders: requestHeaders,
            availableVariables: [],
            onReveal: { "synthetic revealed value" },
            onOpenSource: {}
        ))
    }

    private func makeResetKey(
        identity: RequestIdentity,
        request: HTTPRequestConfiguration
    ) -> HeaderPreviewResetKey {
        HeaderPreviewResetKey(
            identity: identity,
            request: request,
            collectionHeaders: [],
            collectionAuthentication: nil,
            variableContext: VariableContext()
        )
    }
}

private actor RevealProbe {
    private var calls = 0

    func reveal() -> String {
        calls += 1
        return "synthetic decrypted key"
    }

    func callCount() -> Int {
        calls
    }
}
