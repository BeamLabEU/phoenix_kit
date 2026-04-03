#!/bin/bash
# Seamless agent runner - launches visual agent AND returns result
#
# Usage:
#   ./scripts/agent.sh "prompt" [options]
#
# This script:
#   1. Launches agent in tmux pane (user sees progress)
#   2. Waits for completion
#   3. Returns the result to stdout
#
# Perfect for programmatic use while maintaining visual feedback.

set -e

PROMPT=""
TOOLS="Read,Grep,Glob,Bash"
NEW_WINDOW=false
TIMEOUT=300  # 5 minutes default
SESSION="phoenixkit"
OUTPUT_DIR="/tmp/claude_agents"

while [[ $# -gt 0 ]]; do
    case $1 in
        --tools) TOOLS="$2"; shift 2 ;;
        --new-window) NEW_WINDOW=true; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --session) SESSION="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 'prompt' [options]"
            echo ""
            echo "Launches agent with visual tmux output and returns result."
            echo ""
            echo "Options:"
            echo "  --tools TOOLS    Allowed tools (default: Read,Grep,Glob,Bash)"
            echo "  --new-window     Use new tmux window"
            echo "  --timeout SECS   Max wait time (default: 300)"
            exit 0
            ;;
        *) [ -z "$PROMPT" ] && PROMPT="$1"; shift ;;
    esac
done

[ -z "$PROMPT" ] && { echo "Error: No prompt provided" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"

AGENT_ID="$(date +%Y%m%d_%H%M%S)_$$"
OUTPUT_FILE="${OUTPUT_DIR}/agent_${AGENT_ID}.txt"
STATUS_FILE="${OUTPUT_DIR}/agent_${AGENT_ID}.status"

TARGET_WINDOW=$(tmux display-message -p '#{window_index}' 2>/dev/null || echo "4")

ESCAPED_PROMPT=$(printf '%s' "$PROMPT" | sed "s/'/'\\\\''/g")

AGENT_CMD="(
echo 'STARTED' > '${STATUS_FILE}'
echo '🤖 Agent ${AGENT_ID}'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
claude -p '${ESCAPED_PROMPT}' --allowedTools '${TOOLS}' 2>&1 | tee '${OUTPUT_FILE}'
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
echo 'COMPLETED' > '${STATUS_FILE}'
sleep 3
)"

if [ "$NEW_WINDOW" = true ]; then
    tmux new-window -t "$SESSION" -n "Agent" "$AGENT_CMD"
else
    tmux split-window -h -t "${SESSION}:${TARGET_WINDOW}" "$AGENT_CMD"
fi

# Wait for completion
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -f "$STATUS_FILE" ] && [ "$(cat "$STATUS_FILE" 2>/dev/null)" = "COMPLETED" ]; then
        cat "$OUTPUT_FILE"
        rm -f "$OUTPUT_FILE" "$STATUS_FILE" 2>/dev/null
        exit 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "Error: Agent timed out after ${TIMEOUT}s" >&2
[ -f "$OUTPUT_FILE" ] && cat "$OUTPUT_FILE"
exit 1
