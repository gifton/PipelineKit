import Foundation
import PipelineKitSecurity
#if canImport(CryptoKit)
@preconcurrency import CryptoKit
#else
@preconcurrency import Crypto
#endif

/// Simple in-memory key store implementation for testing.
///
/// Key storage and current snapshot publication occur in the same actor turn.
/// Snapshot identity is exercised by `InMemoryKeyStoreTests.testSnapshotKeyMatchesIdentifierDuringConcurrentStores`.
public actor InMemoryKeyStore: KeyStore {
    private var keys: [String: SendableSymmetricKey] = [:]
    private var keyDates: [String: Date] = [:]
    public private(set) var currentKeySnapshot: EncryptionKeySnapshot?
    
    public init() {}
    
    public func store(key: SendableSymmetricKey, identifier: String) {
        keys[identifier] = key
        keyDates[identifier] = Date()
        currentKeySnapshot = EncryptionKeySnapshot(key: key, identifier: identifier)
    }
    
    public func key(for identifier: String) -> SendableSymmetricKey? {
        keys[identifier]
    }
    
    public func removeExpiredKeys(before date: Date) {
        for (identifier, keyDate) in keyDates {
            if keyDate < date && identifier != currentKeySnapshot?.identifier {
                keys.removeValue(forKey: identifier)
                keyDates.removeValue(forKey: identifier)
            }
        }
    }
}
