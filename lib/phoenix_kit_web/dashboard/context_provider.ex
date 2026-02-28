defmodule PhoenixKitWeb.Dashboard.ContextProvider do
  @moduledoc """
  LiveView on_mount hook for loading dashboard contexts.

  This module provides an on_mount hook that loads available contexts for the
  current user and sets socket assigns for the context selector.

  ## Usage

  Add to your live_session:

      live_session :dashboard,
        on_mount: [
          {PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope},
          {PhoenixKitWeb.Dashboard.ContextProvider, :default}
        ]

  ## Assigns Set (Single Selector - Legacy)

  - `@dashboard_contexts` - List of all contexts available to the user
  - `@current_context` - The currently selected context (or nil)
  - `@show_context_selector` - Boolean, true only if user has 2+ contexts
  - `@context_selector_config` - The ContextSelector config struct
  - `@current_contexts_map` - Map with single entry `%{key => current_context}` for badge compatibility
  - `@dashboard_contexts_map` - Map with single entry `%{key => contexts}` for consistency
  - `@show_context_selectors_map` - Map with single entry `%{key => show_selector}`
  - `@dashboard_tabs` - (Optional) List of Tab structs when `tab_loader` is configured

  Note: The `key` used in maps is `config.key` if set, otherwise `:default`.
  This ensures context-aware badges work correctly with legacy single-selector configs.

  ## Assigns Set (Multiple Selectors)

  - `@dashboard_contexts_map` - Map of key => list of contexts
  - `@current_contexts_map` - Map of key => current context item
  - `@show_context_selectors_map` - Map of key => boolean
  - `@context_selector_configs` - List of all ContextSelector configs

  Note: Legacy assigns are also set for backward compatibility when using
  multiple selectors. The first selector's data populates the legacy assigns.

  ## Accessing in LiveViews

      def mount(_params, _session, socket) do
        # Single selector (legacy)
        context = socket.assigns.current_context

        # Multiple selectors
        org = socket.assigns.current_contexts_map[:organization]
        project = socket.assigns.current_contexts_map[:project]

        if context do
          items = MyApp.Items.list_for_context(context.id)
          {:ok, assign(socket, items: items)}
        else
          {:ok, assign(socket, items: [])}
        end
      end

  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Dashboard.ContextSelector
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Users.Auth.Scope

  @doc """
  On mount hook that loads contexts and sets assigns.

  ## Options

  - `:default` - Standard behavior, loads contexts for authenticated user
  - `:optional` - Same as default, but doesn't require authentication

  """
  def on_mount(:default, _params, session, socket) do
    # Check if multi-selector is configured
    if ContextSelector.multi_selector_enabled?() do
      load_multi_selectors(socket, session)
    else
      # Legacy single selector
      config = ContextSelector.get_config()

      if config.enabled do
        load_and_assign_contexts(socket, session, config)
      else
        {:cont, assign_disabled(socket)}
      end
    end
  end

  def on_mount(:optional, params, session, socket) do
    on_mount(:default, params, session, socket)
  end

  # Private functions

  defp load_and_assign_contexts(socket, session, config) do
    user_uuid = get_user_uuid(socket)

    if user_uuid do
      contexts = ContextSelector.load_contexts(user_uuid)
      current_context = resolve_current_context(contexts, session, config)
      show_selector = length(contexts) > 1

      # Load context-specific tabs if tab_loader is configured
      context_tabs = load_context_tabs(current_context, config)

      # Determine the context key for current_contexts_map
      # Use config.key if available, otherwise :default
      context_key = config.key || :default

      socket =
        socket
        |> assign(:dashboard_contexts, contexts)
        |> assign(:current_context, current_context)
        |> assign(:show_context_selector, show_selector)
        |> assign(:context_selector_config, config)
        # Also set current_contexts_map for context-aware badge compatibility
        # This makes legacy single-selector mode consistent with multi-selector mode
        |> assign(:current_contexts_map, build_contexts_map(context_key, current_context))
        |> assign(:dashboard_contexts_map, %{context_key => contexts})
        |> assign(:show_context_selectors_map, %{context_key => show_selector})
        |> maybe_assign_tabs(context_tabs)

      handle_empty_contexts(socket, contexts, config)
    else
      {:cont, assign_disabled(socket)}
    end
  end

  defp build_contexts_map(_key, nil), do: %{}
  defp build_contexts_map(key, context), do: %{key => context}

  defp load_context_tabs(context, config) when config.tab_loader != nil do
    ContextSelector.load_tabs(context)
  end

  defp load_context_tabs(_context, _config), do: nil

  defp maybe_assign_tabs(socket, nil), do: socket
  defp maybe_assign_tabs(socket, []), do: socket

  defp maybe_assign_tabs(socket, tabs) when is_list(tabs) do
    # Convert raw maps to Tab structs if needed
    parsed_tabs =
      Enum.map(tabs, fn
        %Tab{} = tab -> tab
        attrs when is_map(attrs) -> Tab.new!(attrs)
      end)

    assign(socket, :dashboard_tabs, parsed_tabs)
  end

  defp resolve_current_context(contexts, session, config) when is_list(contexts) do
    session_id = session[config.session_key]

    cond do
      # No contexts available
      contexts == [] ->
        nil

      # Try to find by session ID
      session_id != nil ->
        ContextSelector.find_by_id(contexts, session_id) || List.first(contexts)

      # Fall back to first context
      true ->
        List.first(contexts)
    end
  end

  defp handle_empty_contexts(socket, [], %{empty_behavior: {:redirect, path}}) do
    {:halt, Phoenix.LiveView.redirect(socket, to: path)}
  end

  defp handle_empty_contexts(socket, [], %{empty_behavior: :hide}) do
    socket = assign(socket, :show_context_selector, false)
    {:cont, socket}
  end

  defp handle_empty_contexts(socket, [], %{empty_behavior: :show_empty}) do
    {:cont, socket}
  end

  defp handle_empty_contexts(socket, _contexts, _config) do
    {:cont, socket}
  end

  defp assign_disabled(socket) do
    socket
    |> assign(:dashboard_contexts, [])
    |> assign(:current_context, nil)
    |> assign(:show_context_selector, false)
    |> assign(:context_selector_config, %ContextSelector{enabled: false})
    # Multi-selector assigns (also disabled)
    |> assign(:dashboard_contexts_map, %{})
    |> assign(:current_contexts_map, %{})
    |> assign(:show_context_selectors_map, %{})
    |> assign(:context_selector_configs, [])
  end

  # ============================================================================
  # Multi-Selector Support
  # ============================================================================

  defp load_multi_selectors(socket, session) do
    user_uuid = get_user_uuid(socket)

    if user_uuid do
      configs = ContextSelector.get_all_configs()
      ordered_configs = ContextSelector.order_by_dependencies(configs)

      # Get stored context IDs from session
      stored_ids = get_stored_context_ids(session)

      # Load contexts for each selector in dependency order
      {contexts_map, current_map} =
        load_all_contexts(ordered_configs, user_uuid, stored_ids)

      # Build show map
      show_map =
        Map.new(contexts_map, fn {key, contexts} ->
          {key, length(contexts) > 1}
        end)

      # Set legacy assigns using first selector for backward compatibility
      first_config = List.first(ordered_configs)

      socket =
        socket
        # Multi-selector assigns
        |> assign(:dashboard_contexts_map, contexts_map)
        |> assign(:current_contexts_map, current_map)
        |> assign(:show_context_selectors_map, show_map)
        |> assign(:context_selector_configs, ordered_configs)
        # Legacy assigns for backward compatibility
        |> assign_legacy_from_first(first_config, contexts_map, current_map, show_map)

      {:cont, socket}
    else
      {:cont, assign_disabled(socket)}
    end
  end

  defp get_stored_context_ids(session) do
    # Try multi-selector session key first
    case session[ContextSelector.multi_session_key()] do
      ids when is_map(ids) -> ids
      _ -> %{}
    end
  end

  defp load_all_contexts(configs, user_uuid, stored_ids) do
    # Accumulator: {contexts_map, current_map}
    Enum.reduce(configs, {%{}, %{}}, fn config, {ctx_map, cur_map} ->
      # Get parent context if this is a dependent selector
      parent_context =
        if config.depends_on do
          Map.get(cur_map, config.depends_on)
        else
          nil
        end

      # Load contexts for this selector
      contexts = ContextSelector.load_contexts_for_config(config, user_uuid, parent_context)

      # Resolve current context from session or default to first
      current = resolve_context_for_key(contexts, config.key, stored_ids, config)

      {
        Map.put(ctx_map, config.key, contexts),
        Map.put(cur_map, config.key, current)
      }
    end)
  end

  defp resolve_context_for_key(contexts, key, stored_ids, _config) do
    stored_id = Map.get(stored_ids, to_string(key))

    cond do
      contexts == [] ->
        nil

      stored_id != nil ->
        ContextSelector.find_by_id(contexts, stored_id) || List.first(contexts)

      true ->
        List.first(contexts)
    end
  end

  defp assign_legacy_from_first(socket, nil, _contexts_map, _current_map, _show_map) do
    # No configs at all - use disabled defaults
    socket
    |> assign(:dashboard_contexts, [])
    |> assign(:current_context, nil)
    |> assign(:show_context_selector, false)
    |> assign(:context_selector_config, %ContextSelector{enabled: false})
  end

  defp assign_legacy_from_first(socket, first_config, contexts_map, current_map, show_map) do
    key = first_config.key
    contexts = Map.get(contexts_map, key, [])
    current = Map.get(current_map, key)
    show = Map.get(show_map, key, false)

    socket
    |> assign(:dashboard_contexts, contexts)
    |> assign(:current_context, current)
    |> assign(:show_context_selector, show)
    |> assign(:context_selector_config, first_config)
  end

  defp get_user_uuid(socket) do
    cond do
      # Try phoenix_kit_current_scope first
      scope = socket.assigns[:phoenix_kit_current_scope] ->
        user = Scope.user(scope)
        user && user.uuid

      # Try current_user
      user = socket.assigns[:current_user] ->
        user.uuid

      # Try phoenix_kit_current_user
      user = socket.assigns[:phoenix_kit_current_user] ->
        user.uuid

      true ->
        nil
    end
  end
end
