#!/bin/bash
# Run Claude agent with BOTH visual output in tmux AND result file for seamless retrieval
#
# Usage:
#   ./scripts/run_agent_with_output.sh "prompt" [options]
#
# The script:
#   1. Creates a tmux pane for visual monitoring (user can watch progress)
#   2. Saves full output to a temp file
#   3. Returns the output file path for programmatic reading
#
# Options:
#   --tools "Read,Grep"   Allowed tools (default: Read,Grep,Glob,Bash)
#   --new-window          Create new window instead of splitting
#   --json                Output in JSON format
#   --wait                Wait for completion and print result

set -e

PROMPT=""
TOOLS="Read,Grep,Glob,Bash"
NEW_WINDOW=false
JSON_OUTPUT=false
WAIT_FOR_RESULT=false
SESSION="phoenixkit"
OUTPUT_DIR="/tmp/claude_agents"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tools) TOOLS="$2"; shift 2 ;;
        --new-window) NEW_WINDOW=true; shift ;;
        --json) JSON_OUTPUT=true; shift ;;
        --wait) WAIT_FOR_RESULT=true; shift ;;
        --session) SESSION="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 'prompt' [options]"
            echo ""
            echo "Options:"
            echo "  --tools TOOLS    Allowed tools (default: Read,Grep,Glob,Bash)"
            echo "  --new-window     Create new tmux window"
            echo "  --json           JSON output format"
            echo "  --wait           Wait and print result when done"
            echo ""
            echo "Returns: Path to output file"
            exit 0
            ;;
        *) [ -z "$PROMPT" ] && PROMPT="$1"; shift ;;
    esac
done

[ -z "$PROMPT" ] && { echo "Error: No prompt"; exit 1; }

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate unique output file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
AGENT_ID="${TIMESTAMP}_$$"
OUTPUT_FILE="${OUTPUT_DIR}/agent_${AGENT_ID}.txt"
STATUS_FILE="${OUTPUT_DIR}/agent_${AGENT_ID}.status"
JSON_FILE="${OUTPUT_DIR}/agent_${AGENT_ID}.json"

# Get current window
TARGET_WINDOW=$(tmux display-message -p '#{window_index}' 2>/dev/null || echo "4")

# Prepare output format flag
OUTPUT_FLAG=""
if [ "$JSON_OUTPUT" = true ]; then
    OUTPUT_FLAG="--output-format json"
fi

# Escape prompt for shell
ESCAPED_PROMPT=$(printf '%s' "$PROMPT" | sed "s/'/'\\\\''/g")

# Agent command that saves output to file
AGENT_CMD="(
echo 'STARTED' > '${STATUS_FILE}'
echo '🤖 Agent: ${AGENT_ID}'
echo '📋 Prompt: ${ESCAPED_PROMPT}'
echo '🔧 Tools: ${TOOLS}'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# Run claude and tee output to file
claude -p '${ESCAPED_PROMPT}' --allowedTools '${TOOLS}' ${OUTPUT_FLAG} 2>&1 | tee '${OUTPUT_FILE}'

echo ''
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo '✅ Done. Output saved to: ${OUTPUT_FILE}'
echo 'COMPLETED' > '${STATUS_FILE}'

# Keep pane open briefly for viewing
echo 'Press Enter to close...'
read -t 60 || true
)"

# Launch in tmux
if [ "$NEW_WINDOW" = true ]; then
    WINDOW_NAME="Agent-${AGENT_ID}"
    tmux new-window -t "$SESSION" -n "$WINDOW_NAME" "$AGENT_CMD"
else
    tmux split-window -h -t "${SESSION}:${TARGET_WINDOW}" "$AGENT_CMD"
fi

# Output file path for caller
echo "AGENT_ID=${AGENT_ID}"
echo "OUTPUT_FILE=${OUTPUT_FILE}"
echo "STATUS_FILE=${STATUS_FILE}"

# If --wait, poll for completion and print result
if [ "$WAIT_FOR_RESULT" = true ]; then
    echo "Waiting for agent to complete..."
    while [ ! -f "$STATUS_FILE" ] || [ "$(cat "$STATUS_FILE" 2>/dev/null)" != "COMPLETED" ]; do
        sleep 2
    done
    echo ""
    echo "=== AGENT RESULT ==="
    cat "$OUTPUT_FILE"
fi
