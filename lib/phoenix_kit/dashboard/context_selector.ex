defmodule PhoenixKit.Dashboard.ContextSelector do
  @moduledoc """
  Configuration and helpers for the dashboard context selector.

  The context selector allows users to switch between multiple contexts
  (organizations, farms, teams, workspaces, etc.) in the dashboard.
  Users with only one context won't see the selector.

  ## Single Selector Configuration (Legacy)

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

  ## Multiple Selectors Configuration

  Configure multiple independent or dependent selectors:

      config :phoenix_kit, :dashboard_context_selectors, [
        %{
          key: :organization,
          loader: {MyApp.Orgs, :list_for_user},
          display_name: fn org -> org.name end,
          label: "Organization",
          icon: "hero-building-office",
          position: :header,
          sub_position: :start,
          priority: 100
        },
        %{
          key: :project,
          depends_on: :organization,
          loader: {MyApp.Projects, :list_for_org},
          display_name: fn p -> p.name end,
          label: "Project",
          icon: "hero-folder",
          position: :header,
          sub_position: :end,
          priority: 200,
          on_parent_change: :reset
        }
      ]

  ## Configuration Options

  - `:key` - Required for multi-selector. Unique atom identifier (e.g., `:organization`).
    Used in session storage and routes.

  - `:loader` - Required. A `{Module, :function}` tuple that takes a user ID
    and returns a list of context items. Example: `{MyApp.Farms, :list_for_user}`
    For dependent selectors, the function receives `(user_id, parent_context)`.

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

  - `:priority` - Optional. Integer for ordering within same position/sub_position.
    Lower values come first. Defaults to 500.

  - `:depends_on` - Optional. Key of parent selector (for dependent selectors).
    When set, the loader receives `(user_id, parent_context)` instead of just `user_id`.

  - `:on_parent_change` - Optional. What to do when parent selector changes.
    Options: `:reset` (default, select first), `:keep`, `{:redirect, "/path"}`.

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
    Defaults to `"dashboard_context_id"` for single selector, or
    `"dashboard_context_ids"` (map) for multiple selectors.

  - `:tab_loader` - Optional. A `{Module, :function}` tuple that takes a context
    item and returns a list of tab definitions. Enables dynamic tabs that change
    based on the selected context. Example: `{MyApp.Farms, :get_tabs_for_context}`

  ## Usage in LiveViews

  The `ContextProvider` on_mount hook automatically sets these assigns:

  ### Single Selector (Legacy)
  - `@dashboard_contexts` - List of all contexts for the user
  - `@current_context` - The currently selected context item
  - `@show_context_selector` - Boolean, true only if user has 2+ contexts
  - `@dashboard_tabs` - (Optional) List of Tab structs when `tab_loader` is configured

  ### Multiple Selectors
  - `@dashboard_contexts_map` - Map of key => list of contexts
  - `@current_contexts_map` - Map of key => current context item
  - `@show_context_selectors_map` - Map of key => boolean
  - `@context_selector_configs` - List of all ContextSelector configs

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
    :key,
    :loader,
    :display_name,
    :id_field,
    :label,
    :icon,
    :position,
    :sub_position,
    :priority,
    :depends_on,
    :on_parent_change,
    :empty_behavior,
    :session_key,
    :tab_loader,
    :separator,
    enabled: false
  ]

  @type sub_position :: :start | :end | {:priority, integer()}
  @type on_parent_change :: :reset | :keep | {:redirect, String.t()}

  @type t :: %__MODULE__{
          key: atom() | nil,
          loader: {module(), atom()} | nil,
          display_name: (any() -> String.t()) | nil,
          id_field: atom() | (any() -> any()),
          label: String.t(),
          icon: String.t() | nil,
          position: :header | :sidebar,
          sub_position: sub_position() | nil,
          priority: integer(),
          depends_on: atom() | nil,
          on_parent_change: on_parent_change(),
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
  @default_multi_session_key "dashboard_context_ids"
  @default_separator "/"
  @default_id_field :id
  @default_priority 500
  @default_on_parent_change :reset
  @default_key :default

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

      is_atom(config.id_field) and not is_nil(config.id_field) ->
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
    key = get_config_value(config, :key)

    {position, sub_position} = parse_position_and_sub(raw_position, raw_sub_position)

    %__MODULE__{
      enabled: true,
      key: parse_key(key),
      loader: loader,
      display_name: display_name,
      id_field: get_config_value(config, :id_field, @default_id_field),
      label: get_config_value(config, :label, @default_label),
      icon: get_config_value(config, :icon, @default_icon),
      position: position,
      sub_position: sub_position,
      priority: get_config_value(config, :priority, @default_priority),
      depends_on: parse_key(get_config_value(config, :depends_on)),
      on_parent_change: parse_on_parent_change(get_config_value(config, :on_parent_change)),
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

  # Parse key - convert string to atom, keep atoms as-is
  defp parse_key(nil), do: nil
  defp parse_key(key) when is_atom(key), do: key
  defp parse_key(key) when is_binary(key), do: String.to_atom(key)
  defp parse_key(_), do: nil

  # Parse on_parent_change option
  defp parse_on_parent_change(:reset), do: :reset
  defp parse_on_parent_change("reset"), do: :reset
  defp parse_on_parent_change(:keep), do: :keep
  defp parse_on_parent_change("keep"), do: :keep
  defp parse_on_parent_change({:redirect, path}) when is_binary(path), do: {:redirect, path}
  defp parse_on_parent_change(nil), do: @default_on_parent_change
  defp parse_on_parent_change(_), do: @default_on_parent_change

  # ============================================================================
  # Multi-Selector Support
  # ============================================================================

  @doc """
  Checks if multiple selectors are configured.

  Returns `true` if the plural `:dashboard_context_selectors` config is set.
  """
  @spec multi_selector_enabled?() :: boolean()
  def multi_selector_enabled? do
    case Config.get(:dashboard_context_selectors) do
      {:ok, selectors} when is_list(selectors) and length(selectors) > 0 -> true
      _ -> false
    end
  end

  @doc """
  Gets all context selector configurations.

  Returns a list of validated `%ContextSelector{}` structs.
  Handles both the legacy single selector config (`:dashboard_context_selector`)
  and the new multi-selector config (`:dashboard_context_selectors`).

  For legacy single selectors, assigns the default key `:default`.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.get_all_configs()
      [%ContextSelector{key: :organization, ...}, %ContextSelector{key: :project, ...}]

  """
  @spec get_all_configs() :: [t()]
  def get_all_configs do
    case Config.get(:dashboard_context_selectors) do
      {:ok, selectors} when is_list(selectors) and length(selectors) > 0 ->
        selectors
        |> Enum.map(&validate_multi_config/1)
        |> Enum.filter(& &1.enabled)
        |> validate_no_circular_dependencies()

      _ ->
        # Fallback to legacy single selector
        config = get_config()

        if config.enabled do
          # Ensure legacy config has a key
          [%{config | key: config.key || @default_key}]
        else
          []
        end
    end
  end

  @doc """
  Orders selectors by their dependencies using topological sort.

  Independent selectors come first, then dependent selectors in order
  of their dependency chain. Selectors with the same dependency level
  are sorted by priority (lower first).

  ## Examples

      iex> configs = [%{key: :project, depends_on: :org}, %{key: :org}]
      iex> PhoenixKit.Dashboard.ContextSelector.order_by_dependencies(configs)
      [%{key: :org}, %{key: :project, depends_on: :org}]

  """
  @spec order_by_dependencies([t()]) :: [t()]
  def order_by_dependencies(configs) when is_list(configs) do
    # Build dependency graph
    key_to_config = Map.new(configs, fn c -> {c.key, c} end)

    # Topological sort using Kahn's algorithm
    {sorted, _} = topological_sort(configs, key_to_config)

    # Sort by priority within same dependency level
    sorted
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Gets the keys of all selectors that depend on the given key.

  Useful for determining which selectors need to be reset when a parent changes.

  ## Examples

      iex> configs = [%{key: :org}, %{key: :project, depends_on: :org}]
      iex> PhoenixKit.Dashboard.ContextSelector.get_dependent_keys(configs, :org)
      [:project]

  """
  @spec get_dependent_keys([t()], atom()) :: [atom()]
  def get_dependent_keys(configs, parent_key) when is_list(configs) and is_atom(parent_key) do
    configs
    |> Enum.filter(fn c -> c.depends_on == parent_key end)
    |> Enum.map(& &1.key)
  end

  @doc """
  Loads contexts for a specific selector config.

  For independent selectors, calls `loader(user_id)`.
  For dependent selectors, calls `loader(user_id, parent_context)`.

  ## Parameters

  - `config` - The selector configuration
  - `user_id` - The user ID to load contexts for
  - `parent_context` - The parent context (required for dependent selectors)

  """
  @spec load_contexts_for_config(t(), any(), any()) :: list()
  def load_contexts_for_config(config, user_id, parent_context \\ nil)

  def load_contexts_for_config(%__MODULE__{enabled: false}, _user_id, _parent_context), do: []

  def load_contexts_for_config(%__MODULE__{depends_on: nil} = config, user_id, _parent_context) do
    # Independent selector - call with just user_id
    call_loader(config.loader, user_id)
  end

  def load_contexts_for_config(%__MODULE__{depends_on: _} = config, user_id, nil) do
    # Dependent selector but no parent context - return empty
    # This can happen if parent selector has no items
    call_loader_with_parent(config.loader, user_id, nil)
  end

  def load_contexts_for_config(%__MODULE__{depends_on: _} = config, user_id, parent_context) do
    # Dependent selector - call with user_id and parent context
    call_loader_with_parent(config.loader, user_id, parent_context)
  end

  @doc """
  Gets the session key for storing multiple context IDs.

  Returns the configured multi-selector session key.
  """
  @spec multi_session_key() :: String.t()
  def multi_session_key do
    @default_multi_session_key
  end

  @doc """
  Gets the display name for a context item using a specific config.

  ## Examples

      iex> PhoenixKit.Dashboard.ContextSelector.get_display_name_for_config(config, item)
      "My Organization"

  """
  @spec get_display_name_for_config(t(), any()) :: String.t()
  def get_display_name_for_config(_config, nil), do: ""

  def get_display_name_for_config(%__MODULE__{display_name: display_fn}, item)
      when is_function(display_fn, 1) do
    case display_fn.(item) do
      nil -> ""
      result -> result
    end
  rescue
    _ -> to_string(item)
  end

  def get_display_name_for_config(_config, item), do: to_string(item)

  @doc """
  Gets the ID for a context item using a specific config.
  """
  @spec get_id_for_config(t(), any()) :: any()
  def get_id_for_config(_config, nil), do: nil

  def get_id_for_config(%__MODULE__{id_field: id_field}, item) do
    cond do
      is_function(id_field, 1) -> id_field.(item)
      is_atom(id_field) and not is_nil(id_field) -> get_field(item, id_field)
      true -> get_field(item, :id)
    end
  rescue
    _ -> nil
  end

  # Private multi-selector helpers

  defp validate_multi_config(config) when is_map(config) do
    # Multi-selector requires a key
    key = get_config_value(config, :key)

    if key do
      validated = validate_config(config)
      # Ensure key is set even if validate_config didn't set it
      %{validated | key: parse_key(key) || validated.key}
    else
      %__MODULE__{enabled: false}
    end
  end

  defp validate_multi_config(config) when is_list(config) do
    validate_multi_config(Map.new(config))
  end

  defp validate_multi_config(_), do: %__MODULE__{enabled: false}

  defp validate_no_circular_dependencies(configs) do
    keys = MapSet.new(configs, & &1.key)

    has_circular =
      Enum.any?(configs, fn config ->
        if config.depends_on do
          # Check if dependency exists
          if not MapSet.member?(keys, config.depends_on) do
            # Invalid dependency reference - log warning but don't fail
            false
          else
            # Check for circular dependency
            check_circular_dependency(config.key, config.depends_on, configs, MapSet.new())
          end
        else
          false
        end
      end)

    if has_circular do
      # Return only independent selectors on circular dependency
      Enum.filter(configs, fn c -> is_nil(c.depends_on) end)
    else
      configs
    end
  end

  defp check_circular_dependency(original_key, current_key, configs, visited) do
    if MapSet.member?(visited, current_key) do
      # Already visited - this is a cycle
      true
    else
      visited = MapSet.put(visited, current_key)

      # Find the config for current_key
      case Enum.find(configs, fn c -> c.key == current_key end) do
        nil ->
          false

        config ->
          if config.depends_on == original_key do
            # Direct cycle back to original
            true
          else
            if config.depends_on do
              # Continue checking the chain
              check_circular_dependency(original_key, config.depends_on, configs, visited)
            else
              false
            end
          end
      end
    end
  end

  defp topological_sort(configs, key_to_config) do
    # Start with configs that have no dependencies
    {independent, dependent} =
      Enum.split_with(configs, fn c -> is_nil(c.depends_on) end)

    # Process dependent configs in order
    process_dependent(
      independent,
      dependent,
      key_to_config,
      MapSet.new(Enum.map(independent, & &1.key))
    )
  end

  defp process_dependent(sorted, [], _key_to_config, _processed_keys), do: {sorted, []}

  defp process_dependent(sorted, remaining, key_to_config, processed_keys) do
    # Find configs whose dependencies have been processed
    {ready, not_ready} =
      Enum.split_with(remaining, fn c ->
        MapSet.member?(processed_keys, c.depends_on)
      end)

    if ready == [] do
      # No progress - remaining have unresolved dependencies
      {sorted, remaining}
    else
      new_sorted = sorted ++ ready
      new_processed = MapSet.union(processed_keys, MapSet.new(ready, & &1.key))
      process_dependent(new_sorted, not_ready, key_to_config, new_processed)
    end
  end

  defp call_loader_with_parent({module, function}, user_id, parent_context) do
    apply(module, function, [user_id, parent_context])
  rescue
    _ -> []
  end
end
