import Foundation
import PipelineKitSecurity
@preconcurrency import CryptoKit

/// Simple in-memory key store implementation for testing.
///
/// **Thread Safety**: This actor provides guaranteed thread safety through Swift's actor isolation.
/// All methods are actor-isolated, ensuring exclusive access to internal state without manual locking.
public actor InMemoryKeyStore: KeyStore {
    private var keys: [String: SendableSymmetricKey] = [:]
    private var keyDates: [String: Date] = [:]
    private var _currentKeyIdentifier: String?
    
    public init() {}
    
    public var currentKey: SendableSymmetricKey? {
        guard let identifier = _currentKeyIdentifier else { return nil }
        return keys[identifier]
    }
    
    public var currentKeyIdentifier: String? {
        _currentKeyIdentifier
    }
    
    public func store(key: SendableSymmetricKey, identifier: String) {
        keys[identifier] = key
        keyDates[identifier] = Date()
        _currentKeyIdentifier = identifier
    }
    
    public func key(for identifier: String) -> SendableSymmetricKey? {
        keys[identifier]
    }
    
    public func removeExpiredKeys(before date: Date) {
        for (identifier, keyDate) in keyDates {
            if keyDate < date && identifier != _currentKeyIdentifier {
                keys.removeValue(forKey: identifier)
                keyDates.removeValue(forKey: identifier)
            }
        }
    }
}
