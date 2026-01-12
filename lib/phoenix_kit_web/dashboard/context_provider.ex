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

  ## Assigns Set

  - `@dashboard_contexts` - List of all contexts available to the user
  - `@current_context` - The currently selected context (or nil)
  - `@show_context_selector` - Boolean, true only if user has 2+ contexts
  - `@context_selector_config` - The ContextSelector config struct
  - `@dashboard_tabs` - (Optional) List of Tab structs when `tab_loader` is configured

  ## Accessing in LiveViews

      def mount(_params, _session, socket) do
        # Context is already loaded
        context = socket.assigns.current_context

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
    config = ContextSelector.get_config()

    if config.enabled do
      load_and_assign_contexts(socket, session, config)
    else
      {:cont, assign_disabled(socket)}
    end
  end

  def on_mount(:optional, params, session, socket) do
    on_mount(:default, params, session, socket)
  end

  # Private functions

  defp load_and_assign_contexts(socket, session, config) do
    user_id = get_user_id(socket)

    if user_id do
      contexts = ContextSelector.load_contexts(user_id)
      current_context = resolve_current_context(contexts, session, config)
      show_selector = length(contexts) > 1

      # Load context-specific tabs if tab_loader is configured
      context_tabs = load_context_tabs(current_context, config)

      socket =
        socket
        |> assign(:dashboard_contexts, contexts)
        |> assign(:current_context, current_context)
        |> assign(:show_context_selector, show_selector)
        |> assign(:context_selector_config, config)
        |> maybe_assign_tabs(context_tabs)

      handle_empty_contexts(socket, contexts, config)
    else
      {:cont, assign_disabled(socket)}
    end
  end

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
  end

  defp get_user_id(socket) do
    cond do
      # Try phoenix_kit_current_scope first
      scope = socket.assigns[:phoenix_kit_current_scope] ->
        user = Scope.user(scope)
        user && user.id

      # Try current_user
      user = socket.assigns[:current_user] ->
        user.id

      # Try phoenix_kit_current_user
      user = socket.assigns[:phoenix_kit_current_user] ->
        user.id

      true ->
        nil
    end
  end
end
