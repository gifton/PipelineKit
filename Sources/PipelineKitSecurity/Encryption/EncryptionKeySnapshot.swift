/// An immutable encryption key and the identifier bound to that key version.
public struct EncryptionKeySnapshot: Sendable {
    public let key: SendableSymmetricKey
    public let identifier: String

    public init(key: SendableSymmetricKey, identifier: String) {
        self.key = key
        self.identifier = identifier
    }
}
