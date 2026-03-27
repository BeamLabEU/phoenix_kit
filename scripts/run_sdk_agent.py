#!/usr/bin/env python3
"""
Run Claude Agent SDK with live output in tmux pane.

Usage:
    python scripts/run_sdk_agent.py "your prompt" [options]

Options:
    --tools         Comma-separated tools (default: Read,Grep,Glob,Bash)
    --new-window    Create new tmux window instead of splitting
    --window N      Target specific window number
    --session NAME  tmux session name (default: phoenixkit)

Examples:
    python scripts/run_sdk_agent.py "analyze all migrations"
    python scripts/run_sdk_agent.py "find security issues" --tools "Read,Grep,Glob"
    python scripts/run_sdk_agent.py "refactor auth module" --new-window
"""

import asyncio
import argparse
import subprocess
import sys
import os
import shlex
from datetime import datetime

# Check if claude-agent-sdk is available
try:
    from claude_agent_sdk import query, ClaudeAgentOptions
    HAS_SDK = True
except ImportError:
    HAS_SDK = False


def get_current_window(session: str = "phoenixkit") -> str:
    """Get current tmux window index."""
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "#{window_index}"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass

    # Fallback: find window with claude running
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-s", "-t", session, "-F", "#{window_index} #{pane_current_command}"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split('\n'):
            if 'claude' in line:
                return line.split()[0]
    except Exception:
        pass

    return "1"


def create_tmux_pane(session: str, window: str) -> str:
    """Create a new tmux pane by splitting and return its ID."""
    result = subprocess.run(
        ["tmux", "split-window", "-h", "-t", f"{session}:{window}", "-P", "-F", "#{pane_id}"],
        capture_output=True, text=True
    )
    return result.stdout.strip()


def create_tmux_window(session: str, name: str = None) -> str:
    """Create a new tmux window and return its index."""
    if not name:
        name = f"Agent-{datetime.now().strftime('%H%M%S')}"
    result = subprocess.run(
        ["tmux", "new-window", "-t", session, "-n", name, "-P", "-F", "#{window_index}"],
        capture_output=True, text=True
    )
    return result.stdout.strip()


def send_to_pane(pane_id: str, text: str):
    """Send text to a tmux pane."""
    subprocess.run(["tmux", "send-keys", "-t", pane_id, text, "Enter"])


async def run_with_sdk(prompt: str, tools: list[str], pane_id: str = None):
    """Run agent using Claude Agent SDK."""
    print(f"🤖 Starting agent with SDK...")
    print(f"📋 Prompt: {prompt}")
    print(f"🔧 Tools: {', '.join(tools)}")
    print("━" * 50)

    async for message in query(
        prompt=prompt,
        options=ClaudeAgentOptions(allowed_tools=tools)
    ):
        output = str(message)
        print(output)
        if pane_id:
            send_to_pane(pane_id, output)

    print("━" * 50)
    print("✅ Agent finished")


def run_with_cli(prompt: str, tools: list[str], session: str, window: str, new_window: bool = False):
    """Run agent using claude CLI in tmux."""
    tools_str = ",".join(tools)

    # Escape prompt for shell
    escaped_prompt = prompt.replace('"', '\\"').replace("'", "'\\''")

    agent_cmd = f'''echo '🤖 Agent starting...' && \
echo '📋 Prompt: {escaped_prompt}' && \
echo '🔧 Tools: {tools_str}' && \
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' && \
claude -p "{escaped_prompt}" --allowedTools "{tools_str}" ; \
echo '' && \
echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' && \
echo '✅ Agent finished. Press Enter to close.' && \
read'''

    if new_window:
        window_name = f"Agent-{datetime.now().strftime('%H%M%S')}"
        subprocess.run([
            "tmux", "new-window", "-t", session, "-n", window_name, agent_cmd
        ])
        print(f"Agent launched in new window: {window_name}")
    else:
        subprocess.run([
            "tmux", "split-window", "-h", "-t", f"{session}:{window}", agent_cmd
        ])
        print(f"Agent launched in {session}:{window} (split pane)")


def main():
    parser = argparse.ArgumentParser(
        description="Run Claude agent with live tmux output",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s "analyze all migrations"
  %(prog)s "find security issues" --tools "Read,Grep,Glob"
  %(prog)s "refactor auth module" --new-window
  %(prog)s "review code" --window 2
        """
    )
    parser.add_argument("prompt", help="The prompt for the agent")
    parser.add_argument("--tools", default="Read,Grep,Glob,Bash",
                        help="Comma-separated list of allowed tools (default: Read,Grep,Glob,Bash)")
    parser.add_argument("--new-window", action="store_true",
                        help="Run in a new tmux window")
    parser.add_argument("--window", type=str, default=None,
                        help="Target tmux window number (default: current)")
    parser.add_argument("--session", default="phoenixkit",
                        help="tmux session name (default: phoenixkit)")
    parser.add_argument("--sdk", action="store_true",
                        help="Force SDK mode (run in current terminal, not tmux)")

    args = parser.parse_args()
    tools = [t.strip() for t in args.tools.split(",")]

    # Determine target window
    window = args.window if args.window else get_current_window(args.session)

    if args.sdk and HAS_SDK:
        # Use SDK directly in current terminal
        asyncio.run(run_with_sdk(args.prompt, tools))
    else:
        # Use CLI in tmux pane/window
        run_with_cli(args.prompt, tools, args.session, window, args.new_window)


if __name__ == "__main__":
    main()
