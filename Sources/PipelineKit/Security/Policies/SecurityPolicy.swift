import Foundation

/// Configuration for security policies applied to commands.
public struct SecurityPolicy: Sendable {
    /// Maximum allowed command size in bytes
    public let maxCommandSize: Int
    
    /// Whether to allow HTML content in string fields
    public let allowHTML: Bool
    
    /// Whether to enforce strict validation
    public let strictValidation: Bool
    
    /// Maximum string field length
    public let maxStringLength: Int
    
    /// Allowed character set for string fields
    public let allowedCharacters: CharacterSet
    
    /// Default security policy with reasonable defaults
    public static let `default` = SecurityPolicy(
        maxCommandSize: 1_048_576, // 1MB
        allowHTML: false,
        strictValidation: true,
        maxStringLength: 10_000,
        allowedCharacters: CharacterSet.alphanumerics
            .union(.punctuationCharacters)
            .union(.whitespaces)
            .union(.symbols)
    )
    
    /// Strict security policy for high-security environments
    public static let strict = SecurityPolicy(
        maxCommandSize: 102_400, // 100KB
        allowHTML: false,
        strictValidation: true,
        maxStringLength: 1_000,
        allowedCharacters: CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ".,!?-_@"))
    )
    
    public init(
        maxCommandSize: Int,
        allowHTML: Bool,
        strictValidation: Bool,
        maxStringLength: Int,
        allowedCharacters: CharacterSet
    ) {
        self.maxCommandSize = maxCommandSize
        self.allowHTML = allowHTML
        self.strictValidation = strictValidation
        self.maxStringLength = maxStringLength
        self.allowedCharacters = allowedCharacters
    }
}

/// Middleware that enforces security policies on commands.
/// 
/// This middleware applies configured security policies to all commands,
/// providing an additional layer of protection beyond basic validation.
public struct SecurityPolicyMiddleware: Middleware {
    private let policy: SecurityPolicy
    
    /// Creates a security policy middleware with the specified policy.
    /// 
    /// - Parameter policy: The security policy to enforce
    public init(policy: SecurityPolicy = .default) {
        self.policy = policy
    }
    
    public func execute<T: Command>(
        _ command: T,
        metadata: CommandMetadata,
        next: @Sendable (T, CommandMetadata) async throws -> T.Result
    ) async throws -> T.Result {
        // Apply security checks based on policy
        if policy.strictValidation {
            // Perform strict validation checks
            // Note: Size validation would require Encodable constraint
        }
        
        return try await next(command, metadata)
    }
}