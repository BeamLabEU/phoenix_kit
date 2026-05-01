defmodule PhoenixKit.Dashboard.Widget do
  @moduledoc """
  Service for discovering and loading widgets from enabled Phoenix Kit modules.

  Each module can export widgets by defining a Widgets submodule with a widgets/0 function.

  Example:
    defmodule PhoenixKit.Modules.AI.Widgets do
      def widgets do
        [
          %Widget{uuid: "1234-5678-9012-3456", value: fn _ -> localized_function() end},
          %Widget{uuid: "2234-5678-9012-3456", value: fn _ -> localized_function_2() end}
        ]
      end
    end
  """

  require Logger

  defstruct uuid: nil,
            name: nil,
            description: nil,
            icon: nil,
            value: nil,
            module: nil,
            enabled: true

  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  def new(list) when is_list(list) do
    new(Map.new(list))
  end

  @doc """
  Load all available widgets from enabled modules.

  Returns a list of %Widget{} structs.
  """
  def load_all_widgets do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.filter(&module_enabled?/1)
    |> Enum.flat_map(&load_module_widgets/1)
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
  Get a single widget by uuid.

  Returns nil if widget not found or parent module is disabled.
  """
  def get_widget(uuid) do
    load_all_widgets()
    |> Enum.find(&(&1.uuid == uuid))
  end

  @doc """
  Get a single widget by module.

  Returns nil if widget not found or parent module is disabled.
  """
  def get_by_module(params) do
    load_all_widgets()
    |> Enum.find(&(&1.module == params))
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

  defp module_enabled?(module_name) do
    try do
      function_exported?(module_name, :enabled?, 0) && module_name.enabled?()
    rescue
      _ -> false
    end
  end

  defp ensure_widget_struct(map) when is_map(map) do
    new(map)
  end

  defp annotate_widget(%PhoenixKit.Dashboard.Widget{} = widget, module_name) do
    %{widget | module: module_name}
  end

  defp find_widgets_module(module_name) do
    widgets_module = Module.concat(module_name, "Widgets")

    case Code.ensure_compiled(widgets_module) do
      {:module, mod} -> mod
      {:error, _} -> nil
    end
  end

end
