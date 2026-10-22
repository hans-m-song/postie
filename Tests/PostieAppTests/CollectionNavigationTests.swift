import Foundation
import XCTest
import PostieCore
@testable import PostieApp

@MainActor
final class CollectionNavigationTests: XCTestCase {
    func testCollectionStartsWithRequestsAndKeepsConfigurationSectionsNavigable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostieCollectionNavigationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            arguments: [
                "PostieTests",
                "--data-directory", root.appendingPathComponent("data", isDirectory: true).path,
                "--body-directory", root.appendingPathComponent("bodies", isDirectory: true).path,
            ],
            secretVault: SecretVault(keyStore: CollectionNavigationKeyStore())
        )
        do {
            await model.createCollection(name: "Navigation")
            let collectionID = try XCTUnwrap(model.collections.first?.id)

            model.showCollection(collectionID)
            XCTAssertEqual(model.collectionEditorSection, .requests)

            try await waitUntil {
                model.canEditVariables(.collection(collectionID))
            }
            try model.setPlainVariable(name: "host", value: "example.test", owner: .collection(collectionID))
            let definition = try XCTUnwrap(
                model.variableInspection(named: "host", in: .collection(collectionID))
            )
            model.showVariableDefinition(definition)
            XCTAssertEqual(model.selectedCollectionID, collectionID)
            XCTAssertEqual(model.collectionEditorSection, .variables)

            for section in [CollectionEditorSection.headers, .authentication, .settings] {
                model.showCollection(collectionID, section: section)
                XCTAssertEqual(model.selectedCollectionID, collectionID)
                XCTAssertEqual(model.collectionEditorSection, section)
            }
        } catch {
            _ = await model.prepareForTermination()
            throw error
        }

        let terminated = await model.prepareForTermination()
        XCTAssertTrue(terminated)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for collection variables to become editable.")
    }
}

private final class CollectionNavigationKeyStore: ApplicationKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data? = Data(repeating: 0x42, count: 32)

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    func createKey(_ proposedKey: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let key { return key }
        key = proposedKey
        return proposedKey
    }
}
