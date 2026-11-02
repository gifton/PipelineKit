import Foundation
import XCTest
import PipelineKit
import PipelineKitSecurity
@testable import PipelineKitCache

final class CacheIdentityContractTests: XCTestCase {
    // Catches missing arguments/principal/configuration, fallback correlation keys,
    // and a convenience method that drops the caller's generator.
    func testCacheIdentityMatrix() async throws {
        for route in Route.allCases {
            for factory in [false, true] {
                let calls = Counter()
                let middleware = route.make(key: identityKey(), factory: factory)
                for (argument, principal, expected) in [
                    ("one", "alice", "one/alice/v1"), ("two", "alice", "two/alice/v1"),
                    ("one", "bob", "one/bob/v1"), ("two", "bob", "two/bob/v1")
                ] {
                    let value = try await execute(middleware, argument, context(principal), calls)
                    XCTAssertEqual(value, expected, "\(route), factory=\(factory)")
                }
                let repeatValue = try await execute(middleware, "one", context("alice"), calls)
                XCTAssertEqual(repeatValue, "one/alice/v1")
                let afterRepeat = await calls.value
                XCTAssertEqual(afterRepeat, 4, "Four misses followed by exactly one hit: \(route), \(factory)")
                let correlationOnly = try await execute(middleware, "one", context("alice", correlation: "another"), calls)
                XCTAssertEqual(correlationOnly, "one/alice/v1")
                let afterCorrelation = await calls.value
                XCTAssertEqual(afterCorrelation, 4, "This generator intentionally excludes correlation")
                let changedConfiguration = try await execute(middleware, "one", context("alice", version: "v2"), calls)
                XCTAssertEqual(changedConfiguration, "one/alice/v2")
                let total = await calls.value
                XCTAssertEqual(total, 5)
                print("S03 identity route=\(route) factory=\(factory) requests=7 handlerCalls=\(total)")
            }
        }
    }

    func testCallerCanExplicitlyIncludeCorrelation() async throws {
        for route in Route.allCases {
            let calls = Counter()
            let middleware = route.make(key: identityKey(includeCorrelation: true))
            for correlation in ["first", "first", "second"] {
                let value = try await execute(middleware, "one", context("alice", correlation: correlation), calls)
                XCTAssertEqual(value, "one/alice/v1")
            }
            let total = await calls.value
            XCTAssertEqual(total, 2, "\(route): explicit correlation changes the caller's identity")
        }
    }

    func testEqualHashValuesDoNotShareResults() async throws {
        let first = Query(argument: "one")
        let second = Query(argument: "two")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue, "The fixture deliberately combines the same hash input")
        for route in Route.allCases {
            for factory in [false, true] {
                let calls = Counter()
                let middleware = route.make(key: identityKey(), factory: factory)
                for (command, expected) in [(first, "one/alice/v1"), (second, "two/alice/v1"), (first, "one/alice/v1")] {
                    let result = try await execute(middleware, command.argument, context("alice"), calls)
                    XCTAssertEqual(result, expected, "\(route), factory=\(factory)")
                }
                let total = await calls.value
                XCTAssertEqual(total, 2)
                print("S03 hash route=\(route) factory=\(factory) requests=3 handlerCalls=\(total)")
            }
        }
    }

    func testNamespaceEncodingIsUnambiguous() {
        let parts = ["", ":", "a:b", "a", "é", "🙂"]
        var keys: Set<String> = []
        for command in parts {
            for result in parts {
                for middleware in parts {
                    for caller in parts {
                        XCTAssertTrue(keys.insert(CacheKeyNamespace.encode(
                            commandType: command, resultType: result, middleware: middleware, callerKey: caller
                        )).inserted)
                    }
                }
            }
        }
        XCTAssertEqual(keys.count, 1296)
        XCTAssertEqual(CacheKeyNamespace.encode(commandType: "é", resultType: "🙂", middleware: "", callerKey: "a:b"), "2:é4:🙂0:3:a:b")
        let commandTypes = [String(reflecting: Left.Query.self), String(reflecting: Right.Query.self)]
        let resultTypes = [String(reflecting: Left.Payload.self), String(reflecting: Right.Payload.self)]
        XCTAssertNotEqual(commandTypes[0], commandTypes[1])
        XCTAssertNotEqual(resultTypes[0], resultTypes[1])
        let typeKeys = commandTypes.flatMap { command in resultTypes.map { result in
            CacheKeyNamespace.encode(commandType: command, resultType: result, middleware: "cache", callerKey: "")
        } }
        XCTAssertEqual(Set(typeKeys).count, 4, "Each type field contributes independently")
    }

    // Fieldless commands intentionally share a caller key; their types still differ.
    // Codable same-shape result types challenge the encoded backend's decoding path.
    func testExplicitKeysStillNamespaceDifferentCommandAndResultTypes() async throws {
        for route in Route.allCases {
            let key = ClosureCacheKeyGenerator { _, _, _ in "" }
            let middleware = route.make(key: key)
            let calls = Counter()
            for _ in 0..<2 {
                let left = try await middleware.execute(Left.Query(), context: CommandContext()) { _, _ in
                    await calls.increment(); return "left"
                }
                let right = try await middleware.execute(Right.Query(), context: CommandContext()) { _, _ in
                    await calls.increment(); return "right"
                }
                let leftPayload = try await middleware.execute(TypedQuery<Left.Payload>(), context: CommandContext()) { _, _ in
                    await calls.increment(); return Left.Payload(value: "left-payload")
                }
                let rightPayload = try await middleware.execute(TypedQuery<Right.Payload>(), context: CommandContext()) { _, _ in
                    await calls.increment(); return Right.Payload(value: "right-payload")
                }
                XCTAssertEqual(left, "left", "\(route)")
                XCTAssertEqual(right, "right", "\(route)")
                XCTAssertEqual(leftPayload.value, "left-payload", "\(route)")
                XCTAssertEqual(rightPayload.value, "right-payload", "\(route)")
            }
            let total = await calls.value
            XCTAssertEqual(total, 4, "\(route): separate type namespaces must also retain hits")
        }
    }

    func testSharedBackendSeparatesMiddlewareTypesAndWrapperKinds() async throws {
        let cache = InMemoryMiddlewareCache()
        // All commands below are fieldless; the type namespace owns their constant differences.
        let key = ClosureCacheKeyGenerator { _, _, _ in "" }
        let first = CachedMiddleware(wrapping: Left.Stage(), cache: cache, keyGenerator: key)
        let second = CachedMiddleware(wrapping: Right.Stage(), cache: cache, keyGenerator: key)
        let conditional = ConditionalCachedMiddleware(wrapping: Left.Stage(), cache: cache, keyGenerator: key, shouldCache: { _, _ in true })
        let calls = Counter()
        for _ in 0..<2 {
            let left = try await first.execute(Left.Query(), context: CommandContext()) { _, _ in await calls.increment(); return "cached-left" }
            let right = try await second.execute(Left.Query(), context: CommandContext()) { _, _ in await calls.increment(); return "cached-right" }
            let condition = try await conditional.execute(Left.Query(), context: CommandContext()) { _, _ in await calls.increment(); return "conditional-left" }
            XCTAssertEqual(left, "cached-left")
            XCTAssertEqual(right, "cached-right")
            XCTAssertEqual(condition, "conditional-left")
        }
        let total = await calls.value
        XCTAssertEqual(total, 3)
    }

    func testConditionalBranchesBypassKeyGenerationAndStorage() async throws {
        for route in [Route.conditional, .simple, .encoded] {
            for factory in (route == .conditional ? [false, true] : [false]) {
                let calls = Counter()
                let generated = Counter()
                let key = ClosureCacheKeyGenerator { command, context, middleware in
                    await generated.increment()
                    return await identityKey().generateKey(for: command, context: context, middleware: middleware)
                }
                let middleware = route.make(key: key, factory: factory, cacheEnabled: false)
                for _ in 0..<2 {
                    let value = try await execute(middleware, "one", context("alice"), calls)
                    XCTAssertEqual(value, "one/alice/v1")
                }
                let total = await calls.value
                let keys = await generated.value
                XCTAssertEqual(total, 2, "\(route), factory=\(factory)")
                XCTAssertEqual(keys, 0, "A bypass must not invoke the caller's generator")
            }
        }
    }

    func testCommandTypeFactoriesCacheNonHashableAndBypassOthers() async throws {
        // The encoded convenience API no longer requires Hashable. Exercise that
        // newly reachable selection, plus the rejected type in both factories.
        let key = ClosureCacheKeyGenerator { command, _, _ in
            precondition(command is Left.Query, "Bypassed commands must never generate keys")
            return "fieldless-left-v1"
        }
        for middleware: any Middleware in [
            SimpleCachingMiddleware(ttl: 60, commandType: Left.Query.self, keyGenerator: key),
            CachingMiddleware(cache: InMemoryCache(), commandType: Left.Query.self, keyGenerator: key)
        ] {
            let calls = Counter()
            for _ in 0..<2 {
                let value = try await middleware.execute(Left.Query(), context: CommandContext()) { _, _ in
                    await calls.increment(); return "selected"
                }
                XCTAssertEqual(value, "selected")
            }
            let afterSelected = await calls.value
            XCTAssertEqual(afterSelected, 1)
            for _ in 0..<2 {
                let value = try await middleware.execute(Right.Query(), context: CommandContext()) { _, _ in
                    await calls.increment(); return "bypass"
                }
                XCTAssertEqual(value, "bypass")
            }
            let total = await calls.value
            XCTAssertEqual(total, 3)
        }
    }

    func testTTLAndInvalidationPreserveIdentity() async throws {
        for route in Route.allCases {
            let calls = Counter()
            let backend = InMemoryMiddlewareCache()
            let dataBackend = InMemoryCache()
            let middleware = route.make(key: identityKey(), backend: backend, dataBackend: dataBackend)
            _ = try await execute(middleware, "one", context("alice"), calls)
            _ = try await execute(middleware, "one", context("alice"), calls)
            switch route {
            case .cached, .conditional: await backend.invalidateAll()
            case .encoded: await dataBackend.clear()
            case .simple: (middleware as! SimpleCachingMiddleware).clear()
            }
            let value = try await execute(middleware, "one", context("alice"), calls)
            XCTAssertEqual(value, "one/alice/v1")
            let afterInvalidation = await calls.value
            XCTAssertEqual(afterInvalidation, 2, "\(route)")
            // Negative TTL is already expired; no scheduling delay establishes test ordering.
            let expired = route.make(key: identityKey(), ttl: -1)
            for _ in 0..<2 {
                _ = try await execute(expired, "one", context("alice"), calls)
            }
            let afterExpiration = await calls.value
            XCTAssertEqual(afterExpiration, 4, "\(route)")
        }
    }

    func testAuthenticatedBuilderPipelineUsesVerifiedPrincipal() async throws {
        for route in Route.allCases {
            for authenticationFirst in [false, true] {
                let handlerCalls = Counter()
                let validationCalls = Counter()
                let authenticationCalls = Counter()
                let generated = Counter()
                let key = ClosureCacheKeyGenerator { command, context, _ in
                    guard let query = command as? AuthQuery,
                          let principal = context.getMetadata("authUserId") as? String else {
                        preconditionFailure("Authentication must precede identity generation")
                    }
                    await generated.increment()
                    return fields([query.argument, principal, "render-v1"])
                }
                let authentication = AuthenticationMiddleware { credential in
                    await authenticationCalls.increment()
                    switch credential {
                    case "credential-alice": return "alice"
                    case "credential-bob": return "bob"
                    default: throw AuthenticationFailure()
                    }
                }
                let builder = PipelineBuilder(handler: AuthHandler(calls: handlerCalls))
                if authenticationFirst { await builder.withAuthentication(authentication) }
                await builder.with(route.make(key: key))
                await builder.with(ValidationMiddleware())
                if !authenticationFirst { await builder.withAuthentication(authentication) }
                let pipeline = try await builder.build()
                for (argument, credential, expected) in [
                    ("one", "credential-alice", "one/alice"), ("two", "credential-alice", "two/alice"),
                    ("one", "credential-bob", "one/bob"), ("two", "credential-bob", "two/bob"),
                    ("one", "credential-alice", "one/alice")
                ] {
                    let value = try await pipeline.execute(AuthQuery(argument: argument, validations: validationCalls), context: context(credential))
                    XCTAssertEqual(value, expected, "\(route), authenticationFirst=\(authenticationFirst)")
                }
                do {
                    _ = try await pipeline.execute(AuthQuery(argument: "one", validations: validationCalls), context: context("invalid"))
                    XCTFail("Authentication must reject before cache lookup")
                } catch {
                    XCTAssertTrue(error is AuthenticationFailure)
                }
                let handled = await handlerCalls.value
                let validated = await validationCalls.value
                let authenticated = await authenticationCalls.value
                let keys = await generated.value
                XCTAssertEqual(handled, 4)
                XCTAssertEqual(validated, 5, "Real async validation witness must run even on the hit")
                XCTAssertEqual(authenticated, 6)
                XCTAssertEqual(keys, 5)
                print("S03 authenticated route=\(route) authenticationFirst=\(authenticationFirst) handler=\(handled) validation=\(validated) authentication=\(authenticated) keys=\(keys)")
            }
        }
    }
}

private enum Route: CaseIterable {
    case cached, conditional, simple, encoded

    func make(key: any CacheKeyGenerator, factory: Bool = false, cacheEnabled: Bool = true, ttl: TimeInterval = 60,
              backend: InMemoryMiddlewareCache = InMemoryMiddlewareCache(), dataBackend: InMemoryCache = InMemoryCache()) -> any Middleware {
        switch self {
        case .cached:
            return factory ? PassThrough().cached(ttl: ttl, cache: backend, keyGenerator: key)
                : CachedMiddleware(wrapping: PassThrough(), cache: backend, keyGenerator: key, ttl: ttl)
        case .conditional:
            return factory ? PassThrough().cachedWhen(ttl: ttl, cache: backend, keyGenerator: key, condition: { _, _ in cacheEnabled })
                : ConditionalCachedMiddleware(wrapping: PassThrough(), cache: backend, keyGenerator: key, ttl: ttl, shouldCache: { _, _ in cacheEnabled })
        case .simple:
            // A type-selective factory is exercised separately for its bypass branch.
            if factory && cacheEnabled { return SimpleCachingMiddleware(ttl: ttl, commandType: Query.self, keyGenerator: key) }
            return SimpleCachingMiddleware(ttl: ttl, keyGenerator: key, shouldCache: { _ in cacheEnabled })
        case .encoded:
            if factory && cacheEnabled { return CachingMiddleware(cache: dataBackend, commandType: Query.self, keyGenerator: key, ttl: ttl) }
            return CachingMiddleware(cache: dataBackend, keyGenerator: key, ttl: ttl, shouldCache: { _ in cacheEnabled })
        }
    }
}

private func context(_ principal: String, correlation: String = "same", version: String = "v1") -> CommandContext {
    let context = CommandContext(metadata: DefaultCommandMetadata(userID: principal, correlationID: correlation))
    context.setMetadata("renderVersion", value: version)
    return context
}

private func fields(_ values: [String]) -> String { values.map { "\($0.utf8.count):\($0)" }.joined() }

private func identityKey(includeCorrelation: Bool = false) -> ClosureCacheKeyGenerator {
    ClosureCacheKeyGenerator { command, context, _ in
        guard let query = command as? Query,
              let principal = context.commandMetadata.userID,
              let version = context.getMetadata("renderVersion") as? String else {
            preconditionFailure("Unexpected identity fixture")
        }
        var components = [query.argument, principal, version]
        if includeCorrelation { components.append(context.commandMetadata.correlationID ?? "") }
        return fields(components)
    }
}

private func execute(_ middleware: any Middleware, _ argument: String, _ context: CommandContext, _ calls: Counter) async throws -> String {
    try await middleware.execute(Query(argument: argument), context: context) { command, context in
        await calls.increment()
        return "\(command.argument)/\(context.commandMetadata.userID!)/\(context.getMetadata("renderVersion") as! String)"
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
private struct Query: Command, Hashable {
    typealias Result = String
    let argument: String
    func hash(into hasher: inout Hasher) { hasher.combine(0) }
}
private enum Left {
    struct Query: Command { typealias Result = String }
    struct Payload: Sendable, Codable { let value: String }
    struct Stage: Middleware {
        let priority: ExecutionPriority = .preProcessing
        func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
            try await next(command, context)
        }
    }
}
private enum Right {
    struct Query: Command { typealias Result = String }
    struct Payload: Sendable, Codable { let value: String }
    struct Stage: Middleware {
        let priority: ExecutionPriority = .preProcessing
        func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
            try await next(command, context)
        }
    }
}
private struct TypedQuery<Value: Sendable>: Command { typealias Result = Value }
private struct PassThrough: Middleware {
    let priority: ExecutionPriority = .preProcessing
    func execute<T: Command>(_ command: T, context: CommandContext, next: @escaping MiddlewareNext<T>) async throws -> T.Result {
        try await next(command, context)
    }
}
private struct AuthenticationFailure: Error {}
private struct AuthQuery: Command, ValidatableCommand {
    typealias Result = String
    let argument: String
    let validations: Counter
    func validate() async throws { await validations.increment() }
}
private struct AuthHandler: CommandHandler {
    typealias CommandType = AuthQuery
    let calls: Counter
    func handle(_ command: AuthQuery, context: CommandContext) async throws -> String {
        await calls.increment()
        return "\(command.argument)/\(context.getMetadata("authUserId") as! String)"
    }
}
