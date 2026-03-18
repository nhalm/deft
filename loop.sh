#!/bin/bash

cd "$(dirname "$0")"

# Signal to command templates that we're in an automated loop
export SPECD_LOOP=1

# Defaults
MAX_CYCLES=5
CYCLE=0
AUDIT_MODE="ready"  # ready | full | skip
MODEL_IMPLEMENT="claude-sonnet-4-5-20250929"
MODEL_AUDIT="claude-opus-4-6"
MODEL_REVIEW="claude-haiku-4-5-20251001"

# Parse flags
while [[ $# -gt 0 ]]; do
    case $1 in
        --full-audit)  AUDIT_MODE="full"; shift ;;
        --skip-audit)  AUDIT_MODE="skip"; shift ;;
        --max-cycles)  MAX_CYCLES="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; echo "Usage: ./loop.sh [--full-audit | --skip-audit] [--max-cycles N]"; exit 1 ;;
    esac
done

echo "=== Audit mode: ${AUDIT_MODE} ==="

# Check output file for fatal errors. Returns 0 if fatal error found.
check_fatal_error() {
    local file="$1"
    local phase="$2"

    # Token/usage limit reached (empty output or explicit limit message)
    if [ ! -s "$file" ] || grep -q 'Limit reached' "$file"; then
        echo "=== Token limit reached during ${phase} ==="
        return 0
    fi

    # API rate limit
    if grep -q '"error":"rate_limit"' "$file"; then
        echo "=== API rate limit reached during ${phase} ==="
        return 0
    fi

    # API server errors
    if grep -q 'API Error: 5[0-9][0-9]' "$file" || grep -q '"type":"api_error"' "$file"; then
        echo "=== API error during ${phase} ==="
        echo "Check $file for details"
        return 0
    fi

    # is_error flag on the final result line (not tool results mid-conversation)
    if grep '"type":"result"' "$file" | grep -q '"is_error":true'; then
        echo "=== Error during ${phase} ==="
        echo "Check $file for details"
        return 0
    fi

    return 1
}

while [ $CYCLE -lt $MAX_CYCLES ]; do
    CYCLE=$((CYCLE + 1))
    TASK_NUM=0

    echo "=== Cycle ${CYCLE}/${MAX_CYCLES} ==="

    # Step 1: Review intake — process specd_review.md into specd_work_list.md
    echo "=== Review intake ==="
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    REVIEW_OUTPUT="/tmp/${PWD##*/}-review-${TIMESTAMP}.txt"

    cat .claude/commands/specd/review-intake.md | claude -p \
        --model "$MODEL_REVIEW" \
        --dangerously-skip-permissions \
        --output-format=stream-json \
        --verbose \
        | tee "$REVIEW_OUTPUT" \
        | npx repomirror visualize

    if check_fatal_error "$REVIEW_OUTPUT" "review intake"; then
        exit 1
    fi

    # Step 2: Implement loop — work through specd_work_list.md one item at a time
    while true; do
        TASK_NUM=$((TASK_NUM + 1))
        TIMESTAMP=$(date +%Y%m%d-%H%M%S)
        OUTPUT_FILE="/tmp/${PWD##*/}-impl-${TIMESTAMP}-${TASK_NUM}.txt"

        # Pre-select next unblocked work item to avoid agent reading/scanning
        NEXT_ITEM=$(grep -n '^- ' specd_work_list.md | grep -v '(blocked:' | head -1)
        if [ -z "$NEXT_ITEM" ]; then
            echo "=== All work items blocked or complete ==="
            break
        fi

        ITEM_LINE=$(echo "$NEXT_ITEM" | cut -d: -f1)
        ITEM_TEXT=$(echo "$NEXT_ITEM" | cut -d: -f2- | sed 's/^- //')

        # Walk backwards from the item line to find the spec header (## spec-name vX.Y)
        SPEC_HEADER=$(head -n "$ITEM_LINE" specd_work_list.md | grep '^## ' | tail -1)
        SPEC_NAME=$(echo "$SPEC_HEADER" | sed 's/^## //' | awk '{print $1}')

        echo "=== Cycle ${CYCLE} — Task ${TASK_NUM}: ${SPEC_NAME} ==="
        echo "  Item: ${ITEM_TEXT:0:100}..."

        PROMPT=$(cat <<PROMPT_EOF
Study AGENTS.md for guidelines.

## Your work item

Spec: ${SPEC_NAME}
Item: ${ITEM_TEXT}

## Steps

1. Read the spec at specs/${SPEC_NAME}.md (or specs/ subdirectory if not found at top level). The spec is the source of truth.
2. Implement this ONE work item. If code contradicts the spec, fix the code first.
3. Validate: run the test suite and fix any lint/format errors.
4. Record: log significant decisions to specd_decisions.jsonl (source: "implement", decision_by: "claude").
5. Update tracking files and commit:
   - Add a line at the TOP of specd_history.md: \`- **${SPEC_HEADER#"## "} ($(date +%Y-%m-%d)):** ${ITEM_TEXT}\`
   - Remove the completed item from specd_work_list.md
   - Check specd_work_list.md for items with \`(blocked: ...)\` annotations referencing your completed work — remove resolved blockers
   - Commit ALL changes in a single commit
   - Output \`TASK_COMPLETE: true\` when done
PROMPT_EOF
)

        echo "$PROMPT" | claude -p \
            --model "$MODEL_IMPLEMENT" \
            --dangerously-skip-permissions \
            --output-format=stream-json \
            --verbose \
            | tee "$OUTPUT_FILE" \
            | npx repomirror visualize

        if check_fatal_error "$OUTPUT_FILE" "implement task ${TASK_NUM}"; then
            exit 1
        fi

        sleep 2
    done

    # Step 3: Audit
    if [ "$AUDIT_MODE" = "skip" ]; then
        echo "=== Audit skipped (--skip-audit) ==="
        echo "=== Loop complete after ${CYCLE} cycle(s) ==="
        exit 0
    fi

    AUDIT_CMD="specd/audit.md"
    if [ "$AUDIT_MODE" = "full" ]; then
        AUDIT_CMD="specd/full-audit.md"
    fi

    echo "=== Audit phase (${AUDIT_MODE}) ==="
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    AUDIT_OUTPUT="/tmp/${PWD##*/}-audit-${TIMESTAMP}.txt"

    cat ".claude/commands/${AUDIT_CMD}" | claude -p \
        --model "$MODEL_AUDIT" \
        --dangerously-skip-permissions \
        --output-format=stream-json \
        --verbose \
        | tee "$AUDIT_OUTPUT" \
        | npx repomirror visualize

    if check_fatal_error "$AUDIT_OUTPUT" "audit"; then
        exit 1
    fi

    # If audit found nothing new, we're done
    if grep '"type":"result"' "$AUDIT_OUTPUT" | grep -q 'AUDIT_CLEAN: true'; then
        echo "=== Audit clean — nothing new found ==="
        echo "=== Loop complete after ${CYCLE} cycle(s) ==="
        exit 0
    fi

    echo "=== Audit found new items — starting cycle $((CYCLE + 1)) ==="
    sleep 2
done

echo "=== Cycle cap (${MAX_CYCLES}) reached — check specd_work_list.md and specd_review.md ==="
exit 0
