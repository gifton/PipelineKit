import Foundation
import PipelineKitSecurity
import CryptoKit

/// Simple in-memory key store implementation for testing.
///
/// **Thread Safety**: This actor provides guaranteed thread safety through Swift's actor isolation.
/// All methods are actor-isolated, ensuring exclusive access to internal state without manual locking.
public actor InMemoryKeyStore: KeyStore {
    private var keys: [String: SymmetricKey] = [:]
    private var keyDates: [String: Date] = [:]
    private var _currentKeyIdentifier: String?
    
    public init() {}
    
    public var currentKey: SymmetricKey? {
        guard let identifier = _currentKeyIdentifier else { return nil }
        return keys[identifier]
    }
    
    public var currentKeyIdentifier: String? {
        _currentKeyIdentifier
    }
    
    public func store(key: SymmetricKey, identifier: String) {
        keys[identifier] = key
        keyDates[identifier] = Date()
        _currentKeyIdentifier = identifier
    }
    
    public func key(for identifier: String) -> SymmetricKey? {
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
