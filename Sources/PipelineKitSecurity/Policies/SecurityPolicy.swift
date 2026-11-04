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
    /// Maximum estimated logical content size for reflection-based validation.
    ///
    /// Strings contribute their UTF-8 byte count, `Data` its byte count, and
    /// supported scalar values each contribute `MemoryLayout<Any>.size`.
    /// Scalars are `Bool`, `Int`/`UInt`, their 8/16/32/64-bit variants, `Float`,
    /// `Double`, `UUID` and `Date`.
    /// Arrays, nested values and present optionals contribute their reflected
    /// contents; container/storage overhead and absent optionals contribute zero.
    /// This is neither a serialized size nor a process-memory budget. Commands
    /// implementing `SecurityValidatable` define their own validation instead.
    /// See `testSupportedLeavesHaveSameSizeInEveryContainerShape` and
    /// `testEmptyAndAbsentPayloadsFitZeroLimit` for boundary coverage.
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
///
/// Reflection covers visible children (including superclass fields) and the supported leaves documented by
/// `SecurityPolicy.maxCommandSize`. Opaque leaves and contents hidden by custom
/// mirrors are not measured; use `SecurityValidatable` for a domain-specific
/// contract. Reflected reference cycles are rejected, while repeated acyclic
/// references are counted per occurrence. Size errors report the observed sum
/// when the limit is first exceeded, saturated at `Int.max` on overflow.
/// These behaviors are covered by `testDirectAndIndirectReferenceCyclesRejectBeforeHandler`,
/// `testRepeatedReferenceOccurrencesEachContributeSize`,
/// `testSizeRejectionStopsBeforeLaterPayloadReflection` and
/// `testBudgetRejectsOverflowEvenWhenLimitIsIntMax`.
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
        var budget = SecurityCommandSizeBudget(limit: policy.maxCommandSize)
        try budget.add(0)
        try estimateSize(of: command, budget: &budget)
        try validateStrings(in: command)
    }
    
    private func validateStrings(in value: Any) throws {
        try walkReflectedValues(value) { value, path in
            if let stringValue = value as? String {
                try validateString(stringValue, field: path)
                return false
            }
            if let optionalString = value as? String? {
                if let stringValue = optionalString {
                    try validateString(stringValue, field: path)
                }
                return false
            }
            if let stringArray = value as? [String] {
                for (index, stringValue) in stringArray.enumerated() {
                    try validateString(stringValue, field: "\(path)[\(index)]")
                }
                return false
            }
            return !isSimpleType(value) && !(value is Data)
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
    
    /// Charges leaves before inspecting children, including array elements and
    /// optional payloads. See testSupportedLeavesHaveSameSizeInEveryContainerShape.
    private func estimateSize(of value: Any, budget: inout SecurityCommandSizeBudget) throws {
        try walkReflectedValues(value) { value, _ in
            if let string = value as? String {
                try budget.add(string.utf8.count)
                return false
            }
            if let data = value as? Data {
                try budget.add(data.count)
                return false
            }
            if isSimpleType(value) {
                try budget.add(MemoryLayout<Any>.size)
                return false
            }
            return true
        }
    }

    /// Visits children lazily using an explicit stack. Covered by
    /// testDeeplyNestedOptionalContainersRetainTheirLeafSize,
    /// testDeepAcyclicReferencesRetainTheirLeafSizes and
    /// testSizeRejectionStopsBeforeLaterPayloadReflection. Superclass traversal
    /// is covered by testInheritedStoredPropertiesContributeSize and
    /// testInheritedStringPropertiesAreValidated.
    private func walkReflectedValues(
        _ root: Any, descend: (Any, String) throws -> Bool
    ) throws {
        var activeReferences: Set<ObjectIdentifier> = []
        var frames: [ReflectionFrame] = [.value(root, path: "")]

        while let frame = frames.popLast() {
            switch frame {
            case .value(let value, let path):
                guard try descend(value, path) else { continue }
                let reference = try enterReference(value, activeReferences: &activeReferences)
                let mirror = Mirror(reflecting: value)
                frames.append(.children(
                    owner: value, mirror: mirror, iterator: mirror.children.makeIterator(),
                    path: path, reference: reference
                ))
            case .children(let owner, let mirror, let iterator, let path, let reference):
                if let child = iterator.next() {
                    frames.append(.children(
                        owner: owner, mirror: mirror, iterator: iterator, path: path, reference: reference
                    ))
                    let field = child.label ?? "unknown"
                    let fieldPath = path.isEmpty ? field : "\(path).\(field)"
                    frames.append(.value(child.value, path: fieldPath))
                } else if let superclass = mirror.superclassMirror {
                    frames.append(.children(
                        owner: owner, mirror: superclass, iterator: superclass.children.makeIterator(),
                        path: path, reference: reference
                    ))
                } else if let reference {
                    activeReferences.remove(reference)
                }
            }
        }
    }

    private enum ReflectionFrame {
        case value(Any, path: String)
        case children(
            owner: Any, mirror: Mirror, iterator: Mirror.Children.Iterator,
            path: String, reference: ObjectIdentifier?
        )
    }

    /// Tracks only the current path so separate occurrences of an alias count
    /// separately; see testRepeatedReferenceOccurrencesEachContributeSize.
    private func enterReference(
        _ value: Any, activeReferences: inout Set<ObjectIdentifier>
    ) throws -> ObjectIdentifier? {
        guard type(of: value) is AnyClass else { return nil }
        let reference = ObjectIdentifier(value as AnyObject)
        guard activeReferences.insert(reference).inserted else {
            throw PipelineError.securityPolicy(reason: .validationFailed(
                reason: "Reference cycle requires custom SecurityValidatable validation"
            ))
        }
        return reference
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

/// Accumulates nonnegative leaf charges and rejects on the first excess.
/// Overflow behavior is exercised by testBudgetRejectsOverflowEvenWhenLimitIsIntMax.
struct SecurityCommandSizeBudget {
    let limit: Int
    private(set) var size: Int = 0

    mutating func add(_ bytes: Int) throws {
        let (total, overflow) = size.addingReportingOverflow(bytes)
        guard !overflow && total <= limit else {
            throw PipelineError.securityPolicy(reason: .commandTooLarge(
                size: overflow ? Int.max : total,
                maxSize: limit
            ))
        }
        size = total
    }
}
