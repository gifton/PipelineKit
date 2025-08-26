#!/bin/bash
# Coverage analysis tool for PipelineKit

echo "======================================"
echo "PipelineKit Coverage Analysis"
echo "======================================"
echo ""

# Function to analyze a module
analyze_module() {
    local module=$1
    local source_dir="Sources/$module"
    local test_dir="Tests/${module}Tests"
    
    echo "=== $module ==="
    
    # Count source files
    local source_count=$(find "$source_dir" -name "*.swift" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "Source files: $source_count"
    
    # Count test files
    local test_count=$(find "$test_dir" -name "*Tests.swift" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "Test files: $test_count"
    
    # Count test methods
    local test_methods=$(grep -r "func test" "$test_dir" --include="*.swift" 2>/dev/null | wc -l | tr -d ' ')
    echo "Test methods: $test_methods"
    
    # List untested components
    echo ""
    echo "Components needing tests:"
    find "$source_dir" -name "*.swift" -type f 2>/dev/null | while read source_file; do
        local component=$(basename "$source_file" .swift)
        local test_file="$test_dir"
        
        # Check if test exists for this component
        if ! find "$test_dir" -name "*${component}*Test*.swift" 2>/dev/null | grep -q .; then
            echo "  ❌ $component"
        fi
    done
    
    echo ""
}

# Analyze each module
for module in PipelineKitCore PipelineKitSecurity PipelineKitResilience PipelineKitObservability PipelineKitCache; do
    analyze_module "$module"
done

# Summary
echo "======================================"
echo "Summary"
echo "======================================"
echo ""
echo "Total source files: $(find Sources -name "*.swift" -type f | wc -l | tr -d ' ')"
echo "Total test files: $(find Tests -name "*Tests.swift" -type f | wc -l | tr -d ' ')"
echo "Total test methods: $(grep -r "func test" Tests --include="*.swift" | wc -l | tr -d ' ')"

# Priority components for testing
echo ""
echo "======================================"
echo "Priority Components for Testing"
echo "======================================"
echo ""
echo "1. Core Pipeline Components:"
echo "   - Pipeline.swift"
echo "   - Middleware.swift"
echo "   - CommandHandler.swift"
echo ""
echo "2. Context Management:"
echo "   - CommandContext.swift"
echo "   - CommandContext+Events.swift"
echo ""
echo "3. Error Handling:"
echo "   - PipelineError.swift"
echo "   - CancellationError.swift"
echo ""
echo "4. Security Components:"
echo "   - AuthenticationMiddleware.swift"
echo "   - AuthorizationMiddleware.swift"
echo "   - ValidationMiddleware.swift"