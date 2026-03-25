#!/bin/bash
# PhoenixKit Container Initialization Script
# Run after container creation: docker exec phoenix_kit /app/scripts/init-container.sh

set -e

echo "=== PhoenixKit Container Initialization ==="

# Install required packages
echo "Installing packages..."
apt-get update -qq
apt-get install -y -qq tmux git curl lsof net-tools

# Install Node.js and Claude Code
if ! command -v node &> /dev/null; then
    echo "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
fi

if ! command -v claude &> /dev/null; then
    echo "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash && export PATH="/root/.local/bin:$PATH"
fi

# Create OSC52 copy script for tmux clipboard passthrough
echo "Setting up OSC52 clipboard..."
cat > /usr/local/bin/osc52-copy.sh << 'EOFCOPY'
#!/bin/bash
# OSC 52 clipboard copy with DCS passthrough for nested tmux
read input
encoded=$(echo -n "$input" | base64 | tr -d '\n')

# Check if we're in a tmux session
if [ -n "$TMUX" ]; then
    # Use DCS passthrough for nested tmux
    printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$encoded"
else
    # Direct OSC 52
    printf '\e]52;c;%s\a' "$encoded"
fi
EOFCOPY
chmod +x /usr/local/bin/osc52-copy.sh

# Setup tmux config if not exists
if [ ! -f /root/.tmux.conf ]; then
    echo "Setting up tmux configuration..."
    cat > /root/.tmux.conf << 'EOFTMUX'
# PhoenixKit Container Tmux Config

# Container prefix: Ctrl-B (different from host Ctrl-A)
set -g prefix C-b
bind C-b send-prefix

# General settings
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g history-limit 50000
set -g display-time 4000
set -s escape-time 0

# Terminal colors
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",*256col*:Tc"

# Key bindings
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind x kill-pane
bind z resize-pane -Z

# Vi mode
setw -g mode-keys vi
bind-key -T copy-mode-vi 'v' send -X begin-selection
bind-key -T copy-mode-vi 'y' send -X copy-pipe-and-cancel "/usr/local/bin/osc52-copy.sh"
bind-key -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "/usr/local/bin/osc52-copy.sh"
bind-key -T copy-mode MouseDragEnd1Pane send -X copy-pipe-and-cancel "/usr/local/bin/osc52-copy.sh"
bind Y run-shell "tmux save-buffer - | /usr/local/bin/osc52-copy.sh"

# OSC 52 clipboard support
set -g set-clipboard on
set -g allow-passthrough on
set -ag terminal-overrides ",xterm*:Ms=\\E]52;c;%p2%s\\7"
set -ag terminal-overrides ",screen*:Ms=\\E]52;c;%p2%s\\7"
set -ag terminal-overrides ",tmux*:Ms=\\E]52;c;%p2%s\\7"

# Status bar
set -g status-position bottom
set -g status-style bg=colour234,fg=colour137
set -g status-left '#[fg=colour233,bg=colour245,bold] #{session_name} '
set -g status-right '#[fg=colour233,bg=colour241,bold] %H:%M '
setw -g window-status-format ' #I:#W '
setw -g window-status-current-format '#[fg=colour233,bg=colour81,bold] #I:#W '
EOFTMUX
fi

# Setup Logger filter for TLS warnings
HYDROFORCE_DIR="/root/projects/hydroforce"
if [ -d "$HYDROFORCE_DIR" ]; then
    echo "Setting up Logger filter for TLS warnings..."

    FILTER_FILE="$HYDROFORCE_DIR/lib/phoenixkit_hello_world/logger_filter.ex"
    if [ ! -f "$FILTER_FILE" ]; then
        cat > "$FILTER_FILE" << 'EOFFILTER'
defmodule PhoenixkitHelloWorld.LoggerFilter do
  @moduledoc """
  Logger filter to suppress noise from bot scans on exposed debug ports.
  """

  def filter(%{msg: {:string, msg}}, _opts) do
    if String.contains?(to_string(msg), "TLS received on a clear channel") do
      :stop
    else
      :ignore
    end
  end

  def filter(%{msg: {:report, %{msg: msg}}}, _opts) when is_binary(msg) do
    if String.contains?(msg, "TLS received on a clear channel") do
      :stop
    else
      :ignore
    end
  end

  def filter(_event, _opts), do: :ignore
end
EOFFILTER
    fi

    # Add config if not present
    if ! grep -q "LoggerFilter" "$HYDROFORCE_DIR/config/dev.exs" 2>/dev/null; then
        cat >> "$HYDROFORCE_DIR/config/dev.exs" << 'EOFCONFIG'

# Filter out TLS-on-clear-channel warnings from bots scanning port 4002
config :logger, :default_handler,
  filters: [
    tls_warning_filter: {&PhoenixkitHelloWorld.LoggerFilter.filter/2, []}
  ]
EOFCONFIG
    fi
fi

# Setup SSH for GitHub (port 443)
mkdir -p /root/.ssh
if [ ! -f /root/.ssh/config ]; then
    cat > /root/.ssh/config << 'EOFSSH'
Host github.com
  Hostname ssh.github.com
  Port 443
  User git
EOFSSH
    chmod 600 /root/.ssh/config
fi

echo "=== Initialization complete ==="
echo ""
echo "Next steps:"
echo "  1. Generate SSH key if needed: ssh-keygen -t ed25519 -C 'phoenix_kit@laisk'"
echo "  2. Add key to GitHub: cat /root/.ssh/id_ed25519.pub"
echo "  3. Clone hydroforce: git clone git@github.com:timujinne/dev.enter-t.net-Hydroforce.git /root/projects/hydroforce"
echo "  4. Start tmux: tmux new -s LAISK"
