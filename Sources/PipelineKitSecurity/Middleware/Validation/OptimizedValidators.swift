import Foundation
import PipelineKitCore

/// Optimized validators with pre-compiled regex patterns
public enum OptimizedValidators {
    // Pre-compiled regex patterns (thread-safe, only compiled once)
    private static let emailRegex: NSRegularExpression? = {
        // Comprehensive email pattern based on RFC 5322 (simplified for practical use)
        // Supports:
        // - Local part: letters, numbers, and ._%+-
        // - No consecutive dots, no dots at start/end of local part
        // - Domain: letters, numbers, hyphens (not at start/end of labels)
        // - TLD: 2+ letters
        // - Subdomains allowed
        let pattern = #"^[A-Za-z0-9_%+-]+(?:\.[A-Za-z0-9_%+-]+)*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
    
    private static let htmlRegex: NSRegularExpression? = {
        // Pattern to detect HTML tags and comments while avoiding false positives
        // Matches: <tag>, </tag>, <tag attr="value">, <!-- comment -->, but not: x < y
        // Requires either a letter immediately after < or the comment syntax
        let pattern = "(<[a-zA-Z/!][^>]*>|<!--.*?-->)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()
    
    /// Validates email using pre-compiled regex with additional checks
    public static func validateEmail(_ email: String) -> Bool {
        // Basic length checks
        guard email.count >= 3 && email.count <= 320 else { return false }
        
        // Check for exactly one @ symbol
        let atCount = email.filter { $0 == "@" }.count
        guard atCount == 1 else { return false }
        
        // Split into local and domain parts
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return false }
        
        let localPart = String(parts[0])
        let domainPart = String(parts[1])
        
        // Local part length check (RFC 5321)
        guard localPart.count >= 1 && localPart.count <= 64 else { return false }
        
        // Domain part length check
        guard domainPart.count >= 3 && domainPart.count <= 255 else { return false }
        
        // Use regex for final validation
        guard let regex = emailRegex else { return false }
        let range = NSRange(location: 0, length: email.utf16.count)
        return regex.firstMatch(in: email, options: [], range: range) != nil
    }
    
    /// Checks for HTML content using pre-compiled regex
    public static func containsHTML(_ string: String) -> Bool {
        guard let regex = htmlRegex else { return false }
        let range = NSRange(location: 0, length: string.utf16.count)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
    
    /// Alternative email validation without regex for comparison
    public static func validateEmailSimple(_ email: String) -> Bool {
        // Find @ symbol
        let components = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        
        let localPart = components[0]
        let domainPart = components[1]
        
        // Basic validation
        guard !localPart.isEmpty && !domainPart.isEmpty else { return false }
        guard localPart.count <= 64 && domainPart.count <= 255 else { return false }
        
        // Check domain has at least one dot
        let domainComponents = domainPart.split(separator: ".", omittingEmptySubsequences: false)
        guard domainComponents.count >= 2 else { return false }
        
        // Check TLD length
        guard let tld = domainComponents.last, tld.count >= 2 else { return false }
        
        // Check for valid characters (simplified)
        let validLocalChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-")
        let validDomainChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        
        for scalar in localPart.unicodeScalars {
            guard validLocalChars.contains(scalar) else { return false }
        }
        
        for scalar in domainPart.unicodeScalars {
            guard validDomainChars.contains(scalar) else { return false }
        }
        
        // Check for consecutive dots
        if email.contains("..") { return false }
        
        // Check first and last characters
        if localPart.first == "." || localPart.last == "." { return false }
        if domainPart.first == "." || domainPart.last == "." { return false }
        
        // Check each domain component for hyphens at start/end
        for component in domainComponents {
            if component.first == "-" || component.last == "-" {
                return false
            }
        }
        
        return true
    }
    
    /// Advanced email validation with detailed results
    public struct EmailValidationResult: Sendable {
        public let isValid: Bool
        public let localPart: String?
        public let domainPart: String?
        public let issues: [String]
        
        public static let invalid = EmailValidationResult(
            isValid: false,
            localPart: nil,
            domainPart: nil,
            issues: ["Invalid email format"]
        )
    }
    
    /// Performs comprehensive email validation with detailed feedback
    public static func validateEmailAdvanced(_ email: String) -> EmailValidationResult {
        var issues: [String] = []
        
        // Trim whitespace
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail != email {
            issues.append("Email contains leading or trailing whitespace")
        }
        
        // Length checks
        if email.count < 3 {
            issues.append("Email is too short (minimum 3 characters)")
        }
        if email.count > 320 {
            issues.append("Email is too long (maximum 320 characters)")
        }
        
        // Check for @ symbol
        let atCount = email.filter { $0 == "@" }.count
        if atCount == 0 {
            issues.append("Email missing @ symbol")
            return EmailValidationResult(isValid: false, localPart: nil, domainPart: nil, issues: issues)
        }
        if atCount > 1 {
            issues.append("Email contains multiple @ symbols")
            return EmailValidationResult(isValid: false, localPart: nil, domainPart: nil, issues: issues)
        }
        
        // Split email
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else {
            issues.append("Invalid email structure")
            return EmailValidationResult(isValid: false, localPart: nil, domainPart: nil, issues: issues)
        }
        
        let localPart = String(parts[0])
        let domainPart = String(parts[1])
        
        // Validate local part
        if localPart.isEmpty {
            issues.append("Local part (before @) is empty")
        } else if localPart.count > 64 {
            issues.append("Local part exceeds 64 characters")
        }
        
        if localPart.hasPrefix(".") || localPart.hasSuffix(".") {
            issues.append("Local part cannot start or end with a dot")
        }
        
        if localPart.contains("..") {
            issues.append("Local part contains consecutive dots")
        }
        
        // Validate domain part
        if domainPart.isEmpty {
            issues.append("Domain part (after @) is empty")
        } else if domainPart.count > 255 {
            issues.append("Domain part exceeds 255 characters")
        }
        
        if domainPart.hasPrefix(".") || domainPart.hasSuffix(".") {
            issues.append("Domain cannot start or end with a dot")
        }
        
        if domainPart.hasPrefix("-") || domainPart.hasSuffix("-") {
            issues.append("Domain cannot start or end with a hyphen")
        }
        
        // Check for valid TLD
        let domainComponents = domainPart.split(separator: ".")
        if domainComponents.count < 2 {
            issues.append("Domain must have at least one dot")
        } else if let tld = domainComponents.last, tld.count < 2 {
            issues.append("Top-level domain must be at least 2 characters")
        }
        
        // Final regex validation
        let isValid = issues.isEmpty && validateEmail(email)
        
        return EmailValidationResult(
            isValid: isValid,
            localPart: isValid ? localPart : nil,
            domainPart: isValid ? domainPart : nil,
            issues: issues
        )
    }
}
