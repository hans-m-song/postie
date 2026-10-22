import Foundation

public struct SnapshotGrouping: Equatable, Sendable {
    public var identity: RequestIdentity
    public var collectionName: String
    public var requestName: String

    public init(identity: RequestIdentity, collectionName: String, requestName: String) {
        self.identity = identity
        self.collectionName = collectionName
        self.requestName = requestName
    }
}

public struct WorkspaceIndex: Equatable, Sendable {
    public var collectionOrder: [UUID]
    public var snapshotGroupingOverrides: [UUID: SnapshotGrouping]
    public var mcpExcludedSnapshotIDs: Set<UUID>

    public init(
        collectionOrder: [UUID] = [],
        snapshotGroupingOverrides: [UUID: SnapshotGrouping] = [:],
        mcpExcludedSnapshotIDs: Set<UUID> = []
    ) {
        self.collectionOrder = collectionOrder
        self.snapshotGroupingOverrides = snapshotGroupingOverrides
        self.mcpExcludedSnapshotIDs = mcpExcludedSnapshotIDs
    }
}

public struct RequestMoveResult: Equatable, Sendable {
    public let oldIdentity: RequestIdentity
    public let newIdentity: RequestIdentity
    public let workspaceIndex: WorkspaceIndex

    public init(oldIdentity: RequestIdentity, newIdentity: RequestIdentity, workspaceIndex: WorkspaceIndex) {
        self.oldIdentity = oldIdentity
        self.newIdentity = newIdentity
        self.workspaceIndex = workspaceIndex
    }
}
