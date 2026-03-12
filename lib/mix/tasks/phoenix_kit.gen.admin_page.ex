defmodule Mix.Tasks.PhoenixKit.Gen.AdminPage do
  @moduledoc """
  Igniter task that generates admin pages with automatic route registration.

  ## Usage

      mix phoenix_kit.gen.admin_page MyCategory MyPage "Page Title" --url="/admin/my-page"

  ## Arguments

  - `category` - The category name (becomes parent tab)
  - `page_name` - The name for the page module (PascalCase)
  - `page_title` - The display title for the page

  ## Options

  - `--url` - The URL path for the page (required)
  - `--icon` - Heroicon name for the child tab (optional, defaults to "hero-document-text")
  - `--permission` - Permission key for parent tab (optional, defaults to "dashboard")
  - `--category-icon` - Heroicon name for the parent tab (optional, defaults to "hero-folder"). Only used when creating a new parent.

  ## Parent/Child Tab Behavior

  - First page in a category creates both parent and child tabs
  - Subsequent pages in the same category only add the child tab
  - Parent tab path points to the first child's URL
  - Routes are automatically generated via the `live_view` field

  """

  @shortdoc "Generates admin page with automatic route registration"

  use Igniter.Mix.Task

  alias Igniter.Code.Common
  alias Igniter.Project.Config
  alias PhoenixKit.Install.IgniterHelpers
  alias Sourceror.Zipper

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :phoenix_kit,
      example:
        "mix phoenix_kit.gen.admin_page Analytics Reports \"Reports Dashboard\" --url=\"/admin/analytics/reports\"",
      schema: [
        url: :string,
        icon: :string,
        permission: :string,
        category_icon: :string
      ],
      aliases: [u: :url, i: :icon, p: :permission, ci: :category_icon]
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

  @impl Mix.Task
  def run(argv) do
    # Handle --help flag manually
    if "--help" in argv or "-h" in argv do
      Mix.shell().info("""
      Generates admin page with automatic route registration.

      Usage:

          mix phoenix_kit.gen.admin_page MyCategory MyPage "Page Title" --url="/admin/my-page"

      Arguments:

        category    - The category name (becomes parent tab)
        page_name   - The name for the page module (PascalCase)
        page_title  - The display title for the page

      Options:

        --url           - The URL path for the page (required)
        --icon          - Heroicon name for the child tab (optional, defaults to "hero-document-text")
        --permission    - Permission key for parent tab (optional, defaults to "dashboard")
        --category-icon - Heroicon name for the parent tab (optional, defaults to "hero-folder")

      Example:

          mix phoenix_kit.gen.admin_page Analytics Reports "Reports Dashboard" \\
            --url="/admin/analytics/reports"

      Parent/Child Tab Behavior:

      - First page in a category creates both parent and child tabs
      - Subsequent pages in the same category only add the child tab
      - Parent tab path points to the first child's URL
      - Routes are automatically generated via the live_view field
      - After generation, run: mix compile --force
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

    # Validate inputs
    cond do
      !url ->
        Igniter.add_issue(igniter, {:fatal, "--url option is required", []})

      !String.starts_with?(url, "/") ->
        Igniter.add_issue(igniter, {:fatal, "URL must start with '/'", []})

      byte_size(page_title) > 100 ->
        Igniter.add_issue(igniter, {:fatal, "Page title must be less than 100 characters", []})

      true ->
        igniter
        |> create_template_based_live_view(page_name, page_title, url, category)
        |> add_admin_tabs(category, page_name, page_title, url, icon, opts)
        |> print_success_message(category, page_name, page_title, url)
    end
  end

  defp create_template_based_live_view(igniter, page_name, page_title, url, category) do
    # Create nested module name with category
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))

    app_name = IgniterHelpers.get_parent_app_name(igniter)
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)

    web_module_string =
      web_module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")

    # First, create the page LiveView
    igniter =
      create_page_live_view(
        igniter,
        app_name,
        web_module_string,
        category_module_name,
        page_name,
        page_title,
        url,
        category
      )

    # Then, create the category index LiveView
    category_slug = String.downcase(category |> String.replace(" ", "_"))
    category_url = "/admin/#{category_slug}"

    create_category_index_live_view(
      igniter,
      app_name,
      web_module_string,
      category_module_name,
      category,
      category_url
    )
  end

  defp create_page_live_view(
         igniter,
         app_name,
         web_module_string,
         category_module_name,
         page_name,
         page_title,
         url,
         category
       ) do
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
        _full_module_name = Module.concat([web_module_string, "PhoenixKit", module_name])

        # Use string replacement to avoid EEx/HEEX conflicts
        rendered_content =
          template_content
          |> String.replace("<%= @web_module_prefix %>", web_module_string)
          |> String.replace("<%= @page_name %>", to_string(page_name))
          |> String.replace("<%= @page_title %>", to_string(page_title))
          |> String.replace("<%= @url %>", to_string(url))
          |> String.replace(
            "<%= @category %>",
            category_module_name
          )

        # Build the correct path
        file_path = build_live_view_file_path(app_name, category, page_name)

        # Use create_new_file to avoid module parsing that might corrupt HEEX syntax
        # Also skip formatting to preserve HEEX template syntax
        Igniter.create_new_file(igniter, file_path, rendered_content, on_format: :skip)

      {:error, reason} ->
        igniter
        |> Igniter.add_issue({:fatal, "Failed to read template file: #{reason}", []})
    end
  end

  defp create_category_index_live_view(
         igniter,
         app_name,
         web_module_string,
         category_module_name,
         category,
         category_url
       ) do
    # Read the category index template file
    template_path =
      case :code.priv_dir(:phoenix_kit) do
        priv_dir when is_list(priv_dir) or is_binary(priv_dir) ->
          Path.join(priv_dir, "templates/admin_category_index_page.ex")

        _ ->
          "priv/templates/admin_category_index_page.ex"
      end

    case File.read(template_path) do
      {:ok, template_content} ->
        # Use string replacement to avoid EEx/HEEX conflicts
        rendered_content =
          template_content
          |> String.replace("<%= @web_module_prefix %>", web_module_string)
          |> String.replace("<%= @category %>", category_module_name)
          |> String.replace("<%= @url %>", to_string(category_url))

        # Build the correct path for the index file
        category_slug = String.downcase(category |> String.replace(" ", "_"))

        web_path =
          app_name
          |> to_string()
          |> Kernel.<>("_web")
          |> String.downcase()

        file_path = "lib/#{web_path}/phoenix_kit/live/admin/#{category_slug}/index.ex"

        # Use create_new_file to avoid module parsing that might corrupt HEEX syntax
        Igniter.create_new_file(igniter, file_path, rendered_content, on_format: :skip)

      {:error, reason} ->
        igniter
        |> Igniter.add_issue({:fatal, "Failed to read template file: #{reason}", []})
    end
  end

  defp add_admin_tabs(igniter, category, page_name, page_title, url, icon, opts) do
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)
    category_icon = Keyword.get(opts, :category_icon, "hero-folder")
    permission = Keyword.get(opts, :permission, "dashboard")

    parent_id = derive_parent_tab_id(category)
    child_id = derive_child_tab_id(category, page_name)

    # Build the full LiveView module path for child page
    child_live_view_module = build_live_view_module(web_module, category, page_name)

    # Build the category index LiveView module path for parent
    parent_live_view_module = build_category_index_module(web_module, category)

    # Calculate parent URL from category name
    category_slug = String.downcase(category |> String.replace(" ", "_"))
    parent_url = "/admin/#{category_slug}"

    # Create child tab config
    child_tab = %{
      id: child_id,
      label: page_title,
      icon: icon,
      path: url,
      parent: parent_id,
      priority: calculate_child_priority(category, page_name),
      live_view: {child_live_view_module, :index}
    }

    # Use IgniterConfig to modify the config
    Config.configure(
      igniter,
      "config.exs",
      :phoenix_kit,
      [:admin_dashboard_tabs],
      # Default value if config doesn't exist
      [
        create_parent_tab(
          category,
          parent_id,
          parent_url,
          parent_live_view_module,
          category_icon,
          permission
        ),
        child_tab
      ],
      updater: fn zipper ->
        case extract_current_value(zipper) do
          {:ok, existing_tabs} when is_list(existing_tabs) ->
            # Check if parent tab exists
            parent_exists? = Enum.any?(existing_tabs, fn t -> t[:id] == parent_id end)

            # Validate: Check for duplicate child tab ID
            child_exists? = Enum.any?(existing_tabs, fn t -> t[:id] == child_id end)

            if child_exists? do
              {:error,
               "A page with ID #{inspect(child_id)} already exists in category '#{category}'. " <>
                 "Use a different page name."}
            else
              # Get existing children of this parent (siblings)
              siblings =
                Enum.filter(existing_tabs, fn t ->
                  t[:parent] == parent_id or (t[:id] == parent_id and parent_exists?)
                end)

              # Validate: Check for duplicate URL in the same category
              url_duplicate? =
                Enum.any?(siblings, fn t ->
                  t[:path] == url and t[:id] != child_id
                end)

              if url_duplicate? do
                {:error,
                 "A page with URL '#{url}' already exists in category '#{category}'. " <>
                   "Use a different URL."}
              else
                # Validate: Check for duplicate label in the same category
                label_duplicate? =
                  Enum.any?(siblings, fn t ->
                    t[:label] == page_title and t[:id] != child_id
                  end)

                if label_duplicate? do
                  {:error,
                   "A page with label '#{page_title}' already exists in category '#{category}'. " <>
                     "Use a different page title."}
                else
                  updated_tabs =
                    if parent_exists? do
                      # Parent exists, just add child
                      existing_tabs ++ [child_tab]
                    else
                      # Create parent tab with its own index page
                      parent_tab =
                        create_parent_tab(
                          category,
                          parent_id,
                          parent_url,
                          parent_live_view_module,
                          category_icon,
                          permission
                        )

                      existing_tabs ++ [parent_tab, child_tab]
                    end

                  {:ok, Common.replace_code(zipper, updated_tabs)}
                end
              end
            end

          _ ->
            # Config doesn't exist, create with parent and child
            {:ok,
             Common.replace_code(
               zipper,
               [
                 create_parent_tab(
                   category,
                   parent_id,
                   parent_url,
                   parent_live_view_module,
                   category_icon,
                   permission
                 ),
                 child_tab
               ]
             )}
        end
      end
    )
  end

  defp create_parent_tab(category, parent_id, path, live_view_module, icon, permission) do
    %{
      id: parent_id,
      label: category,
      icon: icon,
      path: path,
      permission: permission,
      priority: calculate_parent_priority(category),
      group: :admin_modules,
      subtab_display: :when_active,
      highlight_with_subtabs: false,
      live_view: {live_view_module, :index}
    }
  end

  defp derive_parent_tab_id(category) do
    category
    |> String.downcase()
    |> String.replace(" ", "_")
    |> then(&:"admin_#{&1}")
  end

  defp derive_child_tab_id(category, page_name) do
    category_slug = category |> String.downcase() |> String.replace(" ", "_")
    page_slug = page_name |> String.downcase() |> String.replace(" ", "_")
    :"admin_#{category_slug}_#{page_slug}"
  end

  defp build_live_view_module(web_module, category, page_name) do
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))
    Module.concat([web_module, PhoenixKit, Live, Admin, category_module_name, page_name])
  end

  defp build_category_index_module(web_module, category) do
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))
    Module.concat([web_module, PhoenixKit, Live, Admin, category_module_name, Index])
  end

  defp calculate_parent_priority(category) do
    # Hash category to get a stable priority between 700-790
    category
    |> String.downcase()
    |> :erlang.phash2()
    |> rem(90)
    |> Kernel.+(700)
  end

  defp calculate_child_priority(category, page_name) do
    # Parent priority + 1-9 based on page name hash
    parent_prio = calculate_parent_priority(category)

    offset =
      page_name
      |> String.downcase()
      |> :erlang.phash2()
      |> rem(9)
      |> Kernel.+(1)

    parent_prio + offset
  end

  # Extracts the current value from a zipper
  defp extract_current_value(zipper) do
    current_node = Zipper.node(zipper)

    case Code.eval_quoted(current_node) do
      {value, _binding} -> {:ok, value}
    end
  rescue
    _ -> :error
  end

  defp print_success_message(igniter, category, page_name, _page_title, url) do
    web_module_name = IgniterHelpers.get_parent_app_module_web_string(igniter)

    # Generate the full module name for display
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))

    page_module_name =
      "#{web_module_name}.PhoenixKit.Live.Admin.#{category_module_name}.#{page_name}"

    index_module_name =
      "#{web_module_name}.PhoenixKit.Live.Admin.#{category_module_name}.Index"

    category_slug = String.downcase(category |> String.replace(" ", "_"))
    category_url = "/admin/#{category_slug}"

    parent_id = derive_parent_tab_id(category)
    child_id = derive_child_tab_id(category, page_name)

    Igniter.add_notice(igniter, """
    ✅ Admin page generated successfully!

    Page Created: #{page_module_name}
    Index Created: #{index_module_name}
    Added to category: #{category}
    Page URL: #{url}
    Category URL: #{category_url}

    What was done:
    1. ✓ Created category index LiveView at #{category_url}
    2. ✓ Created page LiveView at #{url}
    3. ✓ Added parent tab (#{parent_id}) and child tab (#{child_id}) to :admin_dashboard_tabs

    📝 Important: Routes are automatically generated

    Routes are automatically generated via the live_view field in the config.
    No manual router configuration is needed.

    Next steps:
    1. Force recompile: mix compile --force
    2. Restart your server
    3. Visit #{category_url} for the category index
    4. Visit #{url} for the page
    5. Implement the page functionality in the LiveView modules
    6. Customize the page content as needed

    Parent/Child Tab Structure:
    - Parent tab: #{category} (#{parent_id})
    - Child tab: #{page_name} (#{child_id})
    - Parent path points to first child's URL
    - Subsequent pages in the same category will only add child tabs
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
