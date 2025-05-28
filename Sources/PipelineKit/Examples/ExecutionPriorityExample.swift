import Foundation

// NOTE: This file demonstrates execution priority concepts.
// The actual middleware implementations would need to be created based on your specific requirements.

/// Example showing how to query middleware categories
func demonstrateMiddlewareCategories() {
    // Get all security-related execution priorities
    let securityPriorities = ExecutionPriority.category(.security)
    print("Security execution priorities:")
    for priority in securityPriorities {
        print("  - \(priority): \(priority.rawValue)")
    }
    
    // Check category of a specific priority
    let authPriority = ExecutionPriority.authentication
    print("\n\(authPriority) belongs to category: \(authPriority.category)")
    
    // Iterate through all categories
    print("\nAll middleware categories:")
    for category in MiddlewareCategory.allCases {
        let priorities = ExecutionPriority.category(category)
        print("\n\(category.rawValue): \(priorities.count) middleware types")
    }
}

/// Example showing how to use the priority helpers
func demonstratePriorityHelpers() {
    // Create custom priorities between standard priorities
    let customPriority1 = ExecutionPriority.between(.authentication, and: .authorization)
    print("Priority between auth and authz: \(customPriority1)")
    
    let customPriority2 = ExecutionPriority.before(.validation)
    print("Priority before validation: \(customPriority2)")
    
    let customPriority3 = ExecutionPriority.after(.logging)
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
        let priorities = ExecutionPriority.category(category)
        for priority in priorities {
            print("  - \(priority) (\(priority.rawValue))")
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
     priority: ExecutionPriority.between(.validation, and: .businessRules)
 )
 
 // Or add with a specific priority
 try await pipeline.addMiddleware(
     ValidationMiddleware(),
     priority: ExecutionPriority.validation.rawValue
 )
 
 // Or add just after another middleware
 try await pipeline.addMiddleware(
     PostValidationMiddleware(),
     priority: ExecutionPriority.after(.validation)
 )
 ```
 */

/// Comprehensive list of all available execution priorities
func listAllExecutionPriorities() {
    print("Complete list of ExecutionPriority cases:\n")
    
    for priority in ExecutionPriority.allCases {
        print("\(priority) = \(priority.rawValue) (Category: \(priority.category))")
    }
}

// Call this to see the execution priority in action
func runExecutionPriorityDemo() {
    print("=== Middleware Categories Demo ===\n")
    demonstrateMiddlewareCategories()
    
    print("\n\n=== Priority Helpers Demo ===\n")
    demonstratePriorityHelpers()
    
    print("\n\n=== Middleware Structure Demo ===\n")
    demonstrateMiddlewareStructure()
    
    print("\n\n=== All Execution Priorities ===\n")
    listAllExecutionPriorities()
}