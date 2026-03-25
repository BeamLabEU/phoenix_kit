defmodule Mix.Tasks.PhoenixKit.Gen.User.Dashboard do
  @moduledoc """
  Igniter task that generates a user dashboard page with tab configuration.

  ## Usage

      mix phoenix_kit.gen.user.dashboard "Example"

  ## Arguments

  - `tab_title` - The display title for the tab (e.g., "Example")

  ## Options

  - `--url` - The URL path for the tab (optional, derived from title if not provided)
  - `--category` - The category name (optional, defaults to "Category")
  - `--icon` - Heroicon name for the tab (optional, defaults to "hero-document")
  - `--description` - Brief description for the tab (optional)
  - `--category-icon` - Heroicon name for the category (optional, defaults to "hero-folder"). Only used when creating a new category.

  ## Examples

      # Simple - uses all defaults
      mix phoenix_kit.gen.user.dashboard "Example"

      # With custom category
      mix phoenix_kit.gen.user.dashboard "Example" --category="Category"

      # With custom icon
      mix phoenix_kit.gen.user.dashboard "Example" --icon="hero-chart-bar"

      # Full control
      mix phoenix_kit.gen.user.dashboard "Example" --url="/custom/path" --icon="hero-user"

  """

  @shortdoc "Generates user dashboard page with tab configuration"

  use Igniter.Mix.Task

  alias PhoenixKit.Install.IgniterConfig
  alias PhoenixKit.Install.IgniterHelpers

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :phoenix_kit,
      example: "mix phoenix_kit.gen.user.dashboard \"Example\"",
      schema: [
        url: :string,
        category: :string,
        icon: :string,
        description: :string,
        category_icon: :string
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
        igniter
        |> create_live_view(tab_title, url, opts)
        |> add_dashboard_tab(category, tab_title, url, opts)

      {:error, message} ->
        Igniter.add_notice(igniter, """
        ❌ Error: #{message}

        Usage: mix phoenix_kit.gen.user.dashboard <tab_title>
        Example: mix phoenix_kit.gen.user.dashboard "Example"
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

          mix phoenix_kit.gen.user.dashboard "Example"

      Arguments:

        tab_title  - The display title for the tab

      Options:

        --url           - The URL path for the tab (optional, derived from title)
        --category      - The category name (optional, defaults to "Category")
        --icon          - Heroicon name for the tab (optional, defaults to "hero-document")
        --description   - Brief description for the tab (optional)
        --category-icon - Heroicon name for the category (optional, defaults to "hero-folder")

      Examples:

          # Simple - uses all defaults
          mix phoenix_kit.gen.user.dashboard "Example"

          # With custom category
          mix phoenix_kit.gen.user.dashboard "Example" --category="Category"

          # With custom icon
          mix phoenix_kit.gen.user.dashboard "Example" --icon="hero-chart-bar"

          # Full control
          mix phoenix_kit.gen.user.dashboard "Example" --url="/custom/path" --icon="hero-user"

      Notes:

        - Creates a LiveView file for the dashboard page
        - Adds tab configuration to config/config.exs under :user_dashboard_categories
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
        category = Keyword.get(opts, :category, "Category")

        {:ok, {tab_title, category, url}}

      [] ->
        {:error, "not enough arguments. Expected: <tab_title>"}

      _ ->
        {:error, "invalid arguments"}
    end
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
          Path.join(priv_dir, "templates/user_dashboard_page.ex")

        _ ->
          "priv/templates/user_dashboard_page.ex"
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
    app_name = IgniterHelpers.get_parent_app_name(igniter)
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)

    web_module_string =
      web_module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")

    page_name = camelize(tab_title)
    live_view_module = "#{web_module_string}.PhoenixKit.Dashboard.#{page_name}"

    Igniter.add_notice(igniter, """
    ✅ Dashboard page generated successfully!

    Page Created: #{live_view_module}
    Tab: #{tab_title}
    Category: #{category}
    URL: #{url}

    What was done:
    1. ✓ Created LiveView file at #{build_live_view_file_path(app_name, page_name)}
    2. ✓ Added tab to user dashboard configuration in config/config.exs

    📝 Next Steps:

    1. Add the route to your router (inside a dashboard live_session):

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

    2. Force recompile: mix compile --force

    3. Restart your server to see the new tab in the dashboard sidebar.

    The tab will appear under the "#{category}" category in the user dashboard.
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
end
