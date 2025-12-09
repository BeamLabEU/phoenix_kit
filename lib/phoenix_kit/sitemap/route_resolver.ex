defmodule PhoenixKit.Sitemap.RouteResolver do
  @moduledoc """
  Resolves actual routes from parent application router.

  Uses router introspection to automatically detect URL patterns,
  falling back to Settings configuration when introspection fails.

  ## Resolution Priority

  1. Router Introspection - automatic detection from parent app router
  2. Settings override - manual configuration in PhoenixKit Settings
  3. Hardcoded fallback - default values

  ## Usage

      # Find path for specific plug module
      RouteResolver.find_route(PhoenixKitWeb.Users.Registration)
      # => "/users/register"

      # Find content route by type
      RouteResolver.find_content_route(:pages)
      # => "/pages/:slug"

      RouteResolver.find_content_route(:entity, "product")
      # => "/products/:slug"
  """

  require Logger

  @doc """
  Gets router module with automatic discovery.

  Resolution order:
  1. `config :phoenix_kit, router: MyAppWeb.Router`
  2. Via endpoint from `config :phoenix_kit, endpoint: MyAppWeb.Endpoint`
  3. Auto-discover from OTP applications (finds *Web.Router modules)
  """
  def get_router do
    # 1. Explicit router config
    case PhoenixKit.Config.get(:router) do
      {:ok, router} when not is_nil(router) ->
        if valid_router?(router), do: router, else: try_endpoint_router()

      _ ->
        try_endpoint_router()
    end
  end

  defp try_endpoint_router do
    # 2. Get router through endpoint
    case PhoenixKit.Config.get(:endpoint) do
      {:ok, endpoint} when not is_nil(endpoint) ->
        router = get_router_from_endpoint(endpoint)
        if router, do: router, else: try_auto_discover()

      _ ->
        try_auto_discover()
    end
  end

  defp get_router_from_endpoint(endpoint) do
    if Code.ensure_loaded?(endpoint) do
      try do
        router = endpoint.config(:router)
        if valid_router?(router), do: router, else: nil
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  # Auto-discover router from loaded OTP applications
  defp try_auto_discover do
    # Get all loaded applications except known system ones
    excluded_apps = ~w(
      elixir stdlib kernel compiler phoenix phoenix_live_view phoenix_html
      plug ecto ecto_sql postgrex jason swoosh oban hammer bcrypt_elixir
      argon2_elixir telemetry logger gettext phoenix_pubsub castore
      mint finch req nimble_options phoenix_ecto floki html_entities
      ex_doc makeup makeup_elixir makeup_erlang earmark_parser mdex
      timex tzdata combine file_system esbuild tailwind heroicons
      phoenix_kit ueberauth ueberauth_google ueberauth_github
      ueberauth_apple ueberauth_facebook assent jose igniter
      owl sourceror spitfire rewrite glob_ex infer inflex
      phoenix_live_dashboard observer_cli
    )a

    :application.loaded_applications()
    |> Enum.map(fn {app, _, _} -> app end)
    |> Enum.reject(&(&1 in excluded_apps))
    |> Enum.find_value(&find_router_in_app/1)
  end

  defp find_router_in_app(app) do
    # Try common router module naming patterns
    app_name = app |> to_string() |> Macro.camelize()

    patterns = [
      "#{app_name}Web.Router",
      "#{app_name}.Router",
      "#{app_name}Web.Web.Router"
    ]

    Enum.find_value(patterns, fn pattern ->
      module = String.to_atom("Elixir.#{pattern}")

      if valid_router?(module) do
        Logger.debug("RouteResolver: Auto-discovered router #{inspect(module)}")
        module
      else
        nil
      end
    end)
  end

  defp valid_router?(nil), do: false

  defp valid_router?(router) do
    Code.ensure_loaded?(router) and
      function_exported?(router, :__routes__, 0)
  end

  @doc """
  Returns all routes from the parent router.

  Returns empty list if router is not available.
  """
  @spec get_routes() :: [map()]
  def get_routes do
    case get_router() do
      nil ->
        []

      router ->
        try do
          router.__routes__()
        rescue
          error ->
            Logger.debug("RouteResolver: Failed to get routes: #{inspect(error)}")
            []
        end
    end
  end

  @doc """
  Finds path for a specific plug module.

  ## Options

  - `:verb` - HTTP verb to match (default: `:get`)

  ## Examples

      find_route(PhoenixKitWeb.Users.Registration)
      # => "/users/register"

      find_route(MyApp.SomeController, verb: :post)
      # => "/some/path"
  """
  @spec find_route(module(), keyword()) :: String.t() | nil
  def find_route(plug_module, opts \\ []) do
    verb = Keyword.get(opts, :verb, :get)

    get_routes()
    |> Enum.find(fn route ->
      route.plug == plug_module and route.verb == verb
    end)
    |> case do
      nil -> nil
      route -> route.path
    end
  end

  @doc """
  Finds route pattern by content type.

  ## Types

  - `:pages` - Finds routes that look like page routes (contain :slug and plug name contains "page")
  - `:entity` - Finds routes matching entity name (singular or plural form)

  ## Examples

      find_content_route(:pages)
      # => "/pages/:slug"

      find_content_route(:entity, "product")
      # => "/products/:slug"

      find_content_route(:entity, "page")
      # => "/pages/:slug"
  """
  @spec find_content_route(atom(), String.t() | nil) :: String.t() | nil
  def find_content_route(type, name \\ nil)

  def find_content_route(:pages, _name) do
    get_routes()
    |> Enum.filter(fn route ->
      route.verb == :get and
        (String.contains?(route.path, ":slug") or
           String.contains?(route.path, "*path"))
    end)
    |> Enum.find(fn route ->
      plug_name = to_string(route.plug) |> String.downcase()
      String.contains?(plug_name, "page") or String.contains?(plug_name, "content")
    end)
    |> extract_path()
  end

  def find_content_route(:entity, entity_name) when is_binary(entity_name) do
    entity_lower = String.downcase(entity_name)

    routes =
      get_routes()
      |> Enum.filter(fn route ->
        route.verb == :get and
          (String.contains?(route.path, ":slug") or String.contains?(route.path, ":id"))
      end)

    # First try exact entity name match
    exact_match =
      Enum.find(routes, fn route ->
        path_lower = String.downcase(route.path)
        # Match both singular and plural forms in path
        String.contains?(path_lower, "/#{entity_lower}/") or
          String.contains?(path_lower, "/#{entity_lower}s/") or
          String.starts_with?(path_lower, "/#{entity_lower}/") or
          String.starts_with?(path_lower, "/#{entity_lower}s/")
      end)

    if exact_match do
      extract_path(exact_match)
    else
      # Try catch-all pattern like /:entity_name/:slug or /:name/:slug
      find_catchall_entity_route(routes, entity_name)
    end
  end

  def find_content_route(_, _), do: nil

  @doc """
  Finds index route for entity (list page without :slug).

  ## Examples

      find_index_route(:entity, "page")
      # => "/page" or "/pages"

      find_index_route(:entity, "product")
      # => "/products"
  """
  @spec find_index_route(atom(), String.t()) :: String.t() | nil
  def find_index_route(:entity, entity_name) when is_binary(entity_name) do
    entity_lower = String.downcase(entity_name)

    # First try static routes (without params)
    static_routes =
      get_routes()
      |> Enum.filter(fn route ->
        route.verb == :get and
          not String.contains?(route.path, ":") and
          not String.contains?(route.path, "*")
      end)

    exact_match =
      Enum.find(static_routes, fn route ->
        path_lower = String.downcase(route.path)
        # Match exact entity path or plural form
        path_lower == "/#{entity_lower}" or
          path_lower == "/#{entity_lower}s" or
          String.ends_with?(path_lower, "/#{entity_lower}") or
          String.ends_with?(path_lower, "/#{entity_lower}s")
      end)

    if exact_match do
      extract_path(exact_match)
    else
      # Try catch-all pattern like /:entity_name
      param_routes =
        get_routes()
        |> Enum.filter(fn route ->
          route.verb == :get and
            String.contains?(route.path, ":") and
            not String.contains?(route.path, "*")
        end)

      find_catchall_index_route(param_routes, entity_name)
    end
  end

  def find_index_route(_, _), do: nil

  @doc """
  Extracts URL prefix from a route pattern.

  ## Examples

      extract_prefix("/pages/:slug")
      # => "/pages"

      extract_prefix("/content/*path")
      # => "/content"

      extract_prefix("/blog/posts/:id")
      # => "/blog/posts"
  """
  @spec extract_prefix(String.t() | nil) :: String.t() | nil
  def extract_prefix(nil), do: nil

  def extract_prefix(pattern) when is_binary(pattern) do
    pattern
    |> String.split("/:")
    |> List.first()
    |> String.split("/*")
    |> List.first()
    |> case do
      "" -> "/"
      prefix -> prefix
    end
  end

  # Private helpers

  # Find catch-all entity routes like /:entity_name/:slug
  # Returns the pattern with :entity_name replaced by actual entity name
  defp find_catchall_entity_route(routes, entity_name) do
    catchall_patterns = [
      ~r{^/:entity_name/:slug$},
      ~r{^/:entity/:slug$},
      ~r{^/:name/:slug$},
      ~r{^/:type/:slug$},
      ~r{^/:[a-z_]+/:slug$}
    ]

    Enum.find_value(routes, fn route ->
      if Enum.any?(catchall_patterns, &Regex.match?(&1, route.path)) do
        # Replace the first param with entity name
        route.path
        |> String.replace(~r{^/:[a-z_]+/}, "/#{entity_name}/")
      else
        nil
      end
    end)
  end

  # Find catch-all index routes like /:entity_name
  defp find_catchall_index_route(routes, entity_name) do
    catchall_patterns = [
      ~r{^/:entity_name$},
      ~r{^/:entity$},
      ~r{^/:name$},
      ~r{^/:type$},
      ~r{^/:[a-z_]+$}
    ]

    Enum.find_value(routes, fn route ->
      if Enum.any?(catchall_patterns, &Regex.match?(&1, route.path)) do
        # Replace with entity name
        "/#{entity_name}"
      else
        nil
      end
    end)
  end

  defp extract_path(nil), do: nil
  defp extract_path(route), do: route.path
end
