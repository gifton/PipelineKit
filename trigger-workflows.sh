#!/bin/bash

# Manual workflow triggers for PipelineKit

echo "🚀 PipelineKit Workflow Triggers"
echo "================================"
echo ""
echo "Select a workflow to trigger:"
echo "1) Full CI for current branch"
echo "2) Weekly Full CI" 
echo "3) Specialty Tests (Memory)"
echo "4) Specialty Tests (Performance)"
echo "5) Specialty Tests (Stress)"
echo "6) Specialty Tests (Security)"
echo "7) Nightly Build"
echo "8) Runner Health Check"
echo ""
read -p "Enter choice (1-8): " choice

BRANCH=$(git branch --show-current)

case $choice in
    1)
        echo "Triggering Full CI on branch: $BRANCH"
        gh workflow run ci.yml --ref $BRANCH
        ;;
    2)
        echo "Triggering Weekly Full CI on branch: $BRANCH"
        gh workflow run weekly-full-ci.yml --ref $BRANCH
        ;;
    3)
        echo "Triggering Memory Tests on branch: $BRANCH"
        gh workflow run specialty-tests.yml --ref $BRANCH -f test_type=memory-intensive
        ;;
    4)
        echo "Triggering Performance Baseline on branch: $BRANCH"
        gh workflow run specialty-tests.yml --ref $BRANCH -f test_type=performance-baseline
        ;;
    5)
        echo "Triggering Stress Tests on branch: $BRANCH"
        gh workflow run specialty-tests.yml --ref $BRANCH -f test_type=stress-testing
        ;;
    6)
        echo "Triggering Security Audit on branch: $BRANCH"
        gh workflow run specialty-tests.yml --ref $BRANCH -f test_type=security-audit
        ;;
    7)
        echo "Triggering Nightly Build on branch: $BRANCH"
        gh workflow run nightly.yml --ref $BRANCH
        ;;
    8)
        echo "Triggering Runner Health Check"
        gh workflow run runner-health.yml --ref $BRANCH
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "✅ Workflow triggered! Check status at:"
echo "https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions"