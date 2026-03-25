#!/bin/bash
# Run Claude Code agent in a new tmux pane with live output
#
# Usage:
#   ./scripts/run_agent.sh "your prompt here" [options]
#
# Options:
#   --tools "Read,Grep,Glob"   Tools to allow (default: Read,Grep,Glob,Bash)
#   --new-window               Create new window instead of splitting current
#   --window N                 Target specific window number
#
# Examples:
#   ./scripts/run_agent.sh "find all TODOs"
#   ./scripts/run_agent.sh "analyze migrations" --tools "Read,Grep"
#   ./scripts/run_agent.sh "review code" --new-window

set -e

# Defaults
PROMPT=""
TOOLS="Read,Grep,Glob,Bash"
NEW_WINDOW=false
TARGET_WINDOW=""
SESSION="phoenixkit"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tools)
            TOOLS="$2"
            shift 2
            ;;
        --new-window)
            NEW_WINDOW=true
            shift
            ;;
        --window)
            TARGET_WINDOW="$2"
            shift 2
            ;;
        --session)
            SESSION="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 'prompt' [options]"
            echo ""
            echo "Options:"
            echo "  --tools TOOLS      Comma-separated tools (default: Read,Grep,Glob,Bash)"
            echo "  --new-window       Create new window instead of splitting"
            echo "  --window N         Target specific window number"
            echo "  --session NAME     tmux session name (default: phoenixkit)"
            echo ""
            echo "Examples:"
            echo "  $0 'find all TODOs'"
            echo "  $0 'analyze code' --tools 'Read,Grep'"
            echo "  $0 'review changes' --new-window"
            exit 0
            ;;
        *)
            if [ -z "$PROMPT" ]; then
                PROMPT="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo "Error: No prompt provided"
    echo "Usage: $0 'prompt' [options]"
    echo "Run '$0 --help' for more options"
    exit 1
fi

# Determine current window if not specified
if [ -z "$TARGET_WINDOW" ]; then
    # Try to get current window from tmux
    TARGET_WINDOW=$(tmux display-message -p '#{window_index}' 2>/dev/null || echo "")
    if [ -z "$TARGET_WINDOW" ]; then
        # Fallback: find window with claude running
        TARGET_WINDOW=$(tmux list-panes -s -t "$SESSION" -F '#{window_index} #{pane_current_command}' 2>/dev/null | grep -m1 'claude' | awk '{print $1}' || echo "1")
    fi
fi

# Agent command
AGENT_CMD="echo '🤖 Agent starting...' && \
echo '📋 Prompt: ${PROMPT}' && \
echo '🔧 Tools: ${TOOLS}' && \
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' && \
claude -p \"${PROMPT}\" --allowedTools \"${TOOLS}\" ; \
echo '' && \
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' && \
echo '✅ Agent finished. Press Enter to close.' && \
read"

if [ "$NEW_WINDOW" = true ]; then
    # Create new window
    WINDOW_NAME="Agent-$(date +%H%M%S)"
    tmux new-window -t "$SESSION" -n "$WINDOW_NAME" "$AGENT_CMD"
    echo "Agent launched in new window: $WINDOW_NAME"
else
    # Split current/target window
    tmux split-window -h -t "${SESSION}:${TARGET_WINDOW}" "$AGENT_CMD"
    echo "Agent launched in ${SESSION}:${TARGET_WINDOW} (split pane)"
fi
