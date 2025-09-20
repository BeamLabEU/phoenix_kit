# Contributing to PhoenixKit

Thank you for your interest in contributing to PhoenixKit! This guide will help you set up a development environment and understand our contribution process.

## Initial Development Setup

To contribute to PhoenixKit, you'll need to set up a local development environment:

1. **Fork the Repository**: Fork [PhoenixKit on GitHub](https://github.com/BeamLabEU/phoenix_kit/fork) to your account
   - **Important**: Uncheck "Copy the `main` branch only" to get all branches including `dev`

2. **Clone Your Fork**:
```bash
# Using SSH (recommended if you have SSH keys set up)
git clone git@github.com:yourusername/phoenix_kit.git
# OR using HTTPS
git clone https://github.com/yourusername/phoenix_kit.git

cd phoenix_kit
```

3. **Create a Development Phoenix App**: Set up a Phoenix application for testing your PhoenixKit changes:
```bash
# Create a new Phoenix app adjacent to your phoenix_kit directory
cd ..
mix phx.new your_app_name  # Choose any name for your development app
cd your_app_name
```

4. **Configure Local Dependency**: Update your development app's `mix.exs` to use your local PhoenixKit:
```elixir
defp deps do
  [
    {:phoenix_kit, path: "../phoenix_kit"},
    {:igniter, "~> 0.6.0", only: [:dev]},      # Required for phoenix_kit.install task
    {:file_system, "~> 1.1.0", only: [:dev]},  # Required for live reloading
    # ... other Phoenix dependencies
  ]
end
```

5. **Install Dependencies**:
```bash
mix deps.get
mix ecto.create
```

6. **Run PhoenixKit Installation**:
```bash
mix phoenix_kit.install --repo YourApp.Repo  # Use your app's actual repo module
mix ecto.migrate
```

7. **Configure Tailwind CSS** (if using Tailwind CSS 4): Update your `assets/css/app.css` to point to your local PhoenixKit. Find the `@source` directives section and replace the phoenix_kit deps path:
```css
@import "tailwindcss" source(none);
@source "../css";
@source "../js";
@source "../../lib/your_app_web";
/* Replace the auto-generated deps path with your local path */
@source "../../../phoenix_kit";  /* was: @source "../../deps/phoenix_kit"; */
```

This replaces the default deps folder path with your local phoenix_kit development folder, ensuring Tailwind processes your local changes.

8. **Start Your Development Server**:
```bash
mix phx.server
```

You can now visit [`localhost:4000`](http://localhost:4000) to see your development app running with PhoenixKit. Any changes you make to files in the `phoenix_kit` directory will require manually running `mix deps.compile phoenix_kit --force` and refreshing your browser to see the changes.

## Contribution Workflow

1. **Make your changes** in the `phoenix_kit` directory

2. **Sync your fork with upstream**: Before finalizing your changes, ensure your fork is up to date:
   - Navigate to your fork on GitHub
   - Switch to the `dev` branch using the branch dropdown
   - Click the "Sync fork" button and then "Update branch"
   - In your local repository, pull the latest changes:
   ```bash
   git checkout dev
   git pull origin dev
   ```

3. **Update CHANGELOG.md**: Add an entry for your changes in the appropriate section:
   ```bash
   # Edit CHANGELOG.md to document your changes
   # Add your entry under the appropriate category (Added, Changed, Fixed, etc.)
   ```

4. **Commit and push** your changes:
   ```bash
   git add .
   git commit -m "Add your descriptive commit message"
   git push origin dev
   ```

5. **Create Pull Request**:
   - After pushing, you'll see a banner on GitHub indicating that your branch is ahead of the main repository
   - Click "Contribute" and then "Open a pull request"
   - GitHub will show the differences between your fork and the main repository
   - Click "Create pull request"
   - Enter a title and description of your changes
   - Ensure the base branch is set to `BeamLabEU/phoenix_kit:dev` (not main)
   - Click "Create pull request" to submit

## Development with Live Reloading

The basic setup above requires manually recompiling PhoenixKit after each change. To enable automatic hot reloading that detects changes and recompiles automatically, follow these steps:

### Method 1: Phoenix Built-in Systems (Recommended)

**Note**: The following steps are performed in your Phoenix development project (not in the phoenix_kit directory).

This method uses Phoenix's built-in CodeReloader and LiveReloader systems for automatic recompilation and browser refresh.

1. **Configure Phoenix.CodeReloader**: Add to your `config/dev.exs`:

```elixir
config :your_app, YourAppWeb.Endpoint,
  # ... existing config ...
  reloadable_apps: [:your_app, :phoenix_kit],
  reload_lib_dirs: ["lib", "../phoenix_kit/lib"]
```

2. **Configure Phoenix.LiveReloader**: Add to your `config/dev.exs`:

```elixir
# Configure Phoenix LiveReloader to watch the phoenix_kit library (sibling project)
config :phoenix_live_reload, :dirs, ["", "../phoenix_kit"]

# Add phoenix_kit pattern to live reload patterns
config :your_app, YourAppWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/your_app_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$",
      ~r"../phoenix_kit/lib/.*\.(ex|heex)$"  # Add this line
    ]
  ]
```

3. **Restart your Phoenix server**:

```bash
# In your development project directory
iex -S mix phx.server
```

**How it works:**
- When you edit phoenix_kit files, Phoenix.LiveReloader detects changes and triggers browser refresh
- During the refresh request, Phoenix.CodeReloader automatically recompiles changed files
- You see updated code immediately without manual recompilation

### Method 2: Custom FileWatcher (Fallback)

If the Phoenix built-in method doesn't work for your setup, you can use this custom approach:

**Note**: This method requires more custom code but provides the same user experience as Method 1. Use this only if the Phoenix built-in method doesn't work for your specific project structure or setup.

1. **Add FileWatcher Module**: Create a GenServer that monitors file changes in your development app at `lib/your_app/file_watcher.ex`:

```elixir
defmodule YourApp.FileWatcher do
  use GenServer
  require Logger

  def start_link(dirs) do
    GenServer.start_link(__MODULE__, dirs, name: __MODULE__)
  end

  def init(dirs) do
    {:ok, watcher_pid} = FileSystem.start_link(dirs: dirs)
    FileSystem.subscribe(watcher_pid)
    Logger.info("File watcher started for: #{inspect(dirs)}")
    {:ok, %{watcher_pid: watcher_pid}}
  end

  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    ext = Path.extname(path)
    Logger.info("File event detected - Path: #{path}, Extension: #{ext}, Events: #{inspect(events)}")

    if ext in [".ex", ".exs", ".heex", ".eex", ".leex"] do
      Logger.info("Processing change in #{path}, recompiling...")

      Task.start(fn ->
        :timer.sleep(100)

        # Recompile phoenix_kit dependency
        {output, _} = System.cmd("mix", ["deps.compile", "phoenix_kit", "--force"],
          cd: File.cwd!(), stderr_to_stdout: true)
        Logger.debug("Phoenix kit compile output: #{output}")

        # Compile main project
        {compile_output, _} = System.cmd("mix", ["compile"],
          cd: File.cwd!(), stderr_to_stdout: true)
        Logger.debug("Main project compile output: #{compile_output}")

        # Purge and reload modules
        purge_phoenix_kit_modules()

        # Trigger browser refresh
        trigger_browser_refresh()

        Logger.info("✅ External library reload complete - browser should refresh automatically")
      end)
    else
      Logger.debug("Ignoring file event for non-Elixir file: #{path}")
    end

    {:noreply, state}
  end

  defp purge_phoenix_kit_modules do
    :code.all_loaded()
    |> Enum.filter(fn {module, _} ->
      module_name = Atom.to_string(module)
      String.starts_with?(module_name, "Elixir.PhoenixKit")
    end)
    |> Enum.each(fn {module, _} ->
      Logger.info("Purging module: #{module}")
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp trigger_browser_refresh do
    # Touch CSS to trigger Phoenix LiveReload
    css_file = "priv/static/assets/app.css"
    if File.exists?(css_file) do
      File.touch!(css_file)
    else
      # Fallback: create temporary JS file
      dummy_file = "priv/static/phoenix_kit_reload.js"
      File.write!(dummy_file, "// Auto-reload trigger #{:erlang.system_time()}")
      Task.start(fn ->
        :timer.sleep(1000)
        File.rm(dummy_file)
      end)
    end
  end
end
```

2. **Start FileWatcher in Application**: Update your development app's `application.ex`:

```elixir
def start(_type, _args) do
  children = [
    # ... other children
    file_watcher_child(),
    YourAppWeb.Endpoint
  ]
  # ...
end

defp file_watcher_child do
  if Mix.env() == :dev do
    {YourApp.FileWatcher, ["../phoenix_kit/lib"]}  # Path to your local phoenix_kit
  else
    []
  end
end
```

## How Live Reloading Works

### Method 1 (Phoenix Built-in):
- **Phoenix.LiveReloader** monitors file changes and triggers browser refresh
- **Phoenix.CodeReloader** recompiles during the browser refresh request
- **Zero custom code** - uses standard Phoenix development workflow
- **Same user experience** - automatic refresh with updated code

### Method 2 (Custom FileWatcher):
- **FileWatcher** monitors all Elixir files and templates
- **Background recompilation** when files change (before browser refresh)
- **Module purging** to ensure fresh code is loaded
- **Custom browser refresh triggering** via file system manipulation
- **Same user experience** - automatic refresh with updated code

## Benefits of Live Reloading

- **Instant Feedback**: See your changes immediately in the browser
- **No Manual Steps**: No need to manually run `mix deps.compile` or restart the server
- **Template Support**: Works with both Elixir code and Phoenix templates
- **Browser Sync**: Automatic browser refresh on every change