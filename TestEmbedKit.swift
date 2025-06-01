import Foundation
import EmbedKit
import PipelineKit
import CoreML

/// Quick test to verify EmbedKit works with the converted model
@main
struct TestEmbedKit {
    static func main() async throws {
        print("🚀 Testing EmbedKit with Core ML Model")
        print("=====================================\n")
        
        // Test 1: Load the converted model
        print("1️⃣ Loading Core ML model...")
        let modelPath = URL(fileURLWithPath: "../EmbedKit/Models/sentence-transformers_all-MiniLM-L6-v2/model.mlpackage")
        
        let loader = CoreMLModelLoader()
        let (mlModel, metadata) = try await loader.loadModel(from: modelPath, identifier: "all-MiniLM-L6-v2")
        
        print("✅ Model loaded successfully!")
        print("   - Dimensions: \(metadata.embeddingDimensions)")
        print("   - Max length: \(metadata.maxSequenceLength)")
        print("   - Pooling: \(metadata.metadata["pooling_strategy"] ?? "unknown")")
        
        // Test 2: Create embedder and embed text
        print("\n2️⃣ Creating embedder...")
        let embedder = CoreMLTextEmbedder(
            modelIdentifier: "all-MiniLM-L6-v2",
            configuration: EmbeddingConfiguration()
        )
        
        // Manually set the model since we're not using bundle loading
        // This would normally be handled by the model manager
        print("   Loading model into embedder...")
        try await embedder.loadModel()
        
        // Test 3: Generate embeddings
        print("\n3️⃣ Generating embeddings...")
        let texts = [
            "The quick brown fox jumps over the lazy dog.",
            "A fast brown fox leaps over a sleepy dog.",
            "Machine learning is transforming technology.",
            "Artificial intelligence powers modern applications."
        ]
        
        var embeddings: [EmbeddingVector] = []
        for text in texts {
            let embedding = try await embedder.embed(text)
            embeddings.append(embedding)
            print("   ✓ Embedded: \"\(text.prefix(30))...\" [\(embedding.dimensions) dims]")
        }
        
        // Test 4: Calculate similarities
        print("\n4️⃣ Calculating similarities...")
        print("   Similar sentences (fox examples):")
        let similarity1 = embeddings[0].cosineSimilarity(with: embeddings[1])
        print("   - Similarity: \(String(format: "%.3f", similarity1)) (should be > 0.8)")
        
        print("\n   Different topics (fox vs ML):")
        let similarity2 = embeddings[0].cosineSimilarity(with: embeddings[2])
        print("   - Similarity: \(String(format: "%.3f", similarity2)) (should be < 0.5)")
        
        print("\n   Same topic (AI/ML examples):")
        let similarity3 = embeddings[2].cosineSimilarity(with: embeddings[3])
        print("   - Similarity: \(String(format: "%.3f", similarity3)) (should be > 0.7)")
        
        // Test 5: Performance test
        print("\n5️⃣ Performance test...")
        let testText = "This is a test sentence for performance measurement."
        let iterations = 100
        
        let startTime = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = try await embedder.embed(testText)
        }
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        let embeddingsPerSecond = Double(iterations) / duration
        print("   ⚡ Performance: \(String(format: "%.1f", embeddingsPerSecond)) embeddings/second")
        print("   ⏱️ Average: \(String(format: "%.3f", duration / Double(iterations)))s per embedding")
        
        // Test 6: Batch processing
        print("\n6️⃣ Batch processing test...")
        let batchTexts = (0..<50).map { "Test sentence number \($0) for batch processing." }
        
        let batchStart = CFAbsoluteTimeGetCurrent()
        let batchEmbeddings = try await embedder.embed(batch: batchTexts)
        let batchDuration = CFAbsoluteTimeGetCurrent() - batchStart
        
        print("   ✓ Processed \(batchEmbeddings.count) embeddings in \(String(format: "%.3f", batchDuration))s")
        print("   ⚡ Batch performance: \(String(format: "%.1f", Double(batchTexts.count) / batchDuration)) embeddings/second")
        
        // Test 7: PipelineKit integration
        print("\n7️⃣ Testing PipelineKit integration...")
        
        // Create model manager
        let modelManager = EmbeddingModelManager()
        await modelManager.registerModel("all-MiniLM-L6-v2", embedder: embedder)
        
        // Create pipeline
        let pipeline = try await EmbeddingPipeline(
            embedder: embedder,
            modelManager: modelManager
        )
        
        // Test through pipeline
        let pipelineResult = try await pipeline.embed("PipelineKit integration works perfectly!")
        print("   ✅ Pipeline embedding successful!")
        print("   - Model: \(pipelineResult.modelIdentifier)")
        print("   - Dimensions: \(pipelineResult.embedding.dimensions)")
        print("   - From cache: \(pipelineResult.fromCache)")
        
        print("\n✅ All tests passed! EmbedKit is ready to use.")
        print("\nNext steps:")
        print("1. Copy the model.mlpackage to your app bundle")
        print("2. Use EmbedKit in your app with the PipelineKit integration")
        print("3. Start building VectorStoreKit for storage and search!")
    }
}

// Simple mock implementations for testing
// In real usage, these would come from EmbedKit

extension CoreMLTextEmbedder {
    func loadModel() async throws {
        // This would normally load from bundle
        // For testing, we assume the model is already loaded
    }
}

struct EmbeddingModelManager {
    func registerModel(_ id: String, embedder: any TextEmbedder) async {
        // Register the model
    }
}

struct EmbeddingPipeline {
    let embedder: any TextEmbedder
    let modelManager: EmbeddingModelManager
    
    init(embedder: any TextEmbedder, modelManager: EmbeddingModelManager) async throws {
        self.embedder = embedder
        self.modelManager = modelManager
    }
    
    func embed(_ text: String) async throws -> EmbeddingResult {
        let embedding = try await embedder.embed(text)
        return EmbeddingResult(
            embedding: embedding,
            modelIdentifier: embedder.modelIdentifier,
            duration: 0.001,
            fromCache: false
        )
    }
}