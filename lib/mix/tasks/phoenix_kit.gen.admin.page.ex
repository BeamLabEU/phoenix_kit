defmodule Mix.Tasks.PhoenixKit.Gen.Admin.Page do
  @moduledoc """
  Igniter task that generates admin page with automatic route registration.

  ## Usage

      mix phoenix_kit.gen.admin.page "Reports Dashboard"

  ## Arguments

  - `title` - The display title for the page (e.g., "Reports Dashboard")

  ## Options

  - `--url` - The URL path for the page (optional, derived from title if not provided)
  - `--category` - The category name (optional, defaults to "General")
  - `--icon` - Heroicon name for the tab (optional, defaults to "hero-document-text")
  - `--permission` - Permission key for parent tab (optional, defaults to "dashboard")
  - `--category-icon` - Heroicon name for the category (optional, defaults to "hero-folder")

  ## Parent/Child Tab Behavior

  - First page in a category creates both parent and child tabs
  - Subsequent pages in the same category only add the child tab
  - Parent tab path points to the first child's URL
  - Routes are automatically generated via the `live_view` field

  ## Examples

      # Simple - uses all defaults
      mix phoenix_kit.gen.admin.page "Reports Dashboard"

      # With custom category
      mix phoenix_kit.gen.admin.page "User Management" --category="Users"

      # With custom icon
      mix phoenix_kit.gen.admin.page "Analytics" --icon="hero-chart-bar"

      # Full control
      mix phoenix_kit.gen.admin.page "Reports" --url="/admin/analytics/reports" --category="Analytics" --icon="hero-chart-bar"

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
      example: "mix phoenix_kit.gen.admin.page \"Reports Dashboard\"",
      schema: [
        url: :string,
        category: :string,
        icon: :string,
        permission: :string,
        category_icon: :string
      ],
      aliases: [u: :url, c: :category, i: :icon, p: :permission, ci: :category_icon]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options
    argv = igniter.args.argv

    case parse_args(argv, opts) do
      {:ok, {title, category, url}} ->
        igniter
        |> generate_admin_page(title, category, url, opts)

      {:error, message} ->
        Igniter.add_notice(igniter, """
        ❌ Error: #{message}

        Usage: mix phoenix_kit.gen.admin.page <title>
        Example: mix phoenix_kit.gen.admin.page "Reports Dashboard"
        """)
    end
  end

  @impl Mix.Task
  def run(argv) do
    if "--help" in argv or "-h" in argv do
      Mix.shell().info("""
      Generates admin page with automatic route registration.

      Usage:

          mix phoenix_kit.gen.admin.page "Reports Dashboard"

      Arguments:

        title - The display title for the page

      Options:

        --url           - The URL path (optional, derived from title)
        --category      - The category name (optional, defaults to "General")
        --icon          - Heroicon name (optional, defaults to "hero-document-text")
        --permission    - Permission key (optional, defaults to "dashboard")
        --category-icon - Heroicon name for category (optional, defaults to "hero-folder")

      Examples:

          # Simple
          mix phoenix_kit.gen.admin.page "Reports Dashboard"

          # With category
          mix phoenix_kit.gen.admin.page "Users" --category="People"

          # With URL
          mix phoenix_kit.gen.admin.page "Reports" --url="/admin/analytics/reports"

      Notes:
        - Routes are auto-generated via live_view config
        - First page in category creates parent tab
        - Run: mix compile --force && restart server
      """)

      :ok
    else
      super(argv)
    end
  end

  defp parse_args(argv, opts) do
    positional_args = Enum.reject(argv, &String.starts_with?(&1, "--"))

    case positional_args do
      [title] ->
        url = Keyword.get(opts, :url, slugify(title))
        category = Keyword.get(opts, :category, "General")
        {:ok, {title, category, url}}

      [] ->
        {:error, "not enough arguments. Expected: <title>"}

      _ ->
        {:error, "invalid arguments"}
    end
  end

  defp generate_admin_page(igniter, title, category, url, opts) do
    icon = Keyword.get(opts, :icon, "hero-document-text")

    cond do
      !String.starts_with?(url, "/") ->
        Igniter.add_issue(igniter, {:fatal, "URL must start with '/'", []})

      byte_size(title) > 100 ->
        Igniter.add_issue(igniter, {:fatal, "Title must be less than 100 characters", []})

      true ->
        igniter
        |> create_page_live_view(title, category, url)
        |> add_admin_tabs(title, category, url, icon, opts)
        |> print_success_message(title, category, url)
    end
  end

  defp create_page_live_view(igniter, title, category, url) do
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))
    page_name = derive_page_name(title)

    app_name = IgniterHelpers.get_parent_app_name(igniter)
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)

    web_module_string =
      web_module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")

    template_path =
      case :code.priv_dir(:phoenix_kit) do
        priv_dir when is_list(priv_dir) or is_binary(priv_dir) ->
          Path.join(priv_dir, "templates/admin_category_page.ex")

        _ ->
          "priv/templates/admin_category_page.ex"
      end

    case File.read(template_path) do
      {:ok, template_content} ->
        rendered_content =
          template_content
          |> String.replace("<%= @web_module_prefix %>", web_module_string)
          |> String.replace("<%= @page_name %>", to_string(page_name))
          |> String.replace("<%= @page_title %>", to_string(title))
          |> String.replace("<%= @url %>", to_string(url))
          |> String.replace("<%= @category %>", category_module_name)

        file_path = build_live_view_file_path(app_name, category, page_name)

        Igniter.create_new_file(igniter, file_path, rendered_content, on_format: :skip)

      {:error, reason} ->
        igniter
        |> Igniter.add_issue({:fatal, "Failed to read template file: #{reason}", []})
    end
  end

  defp add_admin_tabs(igniter, title, category, url, icon, opts) do
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)
    category_icon = Keyword.get(opts, :category_icon, "hero-folder")
    permission = Keyword.get(opts, :permission, "dashboard")

    parent_id = derive_parent_tab_id(category)
    child_id = derive_child_tab_id(category, derive_page_name(title))

    child_live_view_module = build_live_view_module(web_module, category, derive_page_name(title))

    child_tab = %{
      id: child_id,
      label: title,
      icon: icon,
      path: url,
      parent: parent_id,
      permission: permission,
      priority: calculate_child_priority(category, derive_page_name(title)),
      live_view: {child_live_view_module, :index}
    }

    # Create parent tab (points to first child's URL)
    parent_tab = %{
      id: parent_id,
      label: category,
      icon: category_icon,
      path: url,
      permission: permission,
      priority: calculate_parent_priority(category),
      group: :admin_modules,
      subtab_display: :when_active,
      highlight_with_subtabs: false
    }

    # Use IgniterConfig to modify the config
    Config.configure(
      igniter,
      "config.exs",
      :phoenix_kit,
      [:admin_dashboard_tabs],
      [parent_tab, child_tab],
      updater: fn zipper ->
        case extract_current_value(zipper) do
          {:ok, existing_tabs} when is_list(existing_tabs) ->
            parent_exists? = Enum.any?(existing_tabs, fn t -> t[:id] == parent_id end)
            child_exists? = Enum.any?(existing_tabs, fn t -> t[:id] == child_id end)

            if child_exists? do
              {:error,
               "A page with ID #{inspect(child_id)} already exists in category '#{category}'"}
            else
              siblings =
                Enum.filter(existing_tabs, fn t ->
                  t[:parent] == parent_id or (t[:id] == parent_id and parent_exists?)
                end)

              url_duplicate? =
                Enum.any?(siblings, fn t ->
                  t[:path] == url and t[:id] != child_id
                end)

              if url_duplicate? do
                {:error, "A page with URL '#{url}' already exists in category '#{category}'"}
              else
                updated_tabs =
                  if parent_exists? do
                    existing_tabs ++ [child_tab]
                  else
                    existing_tabs ++ [parent_tab, child_tab]
                  end

                {:ok, Common.replace_code(zipper, updated_tabs)}
              end
            end

          _ ->
            {:ok, Common.replace_code(zipper, [parent_tab, child_tab])}
        end
      end
    )
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

  defp derive_page_name(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, "_")
    |> Macro.camelize()
  end

  defp build_live_view_module(web_module, category, page_name) do
    category_module_name = Macro.camelize(String.replace(category, " ", "_"))
    Module.concat([web_module, PhoenixKit, Admin, category_module_name, page_name])
  end

  defp calculate_parent_priority(category) do
    category
    |> String.downcase()
    |> :erlang.phash2()
    |> rem(90)
    |> Kernel.+(700)
  end

  defp calculate_child_priority(category, page_name) do
    parent_prio = calculate_parent_priority(category)

    offset =
      page_name
      |> :erlang.phash2()
      |> rem(9)
      |> Kernel.+(1)

    parent_prio + offset
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> then(&"/admin/#{&1}")
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

  defp print_success_message(igniter, title, category, url) do
    web_module = IgniterHelpers.get_parent_app_module_web(igniter)

    web_module_string =
      web_module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")

    category_module_name = Macro.camelize(String.replace(category, " ", "_"))
    page_name = derive_page_name(title)

    page_module =
      "#{web_module_string}.PhoenixKit.Admin.#{category_module_name}.#{page_name}"

    Igniter.add_notice(igniter, """
    ✅ Admin page generated!

    Page: #{page_module}
    Category: #{category}
    URL: #{url}

    📝 Routes are auto-generated via live_view config

    Then: mix compile --force && restart server
    """)
  end

  defp build_live_view_file_path(app_name, category, page_name) do
    web_path =
      app_name
      |> to_string()
      |> Kernel.<>("_web")
      |> String.downcase()

    category_path = category |> String.replace(" ", "_") |> String.downcase()
    file_name = String.downcase(page_name)

    "lib/#{web_path}/phoenix_kit/admin/#{category_path}/#{file_name}.ex"
  end
end
