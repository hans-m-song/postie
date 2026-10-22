import Foundation
import PostieCore

enum ResponseBodySource {
    case live(HTTPResponseRecord)
    case history(UUID, HTTPResponseRecord)
    case snapshot(UUID, HTTPResponseRecord)

    var response: HTTPResponseRecord {
        switch self {
        case let .live(response), let .history(_, response), let .snapshot(_, response): response
        }
    }
}
