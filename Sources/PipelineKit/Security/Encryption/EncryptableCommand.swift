import Foundation

/// Protocol for commands that contain sensitive data requiring encryption.
///
/// Example:
/// ```swift
/// struct PaymentCommand: Command, EncryptableCommand {
///     let cardNumber: String
///     let cvv: String
///     
///     var sensitiveFields: [String: Any] {
///         ["cardNumber": cardNumber, "cvv": cvv]
///     }
///     
///     mutating func updateSensitiveFields(_ fields: [String: Any]) {
///         if let cardNumber = fields["cardNumber"] as? String {
///             self.cardNumber = cardNumber
///         }
///         if let cvv = fields["cvv"] as? String {
///             self.cvv = cvv
///         }
///     }
/// }
/// ```
public protocol EncryptableCommand: Command {
    /// Fields that should be encrypted
    var sensitiveFields: [String: Any] { get }
    
    /// Update the command with decrypted fields
    mutating func updateSensitiveFields(_ fields: [String: Any])
}