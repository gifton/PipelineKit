/// An immutable encryption key and the identifier bound to that key version.
public struct EncryptionKeySnapshot: Sendable {
    /// The encryption key captured for this version.
    public let key: SendableSymmetricKey
    /// The key-store identifier used to retrieve this key version.
    public let identifier: String

    /// Pairs an encryption key with the identifier supplied by its store.
    ///
    /// - Parameters:
    ///   - key: The encryption key to retain in the snapshot.
    ///   - identifier: The store's identifier for this key version.
    public init(key: SendableSymmetricKey, identifier: String) {
        self.key = key
        self.identifier = identifier
    }
}
