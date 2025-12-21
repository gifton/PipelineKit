import Foundation
import PipelineKit

/// Protocol for commands that support security validation
public protocol SecurityValidatable {
    /// Validates the command against the security policy
    /// - Parameter policy: The security policy to validate against
    /// - Throws: SecurityPolicyError if validation fails
    func validate(against policy: SecurityPolicy) throws
}


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
    public let priority: ExecutionPriority = .custom
    private let policy: SecurityPolicy
    
    /// Creates a security policy middleware with the specified policy.
    /// 
    /// - Parameter policy: The security policy to enforce
    public init(policy: SecurityPolicy = .default) {
        self.policy = policy
    }
    
    public func execute<T: Command>(
        _ command: T,
        context: CommandContext,
        next: @Sendable (T, CommandContext) async throws -> T.Result
    ) async throws -> T.Result {
        // If command implements SecurityValidatable, use its validation
        if let validatable = command as? any SecurityValidatable {
            try validatable.validate(against: policy)
        } else if policy.strictValidation {
            // For non-validatable commands, use reflection-based validation
            try validateUsingReflection(command)
        }
        
        return try await next(command, context)
    }
    
    /// Validates a command using reflection to inspect its properties
    private func validateUsingReflection<T>(_ command: T) throws {
        let mirror = Mirror(reflecting: command)
        
        // Estimate command size (this is approximate)
        let estimatedSize = estimateSize(of: command)
        if estimatedSize > policy.maxCommandSize {
            throw PipelineError.securityPolicy(reason: .commandTooLarge(
                size: estimatedSize,
                maxSize: policy.maxCommandSize
            ))
        }
        
        // Validate each property
        try validateMirror(mirror, path: "")
    }
    
    /// Recursively validates properties using reflection
    private func validateMirror(_ mirror: Mirror, path: String) throws {
        for child in mirror.children {
            let fieldName = child.label ?? "unknown"
            let fieldPath = path.isEmpty ? fieldName : "\(path).\(fieldName)"
            
            // Validate strings
            if let stringValue = child.value as? String {
                try validateString(stringValue, field: fieldPath)
            }
            // Validate optional strings
            else if let optionalString = child.value as? String? {
                if let stringValue = optionalString {
                    try validateString(stringValue, field: fieldPath)
                }
            }
            // Validate arrays of strings
            else if let stringArray = child.value as? [String] {
                for (index, stringValue) in stringArray.enumerated() {
                    try validateString(stringValue, field: "\(fieldPath)[\(index)]")
                }
            }
            // Recursively validate nested objects
            else if !isSimpleType(child.value) {
                let childMirror = Mirror(reflecting: child.value)
                if !childMirror.children.isEmpty {
                    try validateMirror(childMirror, path: fieldPath)
                }
            }
        }
    }
    
    /// Validates a string value against the security policy
    private func validateString(_ value: String, field: String) throws {
        // Check length
        if value.count > policy.maxStringLength {
            throw PipelineError.securityPolicy(reason: .stringTooLong(
                field: field,
                length: value.count,
                maxLength: policy.maxStringLength
            ))
        }
        
        // Check for HTML content
        if !policy.allowHTML && containsHTML(value) {
            throw PipelineError.securityPolicy(reason: .htmlContentNotAllowed(field: field))
        }
        
        // Check allowed characters
        let invalidChars = value.unicodeScalars.filter { scalar in
            !policy.allowedCharacters.contains(scalar)
        }
        
        if !invalidChars.isEmpty {
            let invalidString = String(String.UnicodeScalarView(invalidChars))
            throw PipelineError.securityPolicy(reason: .invalidCharacters(
                field: field,
                invalidChars: invalidString
            ))
        }
    }
    
    /// Checks if a string contains HTML content
    private func containsHTML(_ string: String) -> Bool {
        // Use optimized pre-compiled regex
        return OptimizedValidators.containsHTML(string)
    }
    
    /// Estimates the size of a value in bytes
    private func estimateSize(of value: Any) -> Int {
        var size = 0
        let mirror = Mirror(reflecting: value)
        
        size += estimateMirrorSize(mirror)
        
        return size
    }
    
    /// Recursively estimates the size of mirrored properties
    private func estimateMirrorSize(_ mirror: Mirror) -> Int {
        var size = 0
        
        for child in mirror.children {
            if let string = child.value as? String {
                size += string.utf8.count
            } else if let data = child.value as? Data {
                size += data.count
            } else if let array = child.value as? [Any] {
                size += array.reduce(0) { $0 + estimateSize(of: $1) }
            } else if isSimpleType(child.value) {
                size += MemoryLayout<Any>.size
            } else {
                let childMirror = Mirror(reflecting: child.value)
                if !childMirror.children.isEmpty {
                    size += estimateMirrorSize(childMirror)
                }
            }
        }
        
        return size
    }
    
    /// Determines if a value is a simple type (doesn't need deep inspection)
    private func isSimpleType(_ value: Any) -> Bool {
        return value is Int || value is Double || value is Float ||
               value is Bool || value is Int8 || value is Int16 ||
               value is Int32 || value is Int64 || value is UInt ||
               value is UInt8 || value is UInt16 || value is UInt32 ||
               value is UInt64 || value is UUID || value is Date
    }
}
