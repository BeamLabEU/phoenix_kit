defmodule PhoenixKit.Modules.AI.Web.Playground do
  @moduledoc """
  LiveView for testing AI endpoints and prompts.

  Provides an interactive playground where admins can:
  - Select an endpoint and optionally a prompt
  - Fill in prompt variables
  - Send requests and see AI responses
  - Type freeform messages when no prompt is selected
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.AI
  alias PhoenixKit.Modules.AI.Completion
  alias PhoenixKit.Modules.AI.Prompt
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # ===========================================
  # LIFECYCLE
  # ===========================================

  @impl true
  def mount(_params, _session, socket) do
    if AI.enabled?() do
      project_title = Settings.get_project_title()

      {endpoints, _total} = AI.list_endpoints(enabled: true, page: 1, page_size: 100)
      prompts = AI.list_prompts(enabled: true)

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:current_path, Routes.path("/admin/ai/playground"))
        |> assign(:page_title, "AI Playground")
        |> assign(:endpoints, endpoints)
        |> assign(:prompts, prompts)
        |> assign(:selected_endpoint_uuid, nil)
        |> assign(:selected_prompt_uuid, nil)
        |> assign(:selected_prompt, nil)
        |> assign(:variable_values, %{})
        |> assign(:edited_content, nil)
        |> assign(:edited_variables, [])
        |> assign(:freeform_system, "")
        |> assign(:freeform_message, "")
        |> assign(:response_text, nil)
        |> assign(:response_usage, nil)
        |> assign(:response_error, nil)
        |> assign(:sending, false)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "AI module is not enabled")
       |> push_navigate(to: Routes.path("/admin/modules"))}
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
  def handle_event("change", params, socket) do
    socket = apply_form_changes(socket, params)
    {:noreply, socket}
  end

  @impl true
  def handle_event("send", _params, socket) do
    endpoint_uuid = socket.assigns.selected_endpoint_uuid

    if is_nil(endpoint_uuid) do
      {:noreply, put_flash(socket, :error, "Please select an endpoint")}
    else
      socket =
        socket
        |> assign(:sending, true)
        |> assign(:response_text, nil)
        |> assign(:response_usage, nil)
        |> assign(:response_error, nil)

      send(self(), :do_send)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear", _params, socket) do
    socket =
      socket
      |> assign(:response_text, nil)
      |> assign(:response_usage, nil)
      |> assign(:response_error, nil)
      |> assign(:freeform_message, "")
      |> assign(:freeform_system, "")

    {:noreply, socket}
  end

  # Form change helpers

  defp apply_form_changes(socket, params) do
    socket
    |> maybe_update_endpoint(params)
    |> maybe_update_prompt(params)
    |> maybe_update_content(params)
    |> maybe_update_variables(params)
    |> maybe_update_freeform(params)
  end

  defp maybe_update_endpoint(socket, %{"endpoint_uuid" => uuid}) do
    uuid = if uuid == "", do: nil, else: uuid
    assign(socket, :selected_endpoint_uuid, uuid)
  end

  defp maybe_update_endpoint(socket, _), do: socket

  defp maybe_update_prompt(socket, %{"prompt_uuid" => uuid}) do
    uuid = if uuid == "", do: nil, else: uuid

    # Only re-initialize when the prompt actually changes
    if uuid == socket.assigns.selected_prompt_uuid do
      socket
    else
      prompt =
        if uuid do
          Enum.find(socket.assigns.prompts, &(&1.uuid == uuid))
        end

      edited_content = if prompt, do: prompt.content, else: nil
      variables = if prompt, do: Prompt.extract_variables(edited_content || ""), else: []

      variable_values =
        if prompt do
          Map.new(variables, fn var -> {var, ""} end)
        else
          %{}
        end

      socket
      |> assign(:selected_prompt_uuid, uuid)
      |> assign(:selected_prompt, prompt)
      |> assign(:edited_content, edited_content)
      |> assign(:edited_variables, variables)
      |> assign(:variable_values, variable_values)
      |> assign(:response_text, nil)
      |> assign(:response_usage, nil)
      |> assign(:response_error, nil)
    end
  end

  defp maybe_update_prompt(socket, _), do: socket

  defp maybe_update_content(socket, %{"edited_content" => content}) do
    new_vars = Prompt.extract_variables(content)
    old_vars = socket.assigns.edited_variables

    # Preserve existing variable values, add empty for new ones
    variable_values =
      if new_vars != old_vars do
        Map.new(new_vars, fn var ->
          {var, Map.get(socket.assigns.variable_values, var, "")}
        end)
      else
        socket.assigns.variable_values
      end

    socket
    |> assign(:edited_content, content)
    |> assign(:edited_variables, new_vars)
    |> assign(:variable_values, variable_values)
  end

  defp maybe_update_content(socket, _), do: socket

  defp maybe_update_variables(socket, %{"variables" => variables}) when is_map(variables) do
    assign(socket, :variable_values, Map.merge(socket.assigns.variable_values, variables))
  end

  defp maybe_update_variables(socket, _), do: socket

  defp maybe_update_freeform(socket, params) do
    socket
    |> then(fn s ->
      case Map.get(params, "message") do
        nil -> s
        msg -> assign(s, :freeform_message, msg)
      end
    end)
    |> then(fn s ->
      case Map.get(params, "system") do
        nil -> s
        sys -> assign(s, :freeform_system, sys)
      end
    end)
  end

  @impl true
  def handle_info(:do_send, socket) do
    result = execute_request(socket.assigns)

    socket =
      case result do
        {:ok, text, usage} ->
          socket
          |> assign(:response_text, text)
          |> assign(:response_usage, usage)
          |> assign(:response_error, nil)

        {:error, reason} ->
          socket
          |> assign(:response_error, reason)
      end

    {:noreply, assign(socket, :sending, false)}
  end

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp execute_request(assigns) do
    endpoint_uuid = assigns.selected_endpoint_uuid
    prompt = assigns.selected_prompt
    variable_values = assigns.variable_values
    edited_content = assigns.edited_content

    if prompt do
      # Use edited content (user may have modified the template)
      prompt_with_edits = %{prompt | content: edited_content || prompt.content}
      execute_prompt_request(endpoint_uuid, prompt_with_edits, variable_values)
    else
      execute_freeform_request(
        endpoint_uuid,
        assigns.freeform_message,
        assigns.freeform_system
      )
    end
  end

  defp execute_prompt_request(endpoint_uuid, prompt, variable_values) do
    with {:ok, rendered_content} <- Prompt.render(prompt, variable_values),
         {:ok, rendered_system} <- Prompt.render_system_prompt(prompt, variable_values) do
      opts =
        [
          source: "Playground",
          prompt_uuid: prompt.uuid,
          prompt_name: prompt.name
        ]
        |> maybe_add_system(rendered_system)

      case AI.ask(endpoint_uuid, rendered_content, opts) do
        {:ok, response} ->
          AI.increment_prompt_usage(prompt.uuid)
          {:ok, extract_text(response), Completion.extract_usage(response)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_freeform_request(_endpoint_uuid, "", _system) do
    {:error, "Please enter a message"}
  end

  defp execute_freeform_request(endpoint_uuid, message, system) do
    opts =
      [source: "Playground"]
      |> maybe_add_system(if(system == "", do: nil, else: system))

    case AI.ask(endpoint_uuid, message, opts) do
      {:ok, response} ->
        {:ok, extract_text(response), Completion.extract_usage(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_system(opts, nil), do: opts
  defp maybe_add_system(opts, system), do: Keyword.put(opts, :system, system)

  defp extract_text(response) do
    case Completion.extract_content(response) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> "(No content in response)"
    end
  end
end
