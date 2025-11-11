defmodule PhoenixKit.Install.BrowserPipelineIntegration do
  use PhoenixKit.Install.IgniterCompat

  @moduledoc """
  Handles automatic integration of PhoenixKit plugs into the browser pipeline.

  This module provides functionality to:
  - Add PhoenixKitWeb.Plugs.Integration to the :browser pipeline automatically
  - Handle cases where the plug already exists (idempotent)
  - Provide clear error messages if browser pipeline is not found

  ## Extensibility

  The Integration plug acts as a single entry point for all PhoenixKit plugs.
  New features can be added to the Integration plug without modifying the
  parent application's pipeline.
  """

  alias Igniter.Libs.Phoenix, as: IgniterPhoenix
  alias Igniter.Project.Module, as: IgniterModule

  @doc """
  Adds the PhoenixKit Integration plug to the :browser pipeline in the Phoenix router.

  This plug coordinates all PhoenixKit features that need to run in the browser pipeline,
  including maintenance mode, and any future features.

  ## Parameters
  - `igniter` - The igniter context

  ## Returns
  Updated igniter with integration plug added or warning if router/pipeline not found.
  """
  def add_integration_to_browser_pipeline(igniter) do
    case IgniterPhoenix.select_router(igniter) do
      {igniter, nil} ->
        # No router found, add warning
        Igniter.add_warning(
          igniter,
          """
          Could not find router to add PhoenixKit Integration plug.

          Please add the following line to your :browser pipeline manually:

              plug PhoenixKitWeb.Plugs.Integration
          """
        )

      {igniter, router_module} ->
        # Check if plug already exists before adding
        if plug_already_exists?(igniter, router_module) do
          igniter
        else
          # Use Igniter's built-in append_to_pipeline function
          IgniterPhoenix.append_to_pipeline(
            igniter,
            :browser,
            "plug PhoenixKitWeb.Plugs.Integration",
            router: router_module
          )
        end
    end
  end

  # Check if Integration plug already exists in the router
  defp plug_already_exists?(igniter, router_module) do
    case IgniterModule.find_module(igniter, router_module) do
      {:ok, {_igniter, source, _zipper}} ->
        content = Rewrite.Source.get(source, :content)
        String.contains?(content, "PhoenixKitWeb.Plugs.Integration")

      {:error, _igniter} ->
        false
    end
  end
end
