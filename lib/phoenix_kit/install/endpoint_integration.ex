defmodule PhoenixKit.Install.EndpointIntegration do
  @moduledoc """
  Handles endpoint integration for PhoenixKit installation.

  This module adds PhoenixKit sockets (like DB Sync) to the parent app's endpoint.
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Code.{Common, Function}
  alias Igniter.Project.Application
  alias Igniter.Project.Module, as: IgniterModule
  alias PhoenixKit.Install.IgniterHelpers

  @doc """
  Adds PhoenixKit socket integration to the Phoenix endpoint.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with endpoint socket integration or warnings if endpoint not found.
  """
  def add_endpoint_integration(igniter) do
    case find_endpoint(igniter) do
      {igniter, nil} ->
        warning = create_endpoint_not_found_warning()
        Igniter.add_warning(igniter, warning)

      {igniter, endpoint_module} ->
        add_phoenix_kit_socket_to_endpoint(igniter, endpoint_module)
    end
  end

  # Find endpoint module
  defp find_endpoint(igniter) do
    # Check if this is the PhoenixKit library itself
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

  # Add PhoenixKit socket to endpoint
  defp add_phoenix_kit_socket_to_endpoint(igniter, endpoint_module) do
    {_igniter, _source, zipper} = IgniterModule.find_module!(igniter, endpoint_module)

    # Check if phoenix_kit_socket() already exists
    case Function.move_to_function_call(zipper, :phoenix_kit_socket, 0) do
      {:ok, _} ->
        Igniter.add_notice(
          igniter,
          "PhoenixKit socket already exists in endpoint #{inspect(endpoint_module)}, skipping."
        )

      :error ->
        # Check if the SyncSocket is already defined directly
        case check_sync_socket_exists(zipper) do
          true ->
            Igniter.add_notice(
              igniter,
              "Sync socket already exists in endpoint #{inspect(endpoint_module)}, skipping."
            )

          false ->
            # Add import and socket call
            igniter
            |> add_import_to_endpoint_module(endpoint_module)
            |> add_socket_call_to_endpoint_module(endpoint_module)
        end
    end
  end

  # Check if SyncSocket is already defined in endpoint (checks both old and new paths)
  defp check_sync_socket_exists(zipper) do
    case Function.move_to_function_call(zipper, :socket, 2) do
      {:ok, socket_zipper} ->
        case Function.move_to_nth_argument(socket_zipper, 0) do
          {:ok, arg_zipper} ->
            node = Sourceror.Zipper.node(arg_zipper)
            # Check for both old (/db-sync) and new (/sync) paths
            node == "/sync" or node == "/db-sync" or
              check_sync_socket_exists_next(socket_zipper)

          :error ->
            check_sync_socket_exists_next(socket_zipper)
        end

      :error ->
        false
    end
  end

  # Continue searching for SyncSocket in remaining socket calls
  defp check_sync_socket_exists_next(zipper) do
    case Sourceror.Zipper.next(zipper) do
      nil -> false
      next_zipper -> check_sync_socket_exists(next_zipper)
    end
  end

  # Add import PhoenixKitWeb.Integration to endpoint
  defp add_import_to_endpoint_module(igniter, endpoint_module) do
    IgniterModule.find_and_update_module!(igniter, endpoint_module, fn zipper ->
      if import_already_exists?(zipper) do
        {:ok, zipper}
      else
        add_import_after_use_statement(zipper)
      end
    end)
  end

  # Check if PhoenixKitWeb.Integration import already exists
  defp import_already_exists?(zipper) do
    case Function.move_to_function_call(zipper, :import, 1, &check_import_argument/1) do
      {:ok, _} -> true
      :error -> false
    end
  end

  # Check if import argument matches PhoenixKitWeb.Integration
  defp check_import_argument(call_zipper) do
    case Function.move_to_nth_argument(call_zipper, 0) do
      {:ok, arg_zipper} -> Common.nodes_equal?(arg_zipper, PhoenixKitWeb.Integration)
      :error -> false
    end
  end

  # Add import statement after use statement
  defp add_import_after_use_statement(zipper) do
    case Function.move_to_function_call(zipper, :use, 2) do
      {:ok, use_zipper} ->
        import_code = "import PhoenixKitWeb.Integration"
        {:ok, Common.add_code(use_zipper, import_code, placement: :after)}

      :error ->
        {:warning,
         "Could not add import PhoenixKitWeb.Integration to endpoint. Please add manually."}
    end
  end

  # Add phoenix_kit_socket() call after the /live socket
  defp add_socket_call_to_endpoint_module(igniter, endpoint_module) do
    IgniterModule.find_and_update_module!(igniter, endpoint_module, fn zipper ->
      # Try to find the /live socket to add after it
      case find_live_socket(zipper) do
        {:ok, live_socket_zipper} ->
          add_socket_code(live_socket_zipper)

        :error ->
          # Fallback: try import statement or use statement
          add_socket_code_fallback(zipper)
      end
    end)
  end

  defp add_socket_code(target_zipper) do
    socket_code = """
    # PhoenixKit sockets (for DB Sync, etc.)
    phoenix_kit_socket()
    """

    {:ok, Common.add_code(target_zipper, socket_code, placement: :after)}
  end

  defp add_socket_code_fallback(zipper) do
    # Try: add after the import statement we just added
    case find_phoenix_kit_import(zipper) do
      {:ok, import_zipper} ->
        add_socket_code(import_zipper)

      :error ->
        # Last resort: add after use statement
        add_socket_code_after_use(zipper)
    end
  end

  defp add_socket_code_after_use(zipper) do
    case Function.move_to_function_call(zipper, :use, 2) do
      {:ok, use_zipper} ->
        add_socket_code(use_zipper)

      :error ->
        {:warning, "Could not add phoenix_kit_socket() to endpoint. Please add manually."}
    end
  end

  # Find the PhoenixKitWeb.Integration import statement
  defp find_phoenix_kit_import(zipper) do
    Function.move_to_function_call(zipper, :import, 1, &check_import_argument/1)
  end

  # Find the /live socket definition
  defp find_live_socket(zipper) do
    case Function.move_to_function_call(zipper, :socket, 2) do
      {:ok, socket_zipper} ->
        case Function.move_to_nth_argument(socket_zipper, 0) do
          {:ok, arg_zipper} ->
            node = Sourceror.Zipper.node(arg_zipper)

            if node == "/live" do
              {:ok, socket_zipper}
            else
              find_live_socket_next(socket_zipper)
            end

          :error ->
            find_live_socket_next(socket_zipper)
        end

      :error ->
        :error
    end
  end

  # Continue searching for /live socket
  defp find_live_socket_next(zipper) do
    case Sourceror.Zipper.next(zipper) do
      nil -> :error
      next_zipper -> find_live_socket(next_zipper)
    end
  end

  # Create warning when endpoint is not found
  defp create_endpoint_not_found_warning do
    """
    🚨 Endpoint Detection Failed

    PhoenixKit could not automatically detect your Phoenix endpoint.

    ℹ️  NOTE: As of the latest version, the phoenix_kit_socket() macro is
    deprecated and no longer required. The Sync WebSocket is now handled
    automatically via the router when you use phoenix_kit_routes().

    If you have an existing installation with phoenix_kit_socket() in your
    endpoint.ex, you can safely remove it.

    📖 Common endpoint locations:
       • lib/my_app_web/endpoint.ex
       • apps/my_app_web/lib/my_app_web/endpoint.ex (umbrella apps)
    """
  end
end
