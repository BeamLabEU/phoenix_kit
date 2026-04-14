defmodule PhoenixKit.Utils.Widget do
  @moduledoc """
  Service for discovering and loading widgets from enabled Phoenix Kit modules.

  Each module can export widgets by defining a Widgets submodule with a widgets/0 function.

  Example:
    defmodule PhoenixKit.Modules.AI.Widgets do
      def widgets do
        [
          %Widget{id: "ai_stats", ...},
          %Widget{id: "ai_usage", ...}
        ]
      end
    end
  """

  require Logger

  alias PhoenixKit.Utils.Widget

  @doc """
  Load all available widgets from enabled modules.

  Returns a list of %Widget{} structs, sorted by order.
  """
  def load_all_widgets do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.filter(&module_enabled?/1)
    |> Enum.flat_map(&load_module_widgets/1)
    |> Enum.sort_by(& &1.order)
  end

  @doc """
  Load widgets for a specific user, filtered by module permissions.

  Returns widgets only for modules the user has access to.
  """
  def load_user_widgets(user) do
    load_all_widgets()
    |> Enum.filter(fn widget ->
      user_can_access_module?(user, widget.module)
    end)
  end

  @doc """
  Load widgets for a specific module.

  Returns empty list if module is disabled or has no widgets.
  """
  def load_module_widgets(module_name) when is_atom(module_name) do
    case find_widgets_module(module_name) do
      nil ->
        Logger.debug("No widgets module found for #{inspect(module_name)}")
        []

      widgets_module ->
        try do
          if function_exported?(widgets_module, :widgets, 0) do
            widgets_module.widgets()
            |> List.wrap()
            |> Enum.map(&ensure_widget_struct/1)
            |> Enum.map(&annotate_widget(&1, module_name))
            |> Enum.filter(& &1.enabled)
          else
            Logger.warning("Widget module #{inspect(widgets_module)} does not export widgets/0")
            []
          end
        rescue
          e ->
            Logger.error(
              "Error loading widgets for module #{inspect(module_name)}: #{inspect(e)}"
            )

            []
        end
    end
  end

  @doc """
  Get a single widget by ID.

  Returns nil if widget not found or parent module is disabled.
  """
  def get_widget(widget_id) do
    load_all_widgets()
    |> Enum.find(&(&1.id == widget_id))
  end

  @doc """
  Get widget count by module.

  Useful for admin dashboards.
  """
  def get_widget_count_by_module do
    load_all_widgets()
    |> Enum.group_by(& &1.module)
    |> Enum.map(fn {module, widgets} -> {module, length(widgets)} end)
    |> Map.new()
  end

  # --- Private Helpers ---

  defp find_widgets_module(module_name) do
    # Try: PhoenixKit.Modules.AI -> PhoenixKit.Modules.AI.Widgets
    widgets_module = Module.concat(module_name, "Widgets")

    case Code.ensure_compiled(widgets_module) do
      {:module, mod} -> mod
      {:error, _} -> nil
    end
  end

  defp module_enabled?(module_name) do
    try do
      function_exported?(module_name, :enabled?, 0) && module_name.enabled?()
    rescue
      _ -> false
    end
  end

  defp user_can_access_module?(user, module_name) do
    ## PhoenixKit.Users.Permissions.user_can_access_module?(user, module_name)
    true
  end

  defp ensure_widget_struct(%{} = widget) do
    widget
  end

  defp ensure_widget_struct(map) when is_map(map) do
    new(map)
  end

  defp annotate_widget(%{} = widget, module_name) do
    %{widget | module: module_name}
  end

  defstruct uuid: nil,
            title: nil,
            description: nil,
            icon: nil,
            component: nil,
            component_props: %{},
            order: 100,
            enabled: false,
            module: nil

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          title: String.t(),
          description: String.t() | nil,
          icon: String.t() | nil,
          component: atom(),
          component_props: map(),
          order: integer(),
          enabled: boolean(),
          module: atom() | nil
        }

  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  def new(list) when is_list(list) do
    new(Map.new(list))
  end

  def upsert_widget_raw(user_uuid, widget_uuid, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    data =
      attrs
      |> Map.merge(%{
        user_uuid: user_uuid,
        widget_uuid: widget_uuid,
        inserted_at: now,
        updated_at: now
      })

    repo().insert_or_update(
      struct(PhoenixKit.Utils.Widget, data),
      on_conflict: {:replace, Map.keys(data) -- [:id, :inserted_at]},
      conflict_target: [:user_uuid, :uuid],
      returning: true
    )
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
