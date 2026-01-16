defmodule PhoenixKit.Install.EndpointIntegration do
  @moduledoc """
  Endpoint integration for PhoenixKit installation.

  Previously, this module added the `phoenix_kit_socket()` macro to the parent app's
  endpoint. This is no longer needed as the Sync websocket is now handled automatically
  via `phoenix_kit_routes()` in the router.

  This module now removes any existing deprecated `phoenix_kit_socket()` calls from
  endpoints during installation/updates.
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Code.{Common, Function}
  alias Igniter.Project.Application
  alias Igniter.Project.Module, as: IgniterModule
  alias PhoenixKit.Install.IgniterHelpers

  @doc """
  Removes deprecated `phoenix_kit_socket()` and its import from the endpoint.

  The `phoenix_kit_socket()` macro is deprecated. Sync websocket is now handled
  automatically via `phoenix_kit_routes()` in the router.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with deprecated socket code and import removed.
  """
  def add_endpoint_integration(igniter) do
    case find_endpoint(igniter) do
      {igniter, nil} ->
        # No endpoint found, nothing to clean up
        igniter

      {igniter, endpoint_module} ->
        igniter
        |> remove_deprecated_socket(endpoint_module)
        |> remove_deprecated_import(endpoint_module)
    end
  end

  # Find endpoint module
  defp find_endpoint(igniter) do
    case Application.app_name(igniter) do
      :phoenix_kit ->
        {igniter, nil}

      _app_name ->
        endpoint_module = IgniterHelpers.get_parent_app_module_web_endpoint(igniter)

        case IgniterModule.module_exists(igniter, endpoint_module) do
          {true, igniter} ->
            {igniter, endpoint_module}

          {false, igniter} ->
            {igniter, nil}
        end
    end
  end

  # Remove phoenix_kit_socket() if it exists
  defp remove_deprecated_socket(igniter, endpoint_module) do
    IgniterModule.find_and_update_module!(igniter, endpoint_module, fn zipper ->
      case Function.move_to_function_call(zipper, :phoenix_kit_socket, 0) do
        {:ok, socket_zipper} ->
          # Remove the deprecated phoenix_kit_socket() call
          zipper_after_removal = Sourceror.Zipper.remove(socket_zipper)
          {:ok, zipper_after_removal}

        :error ->
          # phoenix_kit_socket() not found, nothing to remove
          {:ok, zipper}
      end
    end)
  end

  # Remove import PhoenixKitWeb.Integration if it exists
  defp remove_deprecated_import(igniter, endpoint_module) do
    IgniterModule.find_and_update_module!(igniter, endpoint_module, fn zipper ->
      case find_integration_import(zipper) do
        {:ok, import_zipper} ->
          # Remove the deprecated import
          zipper_after_removal = Sourceror.Zipper.remove(import_zipper)
          {:ok, zipper_after_removal}

        :error ->
          # Import not found, nothing to remove
          {:ok, zipper}
      end
    end)
  end

  # Find import PhoenixKitWeb.Integration
  defp find_integration_import(zipper) do
    Function.move_to_function_call(zipper, :import, 1, fn call_zipper ->
      case Function.move_to_nth_argument(call_zipper, 0) do
        {:ok, arg_zipper} -> Common.nodes_equal?(arg_zipper, PhoenixKitWeb.Integration)
        :error -> false
      end
    end)
  end
end
