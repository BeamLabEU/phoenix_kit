# Contributing to PhoenixKit

Thank you for your interest in contributing to PhoenixKit! This guide will help you set up a development environment and understand our contribution process.

## Initial Development Setup

To contribute to PhoenixKit, you'll need to set up a local development environment:

1. **Fork the Repository**: Fork [PhoenixKit on GitHub](https://github.com/BeamLabEU/phoenix_kit/fork) to your account
   - **Important**: Uncheck "Copy the `main` branch only" to get all branches including `dev`

2. **Clone Your Fork**:
```bash
git clone git@github.com:yourusername/phoenix_kit.git
```

3. **Create a Development Phoenix App**: Set up a Phoenix application for testing your PhoenixKit changes:
Make sure you have latest [Elixir Phoenix Framework](https://hexdocs.pm/phoenix/installation.html).
```bash
mix archive.install hex phx_new
```
Then create a new Phoenix app adjacent to your phoenix_kit directory.
```bash
mix phx.new your_app_name  # Choose any name for your development app
cd your_app_name
```

4. **Configure Local Dependency**: Update your development app's `mix.exs` to use your local PhoenixKit:
```elixir
defp deps do
  [
    {:phoenix_kit, path: "../phoenix_kit"},
    {:igniter, "~> 0.6.0", only: [:dev]},      # Required for phoenix_kit.install task
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
mix phoenix_kit.install
```

7. **Configure Tailwind CSS**: Update your `assets/css/app.css` to point to your local PhoenixKit git clone. Find the `@source` directives section and replace the phoenix_kit deps path:
```css
@import "tailwindcss" source(none);
@source "../css";
@source "../js";
@source "../../lib/your_app_web";
/* Replace the auto-generated deps path with your local path */
@source "../../../phoenix_kit";  /* was: @source "../../deps/phoenix_kit"; */
```

This replaces the default deps folder path with your local phoenix_kit development folder, ensuring Tailwind processes your local changes.

8. **Rebuild and deploy assets**:
```bash
mix assets.build
mix assets.deploy
```

9. **Start Your Development Server**:
```bash
mix phx.server
```

You can now visit [`http://localhost:4000`](http://localhost:4000) to see your development app running with PhoenixKit, and you can visit PhoenixKit powered pages:
- http://localhost:4000{prefix}/users/register (first registered user will become admin and a product owner)
- http://localhost:4000{prefix}/users/log-in (you should be able to login)
- http://localhost:4000{prefix}/admin/dashboard (and access phoenix_kit admin panel)

Keep in mind, that any changes you make to files in the `phoenix_kit` directory will require manually running `mix deps.compile phoenix_kit --force` and refreshing your browser to see the changes, so let's configure live reloading for a better development experience.

10. **Configure Live Reloading**:
To enable automatic hot reloading that detects changes and recompiles automatically, configure Phoenix's built-in systems:

**Note**: The following configuration is added to your Phoenix development project (not in the phoenix_kit directory).

10.1. **Configure your Endpoint**:
Edit your `config/dev.exs` file, and find your Endpoint configuration, which starts something like this:
```elixir
config :your_app, YourAppWeb.Endpoint,
```

And inside of Endpoint configuration, just before watchers list, add these 2 lines (and don't forget to change `:your_app`)
```elixir
reloadable_apps: [:your_app, :phoenix_kit],
reload_lib_dirs: ["lib", "../phoenix_kit/lib"],
```

10.2. **Configure Phoenix LiveReloader to watch the phoenix_kit library**:

Just below Endpoint configuration, in your `config/dev.exs` file add:

```elixir
config :phoenix_live_reload, :dirs, ["", "../phoenix_kit"]
```

Find live_reload configuration and add extra line to patterns list:

```elixir
~r"../phoenix_kit/lib/.*\.(ex|heex)$"
```

So, live_reload configration should look like this:

```elixir
# Watch static and templates for browser reloading.
config :pk_test, PkTestWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/pk_test_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$",
      ~r"../phoenix_kit/lib/.*\.(ex|heex)$"
    ]
  ]
```

10.3. **Restart your Phoenix app**:

Ctrl+C couple of times to break out from running app and start your app again:

```bash
# In your development project directory
mix phx.server
```

**How it works:**
- When you edit phoenix_kit files, Phoenix.LiveReloader detects changes and triggers browser refresh
- During the refresh request, Phoenix.CodeReloader automatically recompiles changed files
- You see updated code immediately without manual recompilation

## Contribution Workflow

Once you have your development environment set up with live reloading, follow these steps to contribute:

1. **Switch to dev branch**:
```bash
git checkout dev
```

2. **Make your changes** in the `phoenix_kit` directory - you'll see them live in your browser, if live reloading setup was done correctly.

3. **Commit and push** your changes:
```bash
git add file_you_changed
git commit
git push dev
```

4. **Create Pull Request**:
   - After pushing, you'll see a banner on GitHub indicating that your branch is ahead of the main repository
   - Click "Contribute" and then "Open a pull request"
   - GitHub will show the differences between your fork and the main repository
   - Click "Create pull request"
   - Enter a title and description of your changes
   - Ensure the base branch is set to `BeamLabEU/phoenix_kit:dev` (not main)
   - Click "Create pull request" to submit
