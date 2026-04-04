defmodule PhoenixKit.Modules.LLMText.Web.Settings do
  @moduledoc """
  Admin settings LiveView for the LLM Text module.

  Placeholder — full UI to be implemented in a future iteration.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.LLMText

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "LLM Text Settings", enabled: LLMText.enabled?())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-2xl font-semibold mb-4">LLM Text</h1>
      <p class="text-base-content/70">LLM Text settings coming soon.</p>
      <p class="mt-2 text-sm text-base-content/50">
        Module enabled: {@enabled}
      </p>
    </div>
    """
  end
end
