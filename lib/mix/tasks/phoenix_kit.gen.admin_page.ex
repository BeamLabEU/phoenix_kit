defmodule Mix.Tasks.PhoenixKit.Gen.AdminPage do
  @moduledoc """
  Igniter task that generates admin pages using template files.

  ## Usage

      mix phoenix_kit.gen.admin_page MyCategory MyPage "Page Title" --url="/admin/my-page"

  ## Arguments

  - `category` - The category name
  - `page_name` - The name for the page module (PascalCase)
  - `page_title` - The display title for the page

  ## Options

  - `--url` - The URL path for the page (required)
  - `--icon` - Heroicon name for the page (optional, defaults to "hero-document-text")
  - `--description` - Brief description for the page (optional)
  - `--category-icon` - Heroicon name for the category (optional, defaults to "hero-folder"). Only used when creating a new category.

  """

  use Igniter.Mix.Task

  require Igniter.Code.Common
  require Igniter.Code.Module
  alias PhoenixKit.Install.IgniterConfig
  alias PhoenixKit.Install.IgniterHelpers

  @shortdoc "Generates admin page using template files"

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :phoenix_kit,
      example:
        "mix phoenix_kit.gen.admin_page Analytics Reports \"Reports Dashboard\" --url=\"/admin/analytics/reports\" --category-icon=\"hero-chart-bar\"",
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
      {:ok, {category, page_name, page_title}} ->
        igniter
        |> generate_admin_page(category, page_name, page_title, opts)

      {:error, message} ->
        Igniter.add_notice(igniter, """
        ❌ Error: #{message}

        Usage: mix phoenix_kit.gen.admin_page <category> <page_name> <page_title> --url=<url>
        Example: mix phoenix_kit.gen.admin_page Analytics Reports "Reports Dashboard" --url="/admin/analytics/reports"
        """)
    end
  end

  defp parse_args(argv, opts) do
    # Filter out option arguments (starting with --) from argv
    positional_args = Enum.reject(argv, &String.starts_with?(&1, "--"))

    case positional_args do
      [category, page_name, page_title] ->
        url = Keyword.get(opts, :url)

        if url do
          {:ok, {category, page_name, page_title}}
        else
          {:error, "--url option is required"}
        end

      args when length(args) < 3 ->
        {:error, "not enough arguments"}

      _ ->
        {:error, "invalid arguments"}
    end
  end

  defp generate_admin_page(igniter, category, page_name, page_title, opts) do
    url = Keyword.get(opts, :url)
    icon = Keyword.get(opts, :icon, "hero-document-text")
    description = Keyword.get(opts, :description)

    # Validate inputs
    cond do
      !url ->
        Igniter.add_issue(igniter, {:fatal, "--url option is required", []})

      !String.starts_with?(url, "/") ->
        Igniter.add_issue(igniter, {:fatal, "URL must start with '/'", []})

      byte_size(page_title) > 100 ->
        Igniter.add_issue(igniter, {:fatal, "Page title must be less than 100 characters", []})

      description && byte_size(description) > 200 ->
        Igniter.add_issue(igniter, {:fatal, "Description must be less than 200 characters", []})

      true ->
        igniter
        |> create_template_based_live_view(page_name, page_title, url, category)
        |> update_admin_categories_config(category, page_title, url, icon, description, opts)
        |> print_success_message(category, page_name, page_title, url)
    end
  end

  defp create_template_based_live_view(igniter, page_name, page_title, url, category) do
    # Create nested module name with category
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))

    app_name = IgniterHelpers.get_parent_app_name(igniter)
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)
    module_name = "Live.Admin.#{category_module_name}.#{page_name}"

    # Read the EEx template file
    template_path =
      case :code.priv_dir(:phoenix_kit) do
        priv_dir when is_list(priv_dir) or is_binary(priv_dir) ->
          Path.join(priv_dir, "templates/admin_category_page.ex")

        _ ->
          "priv/templates/admin_category_page.ex"
      end

    case File.read(template_path) do
      {:ok, template_content} ->
        # Build full module name as a string
        web_module_string =
          web_module
          |> to_string()
          |> String.replace_prefix("Elixir.", "")

        full_module_name = Module.concat([web_module_string, "PhoenixKit", module_name])

        # Use string replacement to avoid EEx/HEEX conflicts
        rendered_content = template_content

        # Extract the module name without Elixir prefix for the template
        module_name_without_elixir =
          full_module_name
          |> to_string()
          |> String.replace_prefix("Elixir.", "")

        rendered_content =
          rendered_content
          |> String.replace("<%= @module_name %>", module_name_without_elixir)
          |> String.replace("<%= @web_module_prefix %>", web_module_string)
          |> String.replace("<%= @page_title %>", to_string(page_title))
          |> String.replace("<%= @url %>", to_string(url))
          |> String.replace("<%= @category %>", to_string(category))

        # Build the correct path
        file_path = build_live_view_file_path(app_name, category, page_name)

        igniter
        |> Igniter.Project.Module.create_module(full_module_name, rendered_content,
          path: file_path
        )

      {:error, reason} ->
        igniter
        |> Igniter.add_issue({:fatal, "Failed to read template file: #{reason}", []})
    end
  end

  defp update_admin_categories_config(igniter, category, page_title, url, icon, description, opts) do
    new_subsection = %{
      title: page_title,
      url: url,
      icon: icon,
      description: description
    }

    # Get category icon from options or use default
    category_icon = Keyword.get(opts, :category_icon, "hero-folder")

    # Use IgniterConfig to add the page to the category (creates category if needed)
    IgniterConfig.add_to_admin_category(
      igniter,
      category,
      new_subsection,
      icon: category_icon
    )
  end

  defp print_success_message(igniter, category, page_name, _page_title, url) do
    web_module_name = IgniterHelpers.get_parent_app_module_web_string(igniter)

    # Generate the full module name for display
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))

    full_module_name =
      "#{web_module_name}.PhoenixKit.Live.Admin.#{category_module_name}.#{page_name}"

    Igniter.add_notice(igniter, """
    ✅ Admin page generated successfully using template!

    Created: #{full_module_name}
    Added to category: #{category}
    URL: #{url}
    Template: admin_category_page.ex

    What was done:
    1. ✓ Created LiveView module with authentication requirements
    2. ✓ Added to admin dashboard configuration

    📝 Important: Router Setup Required

    Please add this route to your admin live_session in your router:

        live "#{url}", #{full_module_name}, :index

    The route should be added inside the live_session with:
    - on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}]
    - Session name: :phoenix_kit_admin or :phoenix_kit_admin_locale

    Example location in your router (lib/your_app_web/router.ex):

        scope "/" do
          pipe_through :browser

          live_session :phoenix_kit_admin_custom_categories,
            on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
            # ... existing admin routes ...
            live "#{url}", #{full_module_name}, :index
          end
        end

    Next steps:
    1. Add the route to your admin live_session (see above)
    2. Restart your server
    3. Implement the page functionality in the LiveView module
    4. Customize the page content as needed
    """)
  end

  # Builds the full file path for the LiveView template
  defp build_live_view_file_path(app_name, category, page_name) do
    # Use the app_name to get the correct web directory name
    # E.g., phoenix_kit_parent_project -> phoenix_kit_parent_project_web
    web_path =
      app_name
      |> to_string()
      |> Kernel.<>("_web")
      |> String.downcase()

    # Convert category to path-safe format
    category_path =
      category
      |> String.replace(" ", "_")
      |> String.downcase()

    # Convert page name to lowercase for the file
    file_name = String.downcase(page_name)

    # Return the full file path
    "lib/#{web_path}/phoenix_kit/live/admin/#{category_path}/#{file_name}.ex"
  end
end
