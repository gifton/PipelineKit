/// Shared counter boundary used by local and distributed rate windows.
internal enum RateLimitNumeric {
    static func increment(_ requestCount: Int) -> Int? {
        guard requestCount >= 0 && requestCount < Int.max else { return nil }
        return requestCount + 1
    }
}
