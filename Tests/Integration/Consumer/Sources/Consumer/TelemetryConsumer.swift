import Foundation
import PipelineKitObservability
import PipelineKitPooling

/// Produces real public-API wire output for the independent protocol check.
func telemetryExport() async throws {
    let storage = MetricsStorage(maxSnapshotsPerMetric: 1)
    let exporter = PrometheusExporter(metricsStorage: storage)
    let labels = ["route": "/a\"b\\c\nnext"]
    await storage.record(.counter("interop.requests", value: 2, tags: labels))
    await storage.record(.counter("interop.requests", value: 3, tags: labels))
    await storage.record(.gauge("interop.depth", value: 9))
    await storage.record(.gauge("interop.depth", value: 4))
    await storage.record(.init(name: "interop.size", type: "histogram", value: 2, tags: labels))
    await storage.record(.init(name: "interop.size", type: "histogram", value: 5, tags: labels))
    try emit(["protocol": "prometheus", "fixture": "observability-initial", "text": await exporter.export()])
    _ = await storage.drain()
    try emit(["protocol": "prometheus", "fixture": "observability-drained", "text": await exporter.export()])
    await storage.record(.counter("interop.requests", value: 4, tags: labels))
    try emit(["protocol": "prometheus", "fixture": "observability-updated", "text": await exporter.exportAggregated()])
    await storage.clear()
    try emit(["protocol": "prometheus", "fixture": "observability-cleared", "text": await exporter.export()])

    let pools = PoolObservability()
    let poolLabels = ["pool": "quoted\"\\\nname"]
    await pools.incrementCounter("interop_pool_hits_total", by: 7, labels: poolLabels)
    await pools.setGauge("interop_pool_depth", value: -3, labels: poolLabels)
    await pools.recordHistogram("interop_pool_latency", value: 1, labels: poolLabels)
    await pools.recordHistogram("interop_pool_latency", value: 3, labels: poolLabels)
    for value in [1.0, 2.0, 9.0] {
        await pools.recordSummary("interop_pool_size", value: value, labels: poolLabels)
    }
    let poolSnapshot = await pools.captureSnapshot()
    try emit(["protocol": "prometheus", "fixture": "pool", "text": poolSnapshot.prometheusFormat()])

    let statsdPool = PoolObservability()
    await statsdPool.incrementCounter("interop_pool_total", by: 7, labels: ["pool": "a:b"])
    await statsdPool.setGauge("interop_pool_depth", value: -3)
    await statsdPool.recordHistogram("interop_pool_latency", value: 1)
    await statsdPool.recordHistogram("interop_pool_latency", value: 3)
    let statsdPoolSnapshot = await statsdPool.captureSnapshot()
    let poolDatagrams = statsdPoolSnapshot.statsdFormat()
    // Repeating a cumulative snapshot must not add its totals again.
    try emit(["protocol": "statsd", "fixture": "pool-snapshot", "packets": poolDatagrams + poolDatagrams])

    for aggregation in [false, true] {
        let transport = try await MockTransport(configuration: .init())
        let statsd = StatsDExporter(configuration: .init(
            maxBatchSize: 1000, flushInterval: 60, sampleRate: 0.25,
            criticalPatterns: [], aggregation: .init(enabled: aggregation, flushInterval: 60)
        ), transport: transport)
        for index in 0..<100 {
            let name = "interop.counter.\(index)"
            await statsd.record(.init(name: name, type: "counter"))
            await statsd.counter(name, value: 3)
        }
        await statsd.forceFlush()
        let packets = await transport.getMetricsAsStrings()
        try emit(["protocol": "statsd", "fixture": aggregation ? "aggregated" : "direct", "packets": packets])
        await statsd.close()
    }
}
