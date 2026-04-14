defmodule Mix.Tasks.PhoenixKit.Gen.User.Dashboard.Advanced do
  @moduledoc """
  Igniter task that generates an advanced user dashboard page with tab configuration.

  ## Usage

      mix phoenix_kit.gen.user.advanced.dashboard "Example"

  ## Arguments

  - `tab_title` - The display title for the tab (e.g., "Example")

  ## Options

  - `--url` - The URL path for the tab (optional, derived from title if not provided)
  - `--category` - The category name (optional, defaults to "General")
  - `--icon` - Heroicon name for the tab (optional, defaults to "hero-document")
  - `--description` - Brief description for the tab (optional)
  - `--category-icon` - Heroicon name for the category (optional, defaults to "hero-folder"). Only used when creating a new category.
  - `--index` - Generate as main dashboard index (skips config, for overriding /dashboard)

  ## Examples

      # Simple - uses all defaults
      mix phoenix_kit.gen.user.advanced.dashboard "Example"

      # With custom category
      mix phoenix_kit.gen.user.advanced.dashboard "Example" --category="Farm Management"

      # With custom icon
      mix phoenix_kit.gen.user.advanced.dashboard "Example" --icon="hero-chart-bar"

      # Full control
      mix phoenix_kit.gen.user.advanced.dashboard "Example" --url="/custom/path" --icon="hero-user"

      # Generate as main dashboard index (overrides /dashboard)
      mix phoenix_kit.gen.user.advanced.dashboard "Dashboard" --url="/dashboard" --index --description="Welcome"

  """

  @shortdoc "Generates user dashboard page with tab configuration"

  use Igniter.Mix.Task

  alias PhoenixKit.Install.IgniterConfig
  alias PhoenixKit.Install.IgniterHelpers
  import Plug.Conn
  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :phoenix_kit,
      example: "mix phoenix_kit.gen.user.advanced.dashboard \"Example\"",
      schema: [
        url: :string,
        category: :string,
        icon: :string,
        description: :string,
        category_icon: :string,
        index: :boolean
      ],
      aliases: [u: :url, c: :category, i: :icon, d: :description, ci: :category_icon]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    # Get options and arguments from igniter context
    opts = igniter.args.options
    argv = igniter.args.argv


    case parse_args(argv, opts) do
      {:ok, {tab_title, category, url}} ->
        igniter = igniter
        |> create_live_view(tab_title, url, opts)
        |> maybe_add_dashboard_tab(category, tab_title, url, opts)

         Igniter.create_new_file(igniter, "assets/js/hooks/grid.js", grid(), on_format: :skip)
         Igniter.create_new_file(igniter, "assets/js/hooks/context_menu.js", context(), on_format: :skip)

         Igniter.add_notice(igniter, """
    Next Steps: Install gridstack via package manager and add hooks to app.js

    Usage: npm --prefix ./assets install gridstack
    add: import GridHook from "./hooks/grid"
         import { ContextMenu } from "./hooks/context_menu"

         let Hooks = {}
         Hooks.Grid = GridHook
         Hooks.ContextMenu = ContextMenu

         const liveSocket = new LiveSocket("/live", Socket, {
         longPollFallbackMs: 2500,
          params: {_csrf_token: csrfToken},
          hooks: {...window.PhoenixKitHooks, ...colocatedHooks, ...Hooks},
          })
    """)

      {:error, message} ->
        Igniter.add_notice(igniter, """
        ❌ Error: #{message}

        Usage: mix phoenix_kit.gen.user.advanced.dashboard <tab_title>
        Example: mix phoenix_kit.gen.user.advanced.dashboard "Example"
        """)
    end
  end

  @impl Mix.Task
  def run(argv) do
    # Handle --help flag manually
    if "--help" in argv or "-h" in argv do
      Mix.shell().info("""
      Generates a user dashboard page with tab configuration.

      Usage:

          mix phoenix_kit.gen.user.advanced.dashboard "Example"

      Arguments:

        tab_title  - The display title for the tab

      Options:

        --url           - The URL path for the tab (optional, derived from title)
        --category      - The category name (optional, defaults to "General")
        --icon          - Heroicon name for the tab (optional, defaults to "hero-document")
        --description   - Brief description for the tab (optional)
        --category-icon - Heroicon name for the category (optional, defaults to "hero-folder")
        --index         - Generate as main dashboard index (skips config, for overriding /dashboard)

      Examples:

          # Simple - uses all defaults
          mix phoenix_kit.gen.user.advanced.dashboard "Example"

          # With custom category
          mix phoenix_kit.gen.user.advanced.dashboard "Example" --category="Farm Management"

          # With custom icon
          mix phoenix_kit.gen.user.advanced.dashboard "Example" --icon="hero-chart-bar"

          # Full control
          mix phoenix_kit.gen.user.advanced.dashboard "Example" --url="/custom/path" --icon="hero-user"

          # Generate as main dashboard index (overrides /dashboard)
          mix phoenix_kit.gen.user.advanced.dashboard "Dashboard" --url="/dashboard" --index --description="Welcome"

      Notes:

        - Creates a LiveView file for the dashboard page
        - Adds tab configuration to config/config.exs under :user_dashboard_categories (unless --index)
        - After adding the route, run: mix compile --force
      """)

      :ok
    else
      # Delegate to Igniter.Mix.Task for standard execution
      super(argv)
    end
  end

  defp parse_args(argv, opts) do
    # Filter out option arguments (starting with --) from argv
    positional_args = Enum.reject(argv, &String.starts_with?(&1, "--"))

    case positional_args do
      [tab_title] ->
        # Derive URL from tab title if not provided
        url = Keyword.get(opts, :url, slugify(tab_title))
        category = Keyword.get(opts, :category, "General")

        {:ok, {tab_title, category, url}}

      [] ->
        {:error, "not enough arguments. Expected: <tab_title>"}

      _ ->
        {:error, "invalid arguments"}
    end
  end

  defp hooks_imports do
    """
    import { Grid } from "./hooks/grid"
    import { ContextMenu } from "./hooks/context_menu"

    let Hooks = window.Hooks || {}
    Hooks.Grid = Grid
    Hooks.ContextMenu = ContextMenu
    window.Hooks = Hooks
    """
  end

  defp grid do
    """
    import { GridStack } from "gridstack"
    import "gridstack/dist/gridstack.min.css"

    export const Grid = {
      mounted() {
        this.grid = GridStack.init({ float: true, cellHeight: 80 }, this.el)

        this.grid.on("change", () => {
          const items = this.grid.engine.nodes.map(n => ({
            id: n.el.dataset.id,
            x: n.x,
            y: n.y,
            w: n.w,
            h: n.h
          }))
          this.pushEvent("save_grid", { items })
        })
      }
    }
    """
  end

  defp context do
    """
    export const ContextMenu = {
      mounted() {
        this.el.addEventListener("contextmenu", (e) => {
          e.preventDefault()
          const id = this.el.dataset.id
          if (confirm("Remove widget?")) {
            this.pushEvent("remove_widget", { id })
          }
        })
      }
    }
    """
  end

  defp create_live_view(igniter, tab_title, url, opts) do
    app_name = IgniterHelpers.get_parent_app_name(igniter)
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)

    web_module_string =
      web_module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")

    page_name = camelize(tab_title)
    description = Keyword.get(opts, :description, "Manage your dashboard content")

    # Read the EEx template file
    template_path =
      case :code.priv_dir(:phoenix_kit) do
        priv_dir when is_list(priv_dir) or is_binary(priv_dir) ->
          Path.join(priv_dir, "templates/user_dashboard_advanced_page.ex")

        _ ->
          "priv/templates/user_dashboard_advanced_page.ex"
      end

    case File.read(template_path) do
      {:ok, template_content} ->
        # Use string replacement to avoid EEx/HEEX conflicts
        rendered_content =
          template_content
          |> String.replace("<%= @web_module_prefix %>", web_module_string)
          |> String.replace("<%= @page_name %>", page_name)
          |> String.replace("<%= @page_title %>", tab_title)
          |> String.replace("<%= @url %>", url)
          |> String.replace("<%= @description %>", description)

        # Build the correct path
        file_path = build_live_view_file_path(app_name, page_name)

        # Use create_new_file to avoid module parsing that might corrupt HEEX syntax
        # Also skip formatting to preserve HEEX template syntax
        Igniter.create_new_file(igniter, file_path, rendered_content, on_format: :skip)

      {:error, reason} ->
        igniter
        |> Igniter.add_issue({:fatal, "Failed to read template file: #{reason}", []})
    end
  end

  defp add_dashboard_tab(igniter, category, tab_title, url, opts) do
    icon = Keyword.get(opts, :icon, "hero-document")
    description = Keyword.get(opts, :description)

    # Validate inputs
    cond do
      !String.starts_with?(url, "/") ->
        Igniter.add_issue(igniter, {:fatal, "URL must start with '/'", []})

      byte_size(tab_title) > 100 ->
        Igniter.add_issue(igniter, {:fatal, "Tab title must be less than 100 characters", []})

      description && byte_size(description) > 200 ->
        Igniter.add_issue(igniter, {:fatal, "Description must be less than 200 characters", []})

      true ->
        igniter
        |> update_dashboard_categories_config(category, tab_title, url, icon, description, opts)
        |> print_success_message(category, tab_title, url)
    end
  end

  defp maybe_add_dashboard_tab(igniter, category, tab_title, url, opts) do
    is_index = Keyword.get(opts, :index, false)

    if is_index do
      # Skip adding to config for index pages
      print_index_success_message(igniter, tab_title, url)
    else
      add_dashboard_tab(igniter, category, tab_title, url, opts)
    end
  end

  defp update_dashboard_categories_config(
         igniter,
         category,
         tab_title,
         url,
         icon,
         description,
         opts
       ) do
    new_tab = %{
      title: tab_title,
      url: url,
      icon: icon,
      description: description
    }

    # Get category icon from options or use default
    category_icon = Keyword.get(opts, :category_icon, "hero-folder")

    # Use IgniterConfig to add the tab to the category (creates category if needed)
    IgniterConfig.add_to_user_dashboard_category(
      igniter,
      category,
      new_tab,
      icon: category_icon
    )
  end

  defp print_success_message(igniter, category, tab_title, url) do
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)

    web_module_string =
      web_module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")

    page_name = camelize(tab_title)
    live_view_module = "#{web_module_string}.PhoenixKit.Dashboard.#{page_name}"

    Igniter.add_notice(igniter, """
    ✅ Dashboard page generated!

    Page: #{live_view_module}
    Tab: #{tab_title}
    Category: #{category}
    URL: #{url}

    📝 Add route:

         scope "/" do
           pipe_through :browser

           live_session :user_dashboard,
             on_mount: [
               {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
               {PhoenixKitWeb.Dashboard.ContextProvider, :default}
             ] do
             live "#{url}", #{live_view_module}, :index
           end
         end

    Then: mix compile --force && restart server
    """)
  end

  defp print_index_success_message(igniter, tab_title, url) do
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)

    web_module_string =
      web_module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")

    page_name = camelize(tab_title)
    live_view_module = "#{web_module_string}.PhoenixKit.Dashboard.#{page_name}"

    Igniter.add_notice(igniter, """
    ✅ Dashboard index page generated!

    Page: #{live_view_module}
    URL: #{url}

    📝 Add route BEFORE phoenix_kit_routes():

         scope "/" do
           pipe_through :browser

           live_session :user_dashboard,
             on_mount: [
               {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
               {PhoenixKitWeb.Dashboard.ContextProvider, :default}
             ] do
             live "#{url}", #{live_view_module}, :index
           end
         end

         import PhoenixKitWeb.Integration
         phoenix_kit_routes()

    Then: mix compile --force && restart server
    """)
  end

  # Builds the full file path for the LiveView
  defp build_live_view_file_path(app_name, page_name) do
    # Use the app_name to get the correct web directory name
    # E.g., phoenix_kit_parent_project -> phoenix_kit_parent_project_web
    web_path =
      app_name
      |> to_string()
      |> Kernel.<>("_web")
      |> String.downcase()

    # Convert page name to lowercase for the file
    file_name = String.downcase(page_name)

    # Return the full file path
    "lib/#{web_path}/phoenix_kit/dashboard/#{file_name}.ex"
  end

  # Convert title to URL-safe slug
  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> then(&"/dashboard/#{&1}")
  end

  defp camelize(string) do
    string
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> Macro.camelize()
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_, default), do: default
end
