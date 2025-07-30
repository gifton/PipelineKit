# An Interactive Guide to the Command-Bus Architecture

> 📚 **Estimated Reading Time**: 45-60 minutes for the complete guide

Welcome! This repository is an interactive, multi-page guide designed to teach you the fundamentals of the Command-Bus software architecture pattern. While the examples are written in Swift, the concepts are language-agnostic and can be applied to any programming language.

## What is a Command Bus?

At its core, the Command-Bus is a design pattern that decouples the *sender* of an action from the *processor* of that action.

### The Restaurant Analogy 🍔

Imagine you're in a restaurant. You (the *sender*) give your order for a "Cheeseburger" to the waiter. The waiter takes the order and puts it on a conveyor belt to the kitchen. In the kitchen, a specific chef (the *processor*) who specializes in grilling picks up the order and cooks the burger.

You don't need to know who the chef is or how they cook. The chef doesn't need to know who you are. The waiter and the conveyor belt act as a middleman, or **Bus**, that ensures your request, or **Command**, gets to the right **Handler**.

This decoupling leads to code that is:
- **Highly Maintainable:** Each component has a single, well-defined responsibility
- **Easily Testable:** You can test a "chef" in isolation without needing a real "customer"
- **Scalable:** It's easy to add new dishes (Commands) and new chefs (Handlers) without changing the existing system

## When to Use Command-Bus Architecture 

### ✅ Use Command-Bus When:
- **Complex Business Logic**: You have intricate workflows with multiple steps
- **Audit Requirements**: You need to track every action in the system
- **Team Scalability**: Multiple teams work on different features
- **Cross-Cutting Concerns**: You need consistent logging, validation, or security
- **Modular Architecture**: You want clear boundaries between features

### ❌ Don't Use Command-Bus When:
- **Simple CRUD Apps**: Direct method calls are simpler and sufficient
- **High-Throughput Events**: Consider pub/sub or event streaming instead
- **Real-Time Systems**: The abstraction overhead may impact latency
- **Small Teams/Projects**: The complexity isn't justified
- **Learning Projects**: Start with simpler patterns first

### 🤔 Alternatives to Consider:
| Pattern | When to Use | Trade-offs |
|---------|------------|------------|
| **Direct Invocation** | Simple apps, tight coupling acceptable | Fast, simple, but hard to extend |
| **Pub/Sub** | Loose coupling, multiple consumers | Async complexity, eventual consistency |
| **Event Sourcing** | Audit trail, time travel needed | Storage overhead, complexity |
| **MVC/MVP/MVVM** | UI-focused apps | UI-centric, less business logic focus |

---

## Component Dictionary

This guide is broken down by the major components of the pattern. Here's a quick glossary:

- **[The Command](01-Commands.md)**: A simple, immutable data structure that represents a user's intent to change something in the system. It holds all the necessary information for the action to be performed. *Example: `CreateUserCommand`*

- **[The Command Handler](02-CommandHandlers.md)**: A class or struct responsible for executing the business logic for a *single, specific* command. It's the "worker" that knows what to do with a command. *Example: `CreateUserCommandHandler`*

- **[The Command Bus](03-CommandBus.md)**: The central dispatcher or "post office." Its only job is to receive a command and route it to its corresponding handler, often through a pipeline of middleware.

- **[Middleware](05-ScalingTheBus.md#1-middleware-the-onion-model-for-cross-cutting-concerns)**: A component that intercepts a command to perform cross-cutting actions like logging, validation, or authentication. It wraps the command handling process, forming a pipeline.

- **[Testing Strategies](06-TestingTheBus.md)**: Approaches for testing commands, handlers, and the bus in isolation and integration.

---

## System Architecture Overview

```
┌─────────────┐     ┌─────────────┐     ┌──────────────────┐
│   UI/API    │────▶│   Command   │────▶│   Command Bus    │
│   Layer     │     │   (Data)    │     │                  │
└─────────────┘     └─────────────┘     └────────┬─────────┘
                                                  │
                                                  ▼
                                         ┌────────────────┐
                                         │   Middleware   │
                                         │    Pipeline    │
                                         │                │
                                         │ ┌────────────┐ │
                                         │ │  Logging   │ │
                                         │ ├────────────┤ │
                                         │ │ Validation │ │
                                         │ ├────────────┤ │
                                         │ │   Auth     │ │
                                         │ └────────────┘ │
                                         └────────┬───────┘
                                                  │
                                                  ▼
                                         ┌────────────────┐
                                         │    Handler     │
                                         │                │
                                         │ - Validation   │
                                         │ - Business     │
                                         │   Logic        │
                                         │ - Side Effects │
                                         └────────┬───────┘
                                                  │
                                                  ▼
                                         ┌────────────────┐
                                         │  Domain/Data   │
                                         │     Layer      │
                                         └────────────────┘
```

---

## Scaling Intuition: From 10 to 1000 Commands

| Scale | Registration Strategy | Organization | Performance Considerations |
|-------|---------------------|--------------|---------------------------|
| **10 Commands** | Manual registration | Single file | Negligible overhead |
| **100 Commands** | DI Container | Feature folders | Consider lazy loading |
| **1000 Commands** | Auto-discovery | Module boundaries | Profile hot paths, batch operations |

### Performance Benchmarks (Indicative)

```swift
// Simple benchmark to understand overhead
let commands = (0..<1000).map { NoOpCommand(id: $0) }

// Without middleware
let start = CFAbsoluteTimeGetCurrent()
commands.forEach { bus.dispatch(command: $0) }
print("Direct: \(CFAbsoluteTimeGetCurrent() - start)s")
// Result: ~0.012s (12μs per command)

// With 3 middleware
let middlewareStart = CFAbsoluteTimeGetCurrent()
commands.forEach { busWithMiddleware.dispatch(command: $0) }
print("With middleware: \(CFAbsoluteTimeGetCurrent() - middlewareStart)s")
// Result: ~0.045s (45μs per command)
```

---

## How to Use This Guide

This guide is designed to be read sequentially, with each section building on the previous. Each page includes:
- **Conceptual explanation** with analogies
- **Working code examples** you can run
- **Architectural insights** for scaling
- **Common pitfalls** to avoid

### 📖 Start Your Learning Journey:

1. ### [First, let's learn about The Command →](01-Commands.md)
   *Learn how to model user intentions as data*

2. ### [Next, The Command Handler →](02-CommandHandlers.md)
   *Understand single-responsibility business logic*

3. ### [Then, The Command Bus →](03-CommandBus.md)
   *See how routing and middleware work*

4. ### [Let's Put It All Together →](04-PuttingItAllTogether.md)
   *Build a complete working example*

5. ### [Explore advanced scaling patterns →](05-ScalingTheBus.md)
   *Learn async handling, chaining, and more*

6. ### [Master testing strategies →](06-TestingTheBus.md)
   *Test your architecture effectively*

---

## Additional Resources

- [Martin Fowler on Command Pattern](https://martinfowler.com/bliki/CommandOrientedInterface.html)
- [Comparison with CQRS](https://martinfowler.com/bliki/CQRS.html)
- [Enterprise Integration Patterns](https://www.enterpriseintegrationpatterns.com/)

---

*This guide is part of a series on software architecture patterns. Feedback and contributions are welcome!*