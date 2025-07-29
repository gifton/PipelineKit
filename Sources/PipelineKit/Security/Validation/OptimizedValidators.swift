import Foundation

/// Optimized validators with pre-compiled regex patterns
internal enum OptimizedValidators {
    
    // Pre-compiled regex patterns (thread-safe, only compiled once)
    private static let emailRegex: NSRegularExpression? = {
        // Updated pattern to prevent consecutive dots
        let pattern = #"^[A-Z0-9a-z_%+-]+(\.[A-Z0-9a-z_%+-]+)*@[A-Za-z0-9]+([.-][A-Za-z0-9]+)*\.[A-Za-z]{2,}$"#
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()
    
    private static let htmlRegex: NSRegularExpression? = {
        // Pattern to detect HTML tags and comments while avoiding false positives
        // Matches: <tag>, </tag>, <tag attr="value">, <!-- comment -->, but not: x < y
        // Requires either a letter immediately after < or the comment syntax
        let pattern = "(<[a-zA-Z/!][^>]*>|<!--.*?-->)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()
    
    /// Validates email using pre-compiled regex
    static func validateEmail(_ email: String) -> Bool {
        guard let regex = emailRegex else { return false }
        let range = NSRange(location: 0, length: email.utf16.count)
        return regex.firstMatch(in: email, options: [], range: range) != nil
    }
    
    /// Checks for HTML content using pre-compiled regex
    static func containsHTML(_ string: String) -> Bool {
        guard let regex = htmlRegex else { return false }
        let range = NSRange(location: 0, length: string.utf16.count)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }
    
    /// Alternative email validation without regex for comparison
    static func validateEmailSimple(_ email: String) -> Bool {
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
}