import Foundation

/// What differs between the products built from this source: Ambulando, and Grandparent Chat (the restricted
/// family-conversation app, built with the `GRANDPARENT_CHAT` compilation condition). Everything else is shared.
enum Product {
    #if GRANDPARENT_CHAT
    static let name = "Grandparent Chat"
    static let isGrandparentChat = true
    static let refreshTaskIdentifier = "studio.otherstuff.grandparentchat.refresh"
    static let testBundleIdentifier = "studio.otherstuff.grandparentchat.test"
    #else
    static let name = "Ambulando"
    static let isGrandparentChat = false
    static let refreshTaskIdentifier = "studio.otherstuff.ambulando.native.refresh"
    static let testBundleIdentifier = "studio.otherstuff.ambulando.native.test"
    #endif
}
