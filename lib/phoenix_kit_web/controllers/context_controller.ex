defmodule PhoenixKitWeb.ContextController do
  @moduledoc """
  Controller for handling dashboard context switching.

  Provides POST endpoints that set the selected context ID(s) in the session
  and redirect back to the referring page.

  ## Routes

  - `POST /context/:id` - Legacy single selector (backward compatible)
  - `POST /context/:key/:id` - Multi-selector with keyed context

  ## Multi-Selector Behavior

  When using multiple selectors, changing a parent selector will automatically
  reset dependent selectors based on their `on_parent_change` configuration:

  - `:reset` (default) - Clears the dependent selector's stored ID
  - `:keep` - Preserves the dependent selector's stored ID
  - `{:redirect, path}` - Redirects to specified path instead of referer
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Dashboard.ContextSelector

  @doc """
  Sets the current context for a specific selector key.

  This is the multi-selector route that handles `POST /context/:key/:id`.

  ## Parameters

  - `key` - The selector key (e.g., "organization", "project")
  - `id` - The context ID to set as current

  ## Response

  Redirects to the referer URL, or `/dashboard` if no referer is present.
  Dependent selectors may be reset based on their `on_parent_change` setting.
  """
  def set(conn, %{"key" => key, "id" => id}) do
    key_atom = String.to_existing_atom(key)
    configs = ContextSelector.get_all_configs()

    # Find the config for this key
    config = Enum.find(configs, fn c -> c.key == key_atom end)

    if config && config.enabled do
      redirect_path = get_redirect_path(conn)

      # Get current stored IDs
      current_ids = get_session(conn, ContextSelector.multi_session_key()) || %{}

      # Update with new ID
      updated_ids = Map.put(current_ids, key, id)

      # Reset dependent selectors
      updated_ids = reset_dependent_selectors(updated_ids, key_atom, configs)

      conn
      |> put_session(ContextSelector.multi_session_key(), updated_ids)
      |> redirect(to: redirect_path)
    else
      # Try legacy handling if key not found in multi-selector
      set_legacy(conn, %{"id" => id})
    end
  rescue
    ArgumentError ->
      # Key doesn't exist as atom - try legacy route
      set_legacy(conn, %{"id" => id})
  end

  # Legacy single selector route for backward compatibility.
  # Handles `POST /context/:id` when multi-selector is not configured.
  def set(conn, %{"id" => id}) do
    set_legacy(conn, %{"id" => id})
  end

  def set(conn, _params) do
    conn
    |> put_flash(:error, "Invalid context")
    |> redirect(to: get_redirect_path(conn))
  end

  @doc """
  Sets context using the legacy single-selector session key.
  """
  def set_legacy(conn, %{"id" => id}) do
    config = ContextSelector.get_config()

    if config.enabled do
      session_key = config.session_key
      redirect_path = get_redirect_path(conn)

      conn
      |> put_session(session_key, id)
      |> redirect(to: redirect_path)
    else
      conn
      |> put_flash(:error, "Context switching is not enabled")
      |> redirect(to: "/dashboard")
    end
  end

  # Private functions

  defp get_redirect_path(conn) do
    referer = get_req_header(conn, "referer") |> List.first()

    if is_nil(referer) or referer == "" do
      default_redirect()
    else
      parse_referer(referer, conn)
    end
  end

  defp parse_referer(referer, conn) do
    case URI.parse(referer) do
      %URI{host: host, path: path} when is_binary(path) ->
        # Only allow same-host redirects for security
        if same_host?(host, conn) do
          path
        else
          default_redirect()
        end

      _ ->
        default_redirect()
    end
  end

  defp same_host?(nil, _conn), do: true
  defp same_host?("", _conn), do: true

  defp same_host?(referer_host, conn) do
    request_host = conn.host
    referer_host == request_host
  end

  defp default_redirect do
    url_prefix = PhoenixKit.Config.get_url_prefix()
    "#{url_prefix}/dashboard"
  end

  defp reset_dependent_selectors(ids, changed_key, configs) do
    # Find all selectors that depend on the changed key
    dependent_keys = ContextSelector.get_dependent_keys(configs, changed_key)

    # Reset each dependent selector based on its on_parent_change setting
    Enum.reduce(dependent_keys, ids, fn dep_key, acc_ids ->
      dep_config = Enum.find(configs, fn c -> c.key == dep_key end)

      case dep_config && dep_config.on_parent_change do
        :reset ->
          # Remove the stored ID so it defaults to first
          Map.delete(acc_ids, to_string(dep_key))

        :keep ->
          # Keep the current ID
          acc_ids

        {:redirect, _path} ->
          # For redirect, still reset the ID (redirect is handled elsewhere)
          Map.delete(acc_ids, to_string(dep_key))

        _ ->
          # Default to reset
          Map.delete(acc_ids, to_string(dep_key))
      end
    end)
  end
end
