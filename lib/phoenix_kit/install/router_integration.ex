defmodule PhoenixKit.Install.RouterIntegration do
  @moduledoc """
  Handles router integration for PhoenixKit installation.

  This module provides functionality to:
  - Find and validate Phoenix router modules
  - Add PhoenixKit imports and routes to routers
  - Generate demo page routes
  - Handle router integration warnings and notices
  """
  use PhoenixKit.Install.IgniterCompat

  alias Igniter.Code.{Common, Function}
  alias Igniter.Libs.Phoenix, as: IgniterPhoenix
  alias Igniter.Project.Application
  alias Igniter.Project.Module, as: IgniterModule
  alias PhoenixKit.Install.IgniterHelpers

  @doc """
  Adds PhoenixKit integration to the Phoenix router.

  ## Parameters
  - `igniter` - The igniter context
  - `custom_router_path` - Custom path to router file (optional)

  ## Returns
  Updated igniter with router integration or warnings if router not found.
  """
  def add_router_integration(igniter, custom_router_path) do
    case find_router(igniter, custom_router_path) do
      {igniter, nil} ->
        warning = create_router_not_found_warning(custom_router_path)
        Igniter.add_warning(igniter, warning)

      {igniter, router_module} ->
        add_phoenix_kit_routes_to_router(igniter, router_module)
    end
  end

  @doc """
  Verifies and fixes the position of phoenix_kit_routes() in the router.

  During updates, checks if phoenix_kit_routes() is positioned AFTER catch-all routes
  (/:param or /*path patterns) and automatically moves it BEFORE them.

  ## Parameters
  - `igniter` - The igniter context
  - `custom_router_path` - Custom path to router file (optional)

  ## Returns
  Updated igniter with router position fixed or unchanged if already correct.
  """
  def verify_and_fix_router_position(igniter, custom_router_path) do
    case find_router(igniter, custom_router_path) do
      {igniter, nil} ->
        # No router found, nothing to fix
        igniter

      {igniter, router_module} ->
        fix_phoenix_kit_routes_position(igniter, router_module)
    end
  end

  # Fix phoenix_kit_routes() position if it's after catch-all routes
  defp fix_phoenix_kit_routes_position(igniter, router_module) do
    {_igniter, source, zipper} = IgniterModule.find_module!(igniter, router_module)

    # First check if phoenix_kit_routes() exists in router
    case Function.move_to_function_call(zipper, :phoenix_kit_routes, 0) do
      {:ok, _pk_zipper} ->
        # Routes exist, check if they need to be moved
        router_code = Rewrite.Source.get(source, :content)

        if needs_position_fix?(router_code) do
          move_routes_before_catch_all(igniter, router_module)
        else
          # Position is already correct
          igniter
        end

      :error ->
        # phoenix_kit_routes() not found, nothing to fix
        igniter
    end
  end

  # Check if phoenix_kit_routes() comes AFTER catch-all routes (needs fixing)
  defp needs_position_fix?(router_code) when is_binary(router_code) do
    # Find positions of phoenix_kit_routes() and catch-all patterns
    pk_routes_match = Regex.run(~r/phoenix_kit_routes\(\)/, router_code, return: :index)
    catch_all_match = Regex.run(~r/(live|get)\s+["\']\/:[a-z_]+/, router_code, return: :index)

    case {pk_routes_match, catch_all_match} do
      {[{pk_pos, _}], [{catch_all_pos, _}]} ->
        # If phoenix_kit_routes() position is AFTER catch-all, needs fix
        pk_pos > catch_all_pos

      _ ->
        # No catch-all routes or no phoenix_kit_routes(), no fix needed
        false
    end
  end

  # Move phoenix_kit_routes() before catch-all routes
  defp move_routes_before_catch_all(igniter, router_module) do
    Mix.shell().info(
      "🔄 Moving phoenix_kit_routes() before catch-all routes for proper route matching..."
    )

    IgniterModule.find_and_update_module!(igniter, router_module, fn zipper ->
      # Step 1: Find and remove existing phoenix_kit_routes() call
      case Function.move_to_function_call(zipper, :phoenix_kit_routes, 0) do
        {:ok, pk_zipper} ->
          # Remove the phoenix_kit_routes() node
          zipper_after_removal = Sourceror.Zipper.remove(pk_zipper)

          # Step 2: Find catch-all route and insert phoenix_kit_routes() before it
          case find_catch_all_insertion_point(zipper_after_removal) do
            {:ok, insertion_zipper} ->
              {:ok, Common.add_code(insertion_zipper, "phoenix_kit_routes()", placement: :before)}

            :error ->
              # Fallback: re-add at the end (shouldn't happen, but safety)
              {:ok,
               Common.add_code(zipper_after_removal, "phoenix_kit_routes()", placement: :after)}
          end

        :error ->
          # phoenix_kit_routes() not found, nothing to do
          {:ok, zipper}
      end
    end)
  end

  # Find router using IgniterPhoenix
  defp find_router(igniter, nil) do
    # Check if this is the PhoenixKit library itself (not a real Phoenix app)
    case Application.app_name(igniter) do
      :phoenix_kit ->
        # This is the PhoenixKit library itself, skip router integration
        {igniter, nil}

      _app_name ->
        router_module = IgniterHelpers.get_parent_app_module_web_router(igniter)

        case IgniterModule.module_exists(igniter, router_module) do
          {true, igniter} ->
            {igniter, router_module}

          {false, igniter} ->
            # Fallback to Igniter's router selection
            IgniterPhoenix.select_router(
              igniter,
              "Which router should be used for PhoenixKit routes?"
            )
        end
    end
  end

  defp find_router(igniter, custom_path) do
    if File.exists?(custom_path) do
      handle_existing_router_file(igniter, custom_path)
    else
      Igniter.add_warning(igniter, "Router file not found at #{custom_path}")
      {igniter, nil}
    end
  end

  # Handle extraction and verification of router module from existing file
  defp handle_existing_router_file(igniter, custom_path) do
    case extract_module_from_router_file(custom_path) do
      {:ok, module} ->
        verify_router_module_exists(igniter, module, custom_path)

      :error ->
        Igniter.add_warning(igniter, "Could not determine module name from #{custom_path}")
        {igniter, nil}
    end
  end

  # Verify the extracted router module exists in the project
  defp verify_router_module_exists(igniter, module, custom_path) do
    case IgniterModule.module_exists(igniter, module) do
      {true, igniter} ->
        {igniter, module}

      {false, igniter} ->
        Igniter.add_warning(
          igniter,
          "Module #{inspect(module)} extracted from #{custom_path} does not exist"
        )

        {igniter, nil}
    end
  end

  # Extract module name from router file content
  defp extract_module_from_router_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, content) do
          [_, module_name] -> {:ok, Module.concat([module_name])}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # Add PhoenixKit routes to router using proper Igniter API
  defp add_phoenix_kit_routes_to_router(igniter, router_module) do
    # Check if PhoenixKit routes already exist
    {_igniter, _source, zipper} = IgniterModule.find_module!(igniter, router_module)

    case Function.move_to_function_call(zipper, :phoenix_kit_routes, 0) do
      {:ok, _} ->
        # Routes already exist, add notice
        Igniter.add_notice(
          igniter,
          "PhoenixKit routes already exist in router #{inspect(router_module)}, skipping."
        )

      :error ->
        # Add import and routes call to router module
        igniter
        |> add_import_to_router_module(router_module)
        |> add_routes_call_to_router_module(router_module)
    end
  end

  # Add import PhoenixKitWeb.Integration to router
  defp add_import_to_router_module(igniter, router_module) do
    IgniterModule.find_and_update_module!(igniter, router_module, fn zipper ->
      handle_import_addition(igniter, zipper)
    end)
  end

  # Handle the addition of import statement to router
  defp handle_import_addition(igniter, zipper) do
    if import_already_exists?(zipper) do
      {:ok, zipper}
    else
      add_import_after_use_statement(igniter, zipper)
    end
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
  defp add_import_after_use_statement(igniter, zipper) do
    case IgniterPhoenix.move_to_router_use(igniter, zipper) do
      {:ok, use_zipper} ->
        import_code = "import PhoenixKitWeb.Integration"
        {:ok, Common.add_code(use_zipper, import_code, placement: :after)}

      :error ->
        {:warning,
         "Could not add import PhoenixKitWeb.Integration to router. Please add manually."}
    end
  end

  # Add phoenix_kit_routes() call to router with smart positioning
  # Inserts BEFORE catch-all routes like /:param or /*path to avoid conflicts
  defp add_routes_call_to_router_module(igniter, router_module) do
    # Get router source to analyze for catch-all routes
    {_igniter, source, _zipper} = IgniterModule.find_module!(igniter, router_module)

    # Check if router has catch-all routes
    router_code = Rewrite.Source.get(source, :content)
    has_catch_all = has_catch_all_routes?(router_code)

    IgniterModule.find_and_update_module!(igniter, router_module, fn zipper ->
      app_web_module_name = IgniterHelpers.get_parent_app_module_web_string(igniter)
      routes_code = generate_routes_code(app_web_module_name)

      if has_catch_all do
        # Try to insert before catch-all routes
        case find_catch_all_insertion_point(zipper) do
          {:ok, insertion_zipper} ->
            Mix.shell().info(
              "📍 Inserting phoenix_kit_routes() before catch-all routes for proper route matching"
            )

            {:ok, Common.add_code(insertion_zipper, routes_code, placement: :before)}

          :error ->
            # Fallback: add at end
            {:ok, Common.add_code(zipper, routes_code, placement: :after)}
        end
      else
        # No catch-all routes, add at end (current behavior)
        {:ok, Common.add_code(zipper, routes_code, placement: :after)}
      end
    end)
  end

  # Check if router code contains catch-all routes
  defp has_catch_all_routes?(code) when is_binary(code) do
    # Patterns that indicate catch-all routes:
    # - live "/:param"
    # - get "/:param"
    # - live "/:param/*path"
    # - scope "/" with live "/:param"
    catch_all_patterns = [
      # live "/:entity_name"
      ~r/live\s+["\']\/:[a-z_]+["\']/,
      # get "/:param"
      ~r/get\s+["\']\/:[a-z_]+["\']/,
      # live "/:entity/*path"
      ~r/live\s+["\']\/:[a-z_]+\/\*[a-z_]+["\']/,
      # get "/:entity/*path"
      ~r/get\s+["\']\/:[a-z_]+\/\*[a-z_]+["\']/
    ]

    Enum.any?(catch_all_patterns, &Regex.match?(&1, code))
  end

  # Find a good insertion point before catch-all routes
  # Returns {:ok, zipper} positioned at a scope or route before catch-all, or :error
  defp find_catch_all_insertion_point(zipper) do
    # Try to find a scope that contains catch-all routes
    # We look for scope "/" or scope "/", AppWeb patterns
    case Function.move_to_function_call(zipper, :scope, fn call_zipper ->
           # Check if this scope might contain catch-all routes
           scope_has_catch_all?(call_zipper)
         end) do
      {:ok, scope_zipper} ->
        {:ok, scope_zipper}

      :error ->
        # Try to find first live/get with catch-all pattern
        find_first_catch_all_route(zipper)
    end
  end

  # Check if a scope call contains catch-all routes
  defp scope_has_catch_all?(call_zipper) do
    # Get the scope's source code to check for catch-all patterns
    node = Sourceror.Zipper.node(call_zipper)
    code = Macro.to_string(node)
    has_catch_all_routes?(code)
  end

  # Find first live/get call with catch-all pattern
  defp find_first_catch_all_route(zipper) do
    # Look for live "/:..." patterns
    case Function.move_to_function_call(zipper, :live, fn call_zipper ->
           catch_all_route?(call_zipper)
         end) do
      {:ok, _} = result ->
        result

      :error ->
        # Try get routes
        Function.move_to_function_call(zipper, :get, fn call_zipper ->
          catch_all_route?(call_zipper)
        end)
    end
  end

  # Check if a route call is a catch-all (/:param pattern)
  defp catch_all_route?(call_zipper) do
    case Function.move_to_nth_argument(call_zipper, 0) do
      {:ok, arg_zipper} ->
        node = Sourceror.Zipper.node(arg_zipper)

        case node do
          path when is_binary(path) ->
            # Check if path starts with /:
            String.match?(path, ~r/^\/:[a-z_]+/)

          _ ->
            false
        end

      :error ->
        false
    end
  end

  # Generate the routes code with demo pages
  defp generate_routes_code(app_web_module_name) do
    """
    # PhoenixKit Demo Pages - Test Authentication Levels
    scope "/" do
      pipe_through :browser

      live_session :phoenix_kit_demo_current_scope,
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
        live "/test-current-user", #{app_web_module_name}.PhoenixKitLive.TestRequireAuthLive, :index
      end

      live_session :phoenix_kit_demo_redirect_if_auth_scope,
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_redirect_if_authenticated_scope}] do
        live "/test-redirect-if-auth", #{app_web_module_name}.PhoenixKitLive.TestRedirectIfAuthLive, :index
      end

      live_session :phoenix_kit_demo_ensure_auth_scope,
        on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}] do
        live "/test-ensure-auth", #{app_web_module_name}.PhoenixKitLive.TestEnsureAuthLive, :index
      end
    end

    phoenix_kit_routes()
    """
  end

  # Create comprehensive warning when router is not found
  defp create_router_not_found_warning(nil) do
    """
    🚨 Router Detection Failed

    PhoenixKit could not automatically detect your Phoenix router.

    📋 MANUAL SETUP REQUIRED:

    1. Open your main router file (usually lib/your_app_web/router.ex)

    2. Add the following lines to your router module:

       defmodule YourAppWeb.Router do
         use YourAppWeb, :router

         # Add this import
         import PhoenixKitWeb.Integration

         # Your existing pipelines and scopes...

         # Add this line at the end, before the final 'end'
         phoenix_kit_routes()
       end

    3. The routes will be available at:
       • {prefix}/register - User registration
       • {prefix}/login - User login
       • {prefix}/reset_password - Password reset
       Note: {prefix} is your configured PhoenixKit URL prefix (default: /phoenix_kit)
       • And other authentication routes

    📖 Common router locations:
       • lib/my_app_web/router.ex
       • lib/my_app/router.ex
       • apps/my_app_web/lib/my_app_web/router.ex (umbrella apps)

    ⚠️  Note: You may see a compiler warning about "unused import PhoenixKitWeb.Integration".
       This is normal behavior for Elixir macros and can be safely ignored.
       The phoenix_kit_routes() macro will expand correctly.

    💡 Need help? Check the PhoenixKit documentation or create an issue on GitHub.
    """
  end

  defp create_router_not_found_warning(custom_path) do
    """
    🚨 Router Not Found at Custom Path

    PhoenixKit could not find a router at the specified path: #{custom_path}

    📋 TROUBLESHOOTING STEPS:

    1. Verify the path exists and contains a valid Phoenix router
    2. Check file permissions (file must be readable)
    3. Ensure the file contains a proper Phoenix router module:

       defmodule YourAppWeb.Router do
         use YourAppWeb, :router
         # ... router content
       end

    📋 MANUAL SETUP (if file exists but couldn't be processed):

    Add the following to your router at #{custom_path}:

       # Add after 'use YourAppWeb, :router'
       import PhoenixKitWeb.Integration

       # Add before the final 'end'
       phoenix_kit_routes()

    🔄 ALTERNATIVE: Let PhoenixKit auto-detect your router:

    Run the installer without --router-path option:
       mix phoenix_kit.install

    ⚠️  Note: You may see a compiler warning about "unused import PhoenixKitWeb.Integration".
       This is normal for macros and can be safely ignored.

    💡 Need help? Check the PhoenixKit documentation or create an issue on GitHub.
    """
  end
end
