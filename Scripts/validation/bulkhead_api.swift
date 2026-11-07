import PipelineKitCore
import PipelineKitResilience

let partitions = ["tenant": PartitionedBulkheadMiddleware.PartitionConfig(capacity: 2)]
let configuration = PartitionedBulkheadMiddleware.Configuration(
    partitions: partitions,
    partitionExtractor: { _, _ in "tenant" },
    defaultPartition: "tenant",
    allowBorrowing: false,
    reservedCapacityPercentage: 0.5
)
let partitioned = PartitionedBulkheadMiddleware(configuration: configuration)
let shared = BulkheadMiddleware(configuration: .init(maxConcurrency: 2, isolationMode: .semaphore))
let grouped = BulkheadMiddleware(configuration: .init(maxConcurrency: 2, isolationMode: .taskGroup(priority: nil)))

#if REJECT_TAGGED
let removed = BulkheadMiddleware.IsolationMode.tagged(keyExtractor: { _ in "tenant" })
#elseif REJECT_BORROW_PROPERTY
let removed = configuration.maxBorrowPercentage
#elseif REJECT_BORROW_INITIALIZER
let removed = PartitionedBulkheadMiddleware.Configuration(
    partitions: partitions, partitionExtractor: { _, _ in "tenant" }, maxBorrowPercentage: 0.5
)
#endif
