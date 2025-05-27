import Foundation

// NOTE: This file demonstrates middleware ordering concepts.
// The actual middleware implementations would need to be created based on your specific requirements.

/// Example showing how to query middleware categories
func demonstrateMiddlewareCategories() {
    // Get all security-related middleware orders
    let securityOrders = MiddlewareOrder.category(.security)
    print("Security middleware orders:")
    for order in securityOrders {
        print("  - \(order): \(order.rawValue)")
    }
    
    // Check category of a specific order
    let authOrder = MiddlewareOrder.authentication
    print("\n\(authOrder) belongs to category: \(authOrder.category)")
    
    // Iterate through all categories
    print("\nAll middleware categories:")
    for category in MiddlewareCategory.allCases {
        let orders = MiddlewareOrder.category(category)
        print("\n\(category.rawValue): \(orders.count) middleware types")
    }
}

/// Example showing how to use the ordering helpers
func demonstrateOrderingHelpers() {
    // Create custom priorities between standard orders
    let customPriority1 = MiddlewareOrder.between(.authentication, and: .authorization)
    print("Priority between auth and authz: \(customPriority1)")
    
    let customPriority2 = MiddlewareOrder.before(.validation)
    print("Priority before validation: \(customPriority2)")
    
    let customPriority3 = MiddlewareOrder.after(.logging)
    print("Priority after logging: \(customPriority3)")
}

/// Example of how you might structure middleware in a real application
func demonstrateMiddlewareStructure() {
    print("Recommended middleware execution order for a typical web application:\n")
    
    let categories: [(MiddlewareCategory, String)] = [
        (.preProcessing, "Prepare the request"),
        (.security, "Authenticate and authorize"),
        (.validationSanitization, "Validate and clean input"),
        (.trafficControl, "Apply rate limits and circuit breakers"),
        (.observability, "Log and monitor"),
        (.enhancement, "Add features like caching"),
        (.errorHandling, "Handle errors gracefully"),
        (.postProcessing, "Transform and prepare response"),
        (.transactionManagement, "Manage database transactions")
    ]
    
    for (category, description) in categories {
        print("\(category.rawValue): \(description)")
        let orders = MiddlewareOrder.category(category)
        for order in orders {
            print("  - \(order) (\(order.rawValue))")
        }
        print()
    }
}

/*
 Example of how to implement custom middleware with proper ordering:
 
 ```swift
 // 1. Define your middleware
 struct CustomValidationMiddleware: Middleware {
     func execute<T: Command>(
         _ command: T,
         metadata: CommandMetadata,
         next: @Sendable (T, CommandMetadata) async throws -> T.Result
     ) async throws -> T.Result {
         // Custom validation logic here
         return try await next(command, metadata)
     }
 }
 
 // 2. Add it to a pipeline with appropriate priority
 let pipeline = PriorityPipeline(handler: MyHandler())
 
 // Add between validation and business rules
 try await pipeline.addMiddleware(
     CustomValidationMiddleware(),
     priority: MiddlewareOrder.between(.validation, and: .businessRules)
 )
 
 // Or add with a specific order
 try await pipeline.addMiddleware(
     ValidationMiddleware(),
     priority: MiddlewareOrder.validation.rawValue
 )
 
 // Or add just after another middleware
 try await pipeline.addMiddleware(
     PostValidationMiddleware(),
     priority: MiddlewareOrder.after(.validation)
 )
 ```
 */

/// Comprehensive list of all available middleware orders
func listAllMiddlewareOrders() {
    print("Complete list of MiddlewareOrder cases:\n")
    
    for order in MiddlewareOrder.allCases {
        print("\(order) = \(order.rawValue) (Category: \(order.category))")
    }
}

// Call this to see the middleware ordering in action
func runMiddlewareOrderingDemo() {
    print("=== Middleware Categories Demo ===\n")
    demonstrateMiddlewareCategories()
    
    print("\n\n=== Ordering Helpers Demo ===\n")
    demonstrateOrderingHelpers()
    
    print("\n\n=== Middleware Structure Demo ===\n")
    demonstrateMiddlewareStructure()
    
    print("\n\n=== All Middleware Orders ===\n")
    listAllMiddlewareOrders()
}