import Foundation
import XCTest
import PostieCore
@testable import PostieApp

@MainActor
final class WorkspacePaletteNavigationTests: XCTestCase {
    func testOpeningSearchCanChangeModeWhileAlreadyPresented() async throws {
        try await withModel { model in
            let initialFocusRequest = model.workspaceSearchFocusRequestID
            model.showRequestSearch(query: ">")
            XCTAssertTrue(model.showsRequestSearch)
            XCTAssertEqual(model.workspaceSearchQuery, ">")
            XCTAssertNotEqual(model.workspaceSearchFocusRequestID, initialFocusRequest)
            let previousFocusRequest = model.workspaceSearchFocusRequestID
            model.workspaceSearchQuery = "$host"
            model.showRequestSearch()
            XCTAssertTrue(model.showsRequestSearch)
            XCTAssertEqual(model.workspaceSearchQuery, "")
            XCTAssertNotEqual(model.workspaceSearchFocusRequestID, previousFocusRequest)
            model.showRequestSearch(query: "@")
            XCTAssertEqual(model.workspaceSearchQuery, "@")
        }
    }

    func testVariableNavigationUsesExactOwnerAndRejectsStaleResults() async throws {
        try await withModel { model in
            await model.createCollection(name: "Palette fixture")
            let collectionID = try XCTUnwrap(model.collections.first?.id)
            await model.createRequest(in: collectionID, name: "Palette request")
            let identity = try XCTUnwrap(model.selectedIdentity)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.canEditVariables(.request(identity)) {
                guard ContinuousClock.now < deadline else { throw PaletteNavigationError.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
            for owner in [VariableOwner.global, .collection(collectionID), .request(identity)] {
                try model.setPlainVariable(name: "shared", value: "fixture", owner: owner)
            }

            model.showGlobalSettings()
            model.showWorkspaceVariable(owner: .request(identity), name: "shared")
            XCTAssertEqual(model.selectedIdentity, identity)
            XCTAssertEqual(model.requestEditorSection(for: identity), .variables)
            XCTAssertEqual(model.variableDefinitionRequest?.owner, .request(identity))
            XCTAssertEqual(model.variableDefinitionRequest?.name, "shared")
            XCTAssertFalse(model.showsGlobalSettings)

            model.showWorkspaceVariable(owner: .collection(collectionID), name: "shared")
            XCTAssertEqual(model.selectedCollectionID, collectionID)
            XCTAssertEqual(model.collectionEditorSection, .variables)

            model.showWorkspaceVariable(owner: .global, name: "shared")
            XCTAssertTrue(model.showsGlobalVariables)

            model.showGlobalSettings()
            model.showWorkspaceVariable(owner: .request(identity), name: "missing")
            model.showWorkspaceVariable(owner: .collection(UUID()), name: "shared")
            XCTAssertTrue(model.showsGlobalSettings)
            XCTAssertNil(model.variableDefinitionRequest)
            XCTAssertTrue(model.activeRuns.isEmpty)
        }
    }

    private func withModel(_ operation: (AppModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PostiePalette-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            arguments: [
                "PostieTests", "--data-directory", root.appendingPathComponent("data").path,
                "--body-directory", root.appendingPathComponent("bodies").path,
            ],
            secretVault: SecretVault(keyStore: PaletteNavigationKeyStore())
        )
        do {
            try await operation(model)
        } catch {
            _ = await model.prepareForTermination()
            throw error
        }
        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }
}

private enum PaletteNavigationError: Error {
    case timedOut
}

private struct PaletteNavigationKeyStore: ApplicationKeyStore {
    func loadKey() throws -> Data? { Data(repeating: 0x37, count: 32) }
    func createKey(_ proposedKey: Data) throws -> Data { Data(repeating: 0x37, count: 32) }
}
