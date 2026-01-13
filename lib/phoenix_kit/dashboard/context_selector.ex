defmodule PhoenixKit.Dashboard.ContextSelector do
  @moduledoc """
  Configuration and helpers for the dashboard context selector.

  The context selector allows users to switch between multiple contexts
  (organizations, farms, teams, workspaces, etc.) in the dashboard.
  Users with only one context won't see the selector.

  ## Configuration

  Configure in your `config/config.exs`:

      config :phoenix_kit, :dashboard_context_selector,
        loader: {MyApp.Farms, :list_for_user},
        display_name: fn farm -> farm.name end,
        id_field: :id,
        label: "Farm",
        icon: "hero-building-office",
        position: :sidebar,
        sub_position: :end,
        empty_behavior: :hide,
        session_key: "dashboard_context_id",
        tab_loader: {MyApp.Farms, :get_tabs_for_context}

  ## Configuration Options

  - `:loader` - Required. A `{Module, :function}` tuple that takes a user ID
    and returns a list of context items. Example: `{MyApp.Farms, :list_for_user}`

  - `:display_name` - Required. A function that takes a context item and returns
    the display string. Example: `fn farm -> farm.name end`

  - `:id_field` - Optional. The field to use as the unique identifier.
    Defaults to `:id`. Can be an atom or a function.

  - `:label` - Optional. The label shown in the UI (e.g., "Farm", "Organization").
    Defaults to `"Context"`.

  - `:icon` - Optional. Heroicon name for the selector. Defaults to `"hero-building-office"`.

  - `:position` - Optional. Which area to show the selector in.
    Options: `:header` (default), `:sidebar`.

  - `:sub_position` - Optional. Where within the area to place the selector.
    For header: `:start` (left, after logo), `:end` (right, before user menu),
      or `{:priority, N}` to sort among other header items.
    For sidebar: `:start` (top), `:end` (pinned to very bottom),
      or `{:priority, N}` to sort among tabs.
    Defaults to `:start`.

  - `:empty_behavior` - Optional. What to do when user has no contexts.
    Options: `:hide` (default), `:show_empty`, `{:redirect, "/path"}`.

  - `:separator` - Optional. Separator shown between logo and selector in header
    (only applies to `position: :header, sub_position: :start`).
    Defaults to `"/"`. Set to `false` or `nil` to disable. Can be any string
    like `"›"`, `"|"`, or `"·"`.

    Note: The separator may appear slightly off-center due to internal padding
    in the selector dropdown. This is a visual quirk and can be adjusted by
    customizing the layout template if precise alignment is required.

  - `:session_key` - Optional. The session key for storing the selected context ID.
    Defaults to `"dashboard_context_id"`.

  - `:tab_loader` - Optional. A `{Module, :function}` tuple that takes a context
    item and returns a list of tab definitions. Enables dynamic tabs that change
    based on the selected context. Example: `{MyApp.Farms, :get_tabs_for_context}`

  ## Usage in LiveViews

  The `ContextProvider` on_mount hook automatically sets these assigns:

  - `@dashboard_contexts` - List of all contexts for the user
  - `@current_context` - The currently selected context item
  - `@show_context_selector` - Boolean, true only if user has 2+ contexts
  - `@dashboard_tabs` - (Optional) List of Tab structs when `tab_loader` is configured

  Access the current context in your LiveView:

      def mount(_params, _session, socket) do
        context = socket.assigns.current_context
        items = MyApp.Items.list_for_context(context.id)
        {:ok, assign(socket, items: items)}
      end

  Or use the helper functions:

      context_id = PhoenixKit.Dashboard.current_context_id(socket)

  """

  alias PhoenixKit.Config

  defstruct [
    :loader,
    :display_name,
    :id_field,
    :label,
    :icon,
    :position,
    :sub_position,
    :empty_behavior,
    :session_key,
    :tab_loader,
    :separator,
    enabled: false
  ]

  @type sub_position :: :start | :end | {:priority, integer()}

  @type t :: %__MODULE__{
          loader: {module(), atom()} | nil,
          display_name: (any() -> String.t()) | nil,
          id_field: atom() | (any() -> any()),
          label: String.t(),
          icon: String.t() | nil,
          position: :header | :sidebar,
          sub_position: sub_position() | nil,
          empty_behavior: :hide | :show_empty | {:redirect, String.t()},
          session_key: String.t(),
          tab_loader: {module(), atom()} | nil,
          separator: String.t() | false | nil,
          enabled: boolean()
        }

  @default_label "Context"
  @default_icon "hero-building-office"
  @default_empty_behavior :hide
  @default_session_key "dashboard_context_id"
  @default_separator "/"
  @default_id_field :id

  @doc """
  Gets the context selector configuration.

  Returns a validated `%ContextSelector{}` struct if configured,
  or a disabled struct if not configured.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.get_config()
      %ContextSelector{enabled: true, loader: {MyApp.Farms, :list_for_user}, ...}

      iex> PhoenixKit.Dashboard.ContextSelector.get_config()
      %ContextSelector{enabled: false}

  """
  @spec get_config() :: t()
  def get_config do
    case Config.get(:dashboard_context_selector) do
      {:ok, config} when is_map(config) or is_list(config) ->
        validate_config(config)

      _ ->
        %__MODULE__{enabled: false}
    end
  end

  @doc """
  Checks if the context selector feature is enabled.

  Returns `true` if the feature is configured with a valid loader.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.enabled?()
      true

  """
  @spec enabled?() :: boolean()
  def enabled? do
    get_config().enabled
  end

  @doc """
  Loads contexts for a user using the configured loader.

  Returns an empty list if the feature is not enabled or the loader fails.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.load_contexts(user_id)
      [%Farm{id: 1, name: "My Farm"}, %Farm{id: 2, name: "Other Farm"}]

  """
  @spec load_contexts(any()) :: list()
  def load_contexts(user_id) do
    config = get_config()

    if config.enabled do
      call_loader(config.loader, user_id)
    else
      []
    end
  end

  @doc """
  Gets the display name for a context item using the configured function.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.get_display_name(farm)
      "My Farm"

  """
  @spec get_display_name(any()) :: String.t()
  def get_display_name(nil), do: ""

  def get_display_name(item) do
    config = get_config()

    if config.enabled and is_function(config.display_name, 1) do
      case config.display_name.(item) do
        nil -> ""
        result -> result
      end
    else
      to_string(item)
    end
  rescue
    _ -> to_string(item)
  end

  @doc """
  Gets the ID for a context item using the configured id_field.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.get_id(%{id: 123})
      123

  """
  @spec get_id(any()) :: any()
  def get_id(nil), do: nil

  def get_id(item) do
    config = get_config()

    cond do
      is_function(config.id_field, 1) ->
        config.id_field.(item)

      is_atom(config.id_field) ->
        get_field(item, config.id_field)

      true ->
        get_field(item, :id)
    end
  rescue
    _ -> nil
  end

  @doc """
  Finds a context by ID from a list of contexts.

  Handles both string and integer ID comparison.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.find_by_id(contexts, "123")
      %Farm{id: 123, ...}

  """
  @spec find_by_id(list(), any()) :: any() | nil
  def find_by_id(contexts, id) when is_list(contexts) do
    Enum.find(contexts, fn item ->
      item_id = get_id(item)
      ids_match?(item_id, id)
    end)
  end

  def find_by_id(_, _), do: nil

  @doc """
  Gets the session key for storing the context ID.
  """
  @spec session_key() :: String.t()
  def session_key do
    get_config().session_key
  end

  @doc """
  Loads tabs for the given context using the configured tab_loader.

  Returns an empty list if no tab_loader is configured or if the loader fails.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.load_tabs(context)
      [%{id: :overview, label: "Overview", ...}, ...]

  """
  @spec load_tabs(any()) :: list()
  def load_tabs(context) do
    config = get_config()

    if config.enabled and config.tab_loader do
      call_tab_loader(config.tab_loader, context)
    else
      []
    end
  end

  defp call_tab_loader({module, function}, context) do
    apply(module, function, [context])
  rescue
    _ -> []
  end

  # Private functions

  defp validate_config(config) when is_list(config) do
    validate_config(Map.new(config))
  end

  defp validate_config(config) when is_map(config) do
    loader = get_config_value(config, :loader)
    display_name = get_config_value(config, :display_name)

    if valid_loader?(loader) and is_function(display_name, 1) do
      build_enabled_config(config, loader, display_name)
    else
      %__MODULE__{enabled: false}
    end
  end

  defp validate_config(_), do: %__MODULE__{enabled: false}

  defp build_enabled_config(config, loader, display_name) do
    tab_loader = get_config_value(config, :tab_loader)
    raw_position = get_config_value(config, :position)
    raw_sub_position = get_config_value(config, :sub_position)

    {position, sub_position} = parse_position_and_sub(raw_position, raw_sub_position)

    %__MODULE__{
      enabled: true,
      loader: loader,
      display_name: display_name,
      id_field: get_config_value(config, :id_field, @default_id_field),
      label: get_config_value(config, :label, @default_label),
      icon: get_config_value(config, :icon, @default_icon),
      position: position,
      sub_position: sub_position,
      empty_behavior: config |> get_config_value(:empty_behavior) |> parse_empty_behavior(),
      session_key: get_config_value(config, :session_key, @default_session_key),
      tab_loader: validate_tab_loader(tab_loader),
      separator: parse_separator(get_config_value(config, :separator, @default_separator))
    }
  end

  defp validate_tab_loader({module, function}) when is_atom(module) and is_atom(function) do
    {module, function}
  end

  defp validate_tab_loader(_), do: nil

  defp get_config_value(config, key, default \\ nil) do
    config[key] || config[to_string(key)] || default
  end

  defp valid_loader?({module, function}) when is_atom(module) and is_atom(function) do
    true
  end

  defp valid_loader?(_), do: false

  defp call_loader({module, function}, user_id) do
    apply(module, function, [user_id])
  rescue
    _ -> []
  end

  # Parse position and sub_position
  # Returns {position, sub_position} tuple with defaults applied
  defp parse_position_and_sub(position, sub_position) do
    case normalize_position(position) do
      {:header, default_sub} ->
        {:header, parse_sub_position(sub_position, default_sub)}

      {:sidebar, default_sub} ->
        {:sidebar, parse_sub_position(sub_position, default_sub)}
    end
  end

  # Normalize position values to {area, default_sub_position}
  defp normalize_position(:header), do: {:header, :start}
  defp normalize_position("header"), do: {:header, :start}
  defp normalize_position(:sidebar), do: {:sidebar, :start}
  defp normalize_position("sidebar"), do: {:sidebar, :start}
  defp normalize_position(_), do: {:header, :start}

  # Parse sub_position, falling back to default if not specified
  defp parse_sub_position(nil, default), do: default
  defp parse_sub_position(:start, _default), do: :start
  defp parse_sub_position("start", _default), do: :start
  defp parse_sub_position(:end, _default), do: :end
  defp parse_sub_position("end", _default), do: :end
  defp parse_sub_position({:priority, n}, _default) when is_integer(n), do: {:priority, n}
  defp parse_sub_position(_, default), do: default

  defp parse_empty_behavior(:hide), do: :hide
  defp parse_empty_behavior(:show_empty), do: :show_empty
  defp parse_empty_behavior({:redirect, path}) when is_binary(path), do: {:redirect, path}
  defp parse_empty_behavior("hide"), do: :hide
  defp parse_empty_behavior("show_empty"), do: :show_empty
  defp parse_empty_behavior(_), do: @default_empty_behavior

  # Parse separator - can be a string, false/nil to disable, or default "/"
  defp parse_separator(false), do: nil
  defp parse_separator(nil), do: nil
  defp parse_separator(""), do: nil
  defp parse_separator(sep) when is_binary(sep), do: sep
  defp parse_separator(_), do: @default_separator

  defp get_field(item, field) when is_map(item), do: Map.get(item, field)
  defp get_field(item, field) when is_atom(field), do: Map.get(item, field)
  defp get_field(_, _), do: nil

  defp ids_match?(id1, id2) when is_integer(id1) and is_binary(id2) do
    id1 == String.to_integer(id2)
  rescue
    _ -> false
  end

  defp ids_match?(id1, id2) when is_binary(id1) and is_integer(id2) do
    String.to_integer(id1) == id2
  rescue
    _ -> false
  end

  defp ids_match?(id1, id2), do: id1 == id2
end
