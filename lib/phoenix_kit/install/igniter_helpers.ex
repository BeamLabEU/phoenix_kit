# Igniter-only helper: every caller is a `mix phoenix_kit.*` igniter task,
# which is itself guarded the same way. Igniter is an OPTIONAL dependency
# (see mix.exs), so a host that scopes it to `only: [:dev, :test]` compiles
# :prod without it — unguarded, this module emitted a wall of
# "Igniter.X is undefined" warnings on every production build.
if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixKit.Install.IgniterHelpers do
    @moduledoc """
    Helper functions for working with Igniter to detect parent application information.

    This module provides utilities to automatically detect and extract information about
    the parent Phoenix application during the installation process. These helpers are
    used by the installer to determine module names, layouts, and router configurations
    without requiring manual user input.

    All functions are designed to work with Igniter's project detection capabilities
    and provide sensible defaults when detection fails.

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_name(igniter)
        :parent_app

        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web_string(igniter)
        "ParentAppWeb"
    """

    alias Igniter.Project.Module, as: IgniterModule

    @doc """
    Whether the task was started with Igniter's `--dry-run`.

    Igniter honours the flag for every change made through its buffer; a step
    that writes to disk directly (the root-layout and `app.js` splices in
    `PhoenixKit.Install.JsIntegration`) must ask this first and only describe
    the change.
    """
    @spec dry_run?(Igniter.t()) :: boolean()
    def dry_run?(%{args: %{options: options, argv: argv}}) do
      Keyword.get(List.wrap(options), :dry_run, false) == true or
        "--dry-run" in List.wrap(argv)
    end

    def dry_run?(_igniter), do: false

    @doc """
    Trims the blank lines around every notice, warning and issue.

    Igniter prints each one as `"* " <> message`, so a message written as a
    heredoc that starts with an empty line (most of the kit's do) came out as
    a bare `* ` bullet with the text on the lines below it. Run last in a
    task's `igniter/1`. Non-string entries (an exception as a warning) are
    left as they are; messages that become identical are kept once.
    """
    @spec tidy_messages(Igniter.t()) :: Igniter.t()
    def tidy_messages(igniter) do
      %{
        igniter
        | notices: tidy_list(igniter.notices),
          warnings: tidy_list(igniter.warnings),
          issues: tidy_list(igniter.issues)
      }
    end

    defp tidy_list(messages) do
      messages
      |> Enum.map(fn
        message when is_binary(message) -> String.trim(message)
        other -> other
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end

    @doc """
    Gets the parent application name (atom) from the Igniter project.

    Uses Igniter's application detection to determine the OTP application name.
    This is typically used for configuration and dependency injection.

    ## Parameters

    - `igniter` - The Igniter project struct

    ## Returns

    The application name as an atom (e.g., `:parent_app`)

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_name(igniter)
        :parent_app
    """
    @spec get_parent_app_name(Igniter.t()) :: atom()
    def get_parent_app_name(igniter) do
      Igniter.Project.Application.app_name(igniter)
    end

    @doc """
    Gets the parent application module name from the Igniter project.

    Extracts the main application module name (e.g., `ParentApp`) from the project
    structure. This is used as the base for constructing other module names.

    ## Parameters

    - `igniter` - The Igniter project struct

    ## Returns

    The main application module as an atom (e.g., `ParentApp`)

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module(igniter)
        ParentApp
    """
    @spec get_parent_app_module(Igniter.t()) :: module()
    def get_parent_app_module(igniter) do
      Igniter.Project.Module.module_name_prefix(igniter)
    end

    @doc """
    Constructs the Web module name for the parent application.

    Builds the standard Phoenix Web module name by concatenating the base
    application module with "Web" (e.g., `ParentAppWeb`).

    ## Parameters

    - `igniter` - The Igniter project struct

    ## Returns

    The Web module as an atom (e.g., `ParentAppWeb`)

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web(igniter)
        ParentAppWeb
    """
    @spec get_parent_app_module_web(Igniter.t()) :: module()
    def get_parent_app_module_web(igniter) do
      module_name = IgniterModule.module_name_prefix(igniter)
      module_name_web = Module.concat(["#{module_name}" <> "Web"])

      module_name_web
    end

    @doc """
    Gets the Web module name as a string with fallback to default.

    Converts the Web module to a string representation and provides a fallback
    default value when detection fails. This is useful for generating user-facing
    messages or configuration examples.

    ## Parameters

    - `igniter` - The Igniter project struct
    - `default` - Default string to return when detection fails (default: "YourAppWeb")

    ## Returns

    The Web module name as a string (e.g., "ParentAppWeb") or the default value

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web_string(igniter)
        "ParentAppWeb"

        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web_string(igniter, "FallbackWeb")
        "ParentAppWeb"
    """
    @spec get_parent_app_module_web_string(Igniter.t(), String.t()) :: String.t()
    def get_parent_app_module_web_string(igniter, default \\ "YourAppWeb") do
      module_name_web = get_parent_app_module_web(igniter)

      name = Macro.to_string(module_name_web)

      if name === "nil" do
        default
      else
        name
      end
    end

    @doc """
    Detects the existing Layouts module in the parent application.

    Searches for Layouts modules in both possible locations:
    - `ParentAppWeb.Layouts` (standard Phoenix location)
    - `ParentApp.Layouts` (alternative location)

    This function is used during installation to determine which layout module
    exists so PhoenixKit can integrate with the existing layout structure.

    ## Parameters

    - `igniter` - The Igniter project struct

    ## Returns

    The Layouts module if found, or `nil` if no Layouts module exists

    ## Search Order

    1. `MyAppWeb.Layouts` - Standard Phoenix web layouts location
    2. `MyApp.Layouts` - Alternative layouts location

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web_layouts(igniter)
        MyAppWeb.Layouts

        # When no layouts module exists
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web_layouts(igniter)
        nil
    """
    @spec get_parent_app_module_web_layouts(Igniter.t()) :: module() | nil
    def get_parent_app_module_web_layouts(igniter) do
      module_name = IgniterModule.module_name_prefix(igniter)
      module_name_web = Module.concat(["#{module_name}" <> "Web"])

      module_name_layouts = Module.concat([module_name, Layouts])
      module_name_web_layouts = Module.concat([module_name_web, Layouts])

      case IgniterModule.module_exists(igniter, module_name_web_layouts) do
        {true, _igniter} ->
          module_name_web_layouts

        {false, igniter} ->
          case IgniterModule.module_exists(igniter, module_name_layouts) do
            {true, _igniter} ->
              module_name_layouts

            {false, _igniter} ->
              nil
          end
      end
    end

    @doc """
    Constructs the Router module name for the parent application.

    Builds the standard Phoenix Router module name by concatenating the Web
    module with "Router" (e.g., `MyAppWeb.Router`).

    This is used during installation to determine where to inject PhoenixKit
    routes into the existing router configuration.

    ## Parameters

    - `igniter` - The Igniter project struct

    ## Returns

    The Router module as an atom (e.g., `MyAppWeb.Router`)

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web_router(igniter)
        MyAppWeb.Router
    """
    @spec get_parent_app_module_web_router(Igniter.t()) :: module()
    def get_parent_app_module_web_router(igniter) do
      module_name = IgniterModule.module_name_prefix(igniter)
      module_name_web = Module.concat(["#{module_name}" <> "Web"])
      module_name_web_router = Module.concat([module_name_web, Router])

      module_name_web_router
    end

    @doc """
    Constructs the Endpoint module name for the parent application.

    Builds the standard Phoenix Endpoint module name by concatenating the Web
    module with "Endpoint" (e.g., `MyAppWeb.Endpoint`).

    This is used during installation to add PhoenixKit sockets to the endpoint.

    ## Parameters

    - `igniter` - The Igniter project struct

    ## Returns

    The Endpoint module as an atom (e.g., `MyAppWeb.Endpoint`)

    ## Examples

        iex> igniter = Igniter.new()
        iex> PhoenixKit.Install.IgniterHelpers.get_parent_app_module_web_endpoint(igniter)
        MyAppWeb.Endpoint
    """
    @spec get_parent_app_module_web_endpoint(Igniter.t()) :: module()
    def get_parent_app_module_web_endpoint(igniter) do
      module_name = IgniterModule.module_name_prefix(igniter)
      module_name_web = Module.concat(["#{module_name}" <> "Web"])
      Module.concat([module_name_web, Endpoint])
    end
  end
end
