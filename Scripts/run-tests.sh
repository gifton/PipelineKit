#!/bin/bash
# Run discovered PipelineKit tests, preserving each Swift command's verdict.
set -o pipefail

TARGET=""
FILTER=""
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--filter)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "Missing value for $1" >&2
                exit 2
            fi
            if [[ "$1" == --target ]]; then TARGET="$2"; else FILTER="$2"; fi
            shift 2 ;;
        --verbose) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -n "$TARGET" && ! "$TARGET" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Invalid target: $TARGET" >&2
    exit 2
fi

# Swift's list command emits test identifiers on stdout and diagnostics on stderr.
if ! tests=$(swift test list); then
    echo "Test discovery failed" >&2
    exit 1
fi

# Use Swift's regular-expression matching for the discovered identifiers.
script_dir=$(cd "$(dirname "$0")" && pwd)
if ! selection=$(swift "$script_dir/ci/select-tests.swift" "$TARGET" "$FILTER" <<< "$tests"); then
    exit 2
fi
pattern=${selection%%$'\n'*}
selected=${selection#*$'\n'}
if [[ "$selection" == "$pattern" || -z "$selected" ]]; then
    echo "No tests selected" >&2
    exit 1
fi

run_filter() {
    local pattern="$1" status=0
    echo "Running tests: $pattern"
    if [[ "$VERBOSE" == true ]]; then
        swift test --filter "$pattern" || status=$?
    else
        # Formatting is advisory; only Swift's exit status determines the verdict.
        swift test --filter "$pattern" 2>&1 | awk '/Test Suite|Executed|passed|failed/ { print }'
        status=${PIPESTATUS[0]}
    fi
    return "$status"
}

status=0
if [[ -n "$TARGET" && -n "$FILTER" ]]; then
    # Exact identifiers avoid broadening the intersection when the pattern matches
    # tests in multiple modules. Quote regex metacharacters in each identifier.
    run_filter "$pattern" || status=$?
elif [[ -n "$FILTER" ]]; then
    run_filter "$FILTER" || status=$?
elif [[ -n "$TARGET" ]]; then
    run_filter "^${TARGET}Tests\\." || status=$?
else
    modules=$(printf '%s\n' "$selected" | cut -d. -f1 | LC_ALL=C sort -u)
    while IFS= read -r module; do
        run_filter "^${module}\\." || status=1
    done <<< "$modules"
fi
exit "$status"
