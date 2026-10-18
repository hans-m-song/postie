import Foundation

enum RequestEditorAccordion: String, CaseIterable, Hashable, Identifiable {
    case query, path, headers, body

    var id: Self { self }
}

struct RequestEditorContentSnapshot: Equatable {
    let queryCount: Int
    let pathNames: Set<String>
}

struct RequestEditorExpansionState: Equatable {
    private(set) var expanded: Set<RequestEditorAccordion> = []
    private(set) var isInitialized = false
    private var previousContent: RequestEditorContentSnapshot?

    func isExpanded(_ section: RequestEditorAccordion) -> Bool {
        expanded.contains(section)
    }

    mutating func reconcile(
        initiallyExpanded: Set<RequestEditorAccordion>,
        content: RequestEditorContentSnapshot
    ) {
        if !isInitialized {
            expanded.formUnion(initiallyExpanded)
            isInitialized = true
        } else if let previousContent {
            if content.queryCount > previousContent.queryCount {
                expanded.insert(.query)
            }
            if !content.pathNames.isSubset(of: previousContent.pathNames) {
                expanded.insert(.path)
            }
        }
        previousContent = content
    }

    mutating func setExpanded(_ section: RequestEditorAccordion, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(section)
        } else {
            expanded.remove(section)
        }
    }
}
