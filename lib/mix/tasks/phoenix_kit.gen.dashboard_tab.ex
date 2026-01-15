defmodule Mix.Tasks.PhoenixKit.Gen.DashboardTab do
  @moduledoc """
  Igniter task that adds a tab to the user dashboard configuration.

  ## Usage

      mix phoenix_kit.gen.dashboard_tab "Category Name" "Tab Title" --url="/dashboard/path"

  ## Arguments

  - `category` - The category name (e.g., "Farm Management")
  - `tab_title` - The display title for the tab

  ## Options

  - `--url` - The URL path for the tab (required)
  - `--icon` - Heroicon name for the tab (optional, defaults to "hero-document-text")
  - `--description` - Brief description for the tab (optional)
  - `--category-icon` - Heroicon name for the category (optional, defaults to "hero-folder"). Only used when creating a new category.

  ## Examples

      # Add a History tab to Farm Management category
      mix phoenix_kit.gen.dashboard_tab "Farm Management" "History" \\
        --url="/dashboard/history" \\
        --icon="hero-chart-bar" \\
        --category-icon="hero-cube"

      # Add a Settings tab to Account category
      mix phoenix_kit.gen.dashboard_tab "Account" "Settings" \\
        --url="/dashboard/settings" \\
        --icon="hero-cog-6-tooth" \\
        --description="Manage your account settings"

  """

  @shortdoc "Adds a tab to the user dashboard configuration"

  use Igniter.Mix.Task

  alias PhoenixKit.Install.IgniterConfig

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :phoenix_kit,
      example:
        "mix phoenix_kit.gen.dashboard_tab \"Farm Management\" \"History\" --url=\"/dashboard/history\" --icon=\"hero-chart-bar\"",
      schema: [
        url: :string,
        icon: :string,
        description: :string,
        category_icon: :string
      ],
      aliases: [u: :url, i: :icon, d: :description, ci: :category_icon]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    # Get options and arguments from igniter context
    opts = igniter.args.options
    argv = igniter.args.argv

    case parse_args(argv, opts) do
      {:ok, {category, tab_title}} ->
        igniter
        |> add_dashboard_tab(category, tab_title, opts)

      {:error, message} ->
        Igniter.add_notice(igniter, """
        ❌ Error: #{message}

        Usage: mix phoenix_kit.gen.dashboard_tab <category> <tab_title> --url=<url>
        Example: mix phoenix_kit.gen.dashboard_tab "Farm Management" "History" --url="/dashboard/history"
        """)
    end
  end

  @impl Mix.Task
  def run(argv) do
    # Handle --help flag manually
    if "--help" in argv or "-h" in argv do
      Mix.shell().info("""
      Adds a tab to the user dashboard configuration.

      Usage:

          mix phoenix_kit.gen.dashboard_tab "Category Name" "Tab Title" --url="/dashboard/path"

      Arguments:

        category   - The category name (e.g., "Farm Management")
        tab_title  - The display title for the tab

      Options:

        --url           - The URL path for the tab (required)
        --icon          - Heroicon name for the tab (optional, defaults to "hero-document-text")
        --description   - Brief description for the tab (optional)
        --category-icon - Heroicon name for the category (optional, defaults to "hero-folder")

      Examples:

          # Add a History tab to Farm Management category
          mix phoenix_kit.gen.dashboard_tab "Farm Management" "History" \\
            --url="/dashboard/history" \\
            --icon="hero-chart-bar" \\
            --category-icon="hero-cube"

          # Add a Settings tab to Account category
          mix phoenix_kit.gen.dashboard_tab "Account" "Settings" \\
            --url="/dashboard/settings" \\
            --icon="hero-cog-6-tooth" \\
            --description="Manage your account settings"

      Notes:

        - If the category doesn't exist, it will be created automatically
        - Tabs are added to config/config.exs under :user_dashboard_categories
        - The dashboard will automatically pick up the new tab after server restart
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
      [category, tab_title] ->
        url = Keyword.get(opts, :url)

        if url do
          {:ok, {category, tab_title}}
        else
          {:error, "--url option is required"}
        end

      args when length(args) < 2 ->
        {:error, "not enough arguments. Expected: <category> <tab_title>"}

      _ ->
        {:error, "invalid arguments"}
    end
  end

  defp add_dashboard_tab(igniter, category, tab_title, opts) do
    url = Keyword.get(opts, :url)
    icon = Keyword.get(opts, :icon, "hero-document-text")
    description = Keyword.get(opts, :description)

    # Validate inputs
    cond do
      !url ->
        Igniter.add_issue(igniter, {:fatal, "--url option is required", []})

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
    Igniter.add_notice(igniter, """
    ✅ Dashboard tab added successfully!

    Tab: #{tab_title}
    Category: #{category}
    URL: #{url}

    What was done:
    1. ✓ Added tab to user dashboard configuration in config/config.exs

    📝 Next Steps:

    1. Create the LiveView for this tab (if not already created):

        defmodule YourAppWeb.DashboardLive.#{camelize(tab_title)} do
          use YourAppWeb, :live_view

          def mount(_params, _session, socket) do
            {:ok, socket}
          end

          def render(assigns) do
            ~H\"\"\"
            <div>
              <h1>#{tab_title}</h1>
              <!-- Your content here -->
            </div>
            \"\"\"
          end
        end

    2. Add the route to your router (inside a dashboard live_session):

        live "#{url}", YourAppWeb.DashboardLive.#{camelize(tab_title)}, :index

    3. Restart your server to see the new tab in the dashboard sidebar.

    The tab will appear under the "#{category}" category in the user dashboard.
    """)
  end

  defp camelize(string) do
    string
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> Macro.camelize()
  end
end
