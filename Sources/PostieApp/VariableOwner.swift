import Foundation
import PostieCore

enum VariableOwner: Hashable {
    case global
    case collection(UUID)
    case request(RequestIdentity)
}

enum AuthenticationSecretField: Hashable {
    case password
    case token
    case apiKey
}
