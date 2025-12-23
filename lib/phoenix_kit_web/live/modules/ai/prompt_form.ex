defmodule PhoenixKitWeb.Live.Modules.AI.PromptForm do
  @moduledoc """
  LiveView for creating and editing AI prompts.

  A prompt is a reusable text template with variable substitution support.
  Variables use the `{{VariableName}}` syntax.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.AI
  alias PhoenixKit.AI.Prompt
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # ===========================================
  # LIFECYCLE
  # ===========================================

  @impl true
  def mount(params, _session, socket) do
    if AI.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:current_path, Routes.path("/admin/ai"))
        |> assign(:extracted_variables, [])
        |> load_prompt(params["id"])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "AI module is not enabled")
       |> push_navigate(to: Routes.path("/admin/modules"))}
    end
  end

  defp load_prompt(socket, nil) do
    changeset = AI.change_prompt(%Prompt{})

    socket
    |> assign(:page_title, "New AI Prompt")
    |> assign(:prompt, nil)
    |> assign(:form, to_form(changeset))
  end

  defp load_prompt(socket, id) do
    case AI.get_prompt(String.to_integer(id)) do
      nil ->
        socket
        |> put_flash(:error, "Prompt not found")
        |> push_navigate(to: Routes.ai_path() <> "/prompts")

      prompt ->
        changeset = AI.change_prompt(prompt)

        socket
        |> assign(:page_title, "Edit AI Prompt")
        |> assign(:prompt, prompt)
        |> assign(:form, to_form(changeset))
        |> assign(:extracted_variables, prompt.variables || [])
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # ===========================================
  # EVENT HANDLERS
  # ===========================================

  @impl true
  def handle_event("validate", %{"prompt" => params}, socket) do
    changeset =
      (socket.assigns.prompt || %Prompt{})
      |> AI.change_prompt(params)

    # Extract variables from content for preview
    content = params["content"] || ""
    extracted_variables = Prompt.extract_variables(content)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:extracted_variables, extracted_variables)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"prompt" => params}, socket) do
    save_prompt(socket, params)
  end

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp save_prompt(socket, params) do
    result =
      if socket.assigns.prompt do
        AI.update_prompt(socket.assigns.prompt, params)
      else
        AI.create_prompt(params)
      end

    case result do
      {:ok, _prompt} ->
        action = if socket.assigns.prompt, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Prompt #{action} successfully")
         |> push_navigate(to: Routes.ai_path() <> "/prompts")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
