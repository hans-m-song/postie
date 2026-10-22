import Combine
import Foundation

@MainActor
final class ResponseBodyResource: ObservableObject {
    enum Origin: Hashable {
        case live(UUID)
        case history(UUID)
        case snapshot(UUID)
    }

    let id = UUID()
    let url: URL
    let origin: Origin
    @Published private(set) var isValid = true
    private var invalidationHandlers: [UUID: () -> Void] = [:]
    private let release: @MainActor () async -> Void
    private var releaseTask: Task<Void, Never>?

    init(url: URL, origin: Origin, release: @escaping @MainActor () async -> Void = {}) {
        self.url = url
        self.origin = origin
        self.release = release
    }

    func registerInvalidation(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        guard isValid else {
            handler()
            return id
        }
        invalidationHandlers[id] = handler
        return id
    }

    func removeInvalidationHandler(_ id: UUID) {
        invalidationHandlers.removeValue(forKey: id)
    }

    func invalidate() async {
        if let releaseTask {
            await releaseTask.value
            return
        }
        isValid = false
        let handlers = Array(invalidationHandlers.values)
        invalidationHandlers.removeAll()
        for handler in handlers { handler() }
        let release = release
        let task = Task { @MainActor in await release() }
        releaseTask = task
        await task.value
    }
}
