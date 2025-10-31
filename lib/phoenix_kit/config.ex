defmodule PhoenixKit.Config do
  @moduledoc """
  Configuration management system for PhoenixKit.

  This module provides a centralized way to manage PhoenixKit configuration.

  ## Usage

      # Get all configuration
      config = PhoenixKit.Config.get_all()

      # Get specific values
      repo = PhoenixKit.Config.get(:repo)
      mailer = PhoenixKit.Config.get(:mailer, PhoenixKit.Mailer)

  ## Configuration Keys

  - `:repo` - Ecto repository module (required)
  - `:mailer` - Mailer module for sending emails
  - `:host` - Application hostname
  - `:port` - Application port
  - `:layout_module` - Custom layout configuration
  - `:from_email` - Default sender email address for notifications
  - `:from_name` - Default sender name for notifications (default: "PhoenixKit")
  """

  @default_config [
    repo: nil,
    mailer: nil,
    scheme: "http",
    host: "localhost",
    port: 4000,
    url_prefix: "/phoenix_kit",
    layouts_module: nil,
    phoenix_version_strategy: nil,
    from_email: nil,
    from_name: "PhoenixKit",
    magic_link_for_login_expiry_minutes: 15,
    magic_link_for_registration_expiry_minutes: 30
  ]

  @doc """
  Gets all PhoenixKit configuration.
  """
  @spec get_all() :: Keyword.t()
  def get_all do
    app_config = Application.get_all_env(:phoenix_kit)
    Keyword.merge(@default_config, app_config)
  end

  @doc """
  Gets a specific configuration value.
  """
  @spec get(atom()) :: {:ok, any()} | :not_found
  def get(key) when is_atom(key) do
    config = get_all()

    case Keyword.get(config, key) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  @doc """
  Gets a specific configuration value with a default.

  ## Examples

      iex> PhoenixKit.Config.get(:mailer, PhoenixKit.Mailer)
      MyApp.Mailer

      iex> PhoenixKit.Config.get(:nonexistent, :default)
      :default
  """
  @spec get(atom(), any()) :: any()
  def get(key, default) when is_atom(key) do
    case get(key) do
      {:ok, value} -> value
      :not_found -> default
    end
  end

  @doc """
  Gets the configured mailer module.

  Returns the configured mailer or falls back to PhoenixKit.Mailer.

  ## Examples

      iex> PhoenixKit.Config.get_mailer()
      MyApp.Mailer

  """
  @spec get_mailer() :: module()
  def get_mailer do
    case get(:mailer) do
      {:ok, mailer} when is_atom(mailer) -> mailer
      _ -> PhoenixKit.Mailer
    end
  end

  @spec is_mailer_local?() :: boolean()
  def is_mailer_local?() do
    case get(PhoenixKit.Mailer, nil)[:adapter] do
      Swoosh.Adapters.Local -> true
      _ -> false
    end
  end

  @doc """
  Gets configured host with an optional port or default value.
  """
  @spec get_base_url() :: String.t()
  def get_base_url do
    host =
      case get(:host) do
        {:ok, host} -> host
        _ -> "localhost"
      end

    scheme =
      case get(:scheme) do
        {:ok, scheme} -> scheme
        _ -> "http"
      end

    port =
      case get(:port) do
        {:ok, port} when port not in [80, 443] -> ":#{port}"
        _ -> ":4000"
      end

    "#{scheme}://#{host}#{port}"
  end

  @doc """
  Gets the base URL dynamically from the parent Phoenix Endpoint if available,
  otherwise falls back to the static configuration.

  This function automatically detects the correct URL from the running Phoenix
  application, which is especially useful in development mode where the port
  might be different from the default configuration.

  ## Examples

      iex> PhoenixKit.Config.get_dynamic_base_url()
      "http://localhost:4001"  # from Phoenix Endpoint

      iex> PhoenixKit.Config.get_dynamic_base_url()
      "http://localhost:4000"  # fallback to static config
  """
  @spec get_dynamic_base_url() :: String.t()
  def get_dynamic_base_url do
    case get_parent_endpoint_url() do
      {:ok, url} -> url
      :error -> get_base_url()
    end
  end

  @doc """
  Gets the parent Phoenix Endpoint URL if the endpoint is available and running.

  Returns `{:ok, url}` if successful, `:error` if the endpoint cannot be found
  or accessed.
  """
  @spec get_parent_endpoint_url() :: {:ok, String.t()} | :error
  def get_parent_endpoint_url do
    with {:ok, endpoint} <- get_parent_endpoint(),
         true <- function_exported?(endpoint, :url, 0) do
      try do
        url = endpoint.url()
        {:ok, url}
      rescue
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  @doc """
  Gets the parent application's Phoenix Endpoint module.

  This function attempts to detect the main application's endpoint that is using
  PhoenixKit as a dependency.

  Returns `{:ok, endpoint_module}` if found, `:error` otherwise.
  """
  @spec get_parent_endpoint() :: {:ok, module()} | :error
  def get_parent_endpoint do
    case get_parent_app() do
      nil ->
        :error

      app_name ->
        base_module = app_name |> to_string() |> Macro.camelize()

        potential_endpoints = [
          Module.concat([base_module <> "Web", "Endpoint"]),
          Module.concat([base_module, "Endpoint"])
        ]

        Enum.reduce_while(potential_endpoints, :error, fn endpoint, _acc ->
          if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :url, 0) do
            {:halt, {:ok, endpoint}}
          else
            {:cont, :error}
          end
        end)
    end
  end

  @doc """
  Gets configured prefix for urls or default value.
  """
  @spec get_url_prefix() :: String.t()
  def get_url_prefix do
    case get(:url_prefix, "/phoenix_kit") do
      nil -> "/"
      "" -> "/"
      value -> value
    end
  end

  @doc """
  Gets the parent application name that is using PhoenixKit.

  This function attempts to detect the main application that has included
  PhoenixKit as a dependency.
  """
  @spec get_parent_app() :: atom() | nil
  def get_parent_app do
    # Get the application of the configured repo to determine parent app
    case get(:repo) do
      {:ok, repo_module} when is_atom(repo_module) ->
        # Extract app name from repo module (e.g. MyApp.Repo -> :my_app)
        repo_module
        |> Module.split()
        |> hd()
        |> Macro.underscore()
        |> String.to_atom()

      _ ->
        # Fallback: try to find the main application from the loaded applications
        Application.loaded_applications()
        |> Enum.find(fn {app, _, _} ->
          app != :phoenix_kit and
            app != :kernel and
            app != :stdlib and
            app != :elixir and
            not String.starts_with?(to_string(app), "ex_")
        end)
        |> case do
          {app, _, _} -> app
          nil -> nil
        end
    end
  end

  @doc """
  Validates that required configuration is present.

  Raises an exception if any required keys are missing.

  ## Examples

      PhoenixKit.Config.validate_required!([:repo, :secret_key_base])
  """
  def validate_required!(required_keys) do
    config = get_all()

    missing_keys =
      required_keys
      |> Enum.reject(&Keyword.has_key?(config, &1))

    if length(missing_keys) > 0 do
      raise """
      Missing required PhoenixKit configuration keys: #{inspect(missing_keys)}

      Current configuration: #{inspect(Keyword.keys(config))}

      Please add the missing keys to your configuration:

          config :phoenix_kit,
            #{Enum.map_join(missing_keys, ",\n  ", &"#{&1}: YourValue")}
      """
    end

    :ok
  end
end
