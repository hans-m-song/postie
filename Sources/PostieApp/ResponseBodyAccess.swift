import Foundation

enum ResponseBodyAccessError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The response body is no longer available."
    }
}
