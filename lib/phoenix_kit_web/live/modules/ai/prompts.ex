defmodule PhoenixKitWeb.Live.Modules.AI.Prompts do
  @moduledoc """
  LiveView for AI prompts management.

  This module provides an interface for managing reusable AI prompt templates
  with variable substitution support.

  ## Features

  - **Prompt Management**: Add, edit, delete, enable/disable AI prompts
  - **Variable Display**: Shows extracted variables from prompt content
  - **Usage Tracking**: View usage count and last used time

  ## Route

  This LiveView is mounted at `{prefix}/admin/ai/prompts` and requires
  appropriate admin permissions.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.AI
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @sort_options [
    {:sort_order, "Order"},
    {:name, "Name"},
    {:usage_count, "Usage"},
    {:last_used_at, "Last Used"},
    {:inserted_at, "Created"}
  ]

  @impl true
  def mount(_params, session, socket) do
    current_path = get_current_path(socket, session)
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "AI Prompts")
      |> assign(:project_title, project_title)
      |> assign(:prompts, [])
      |> assign(:sort_by, :sort_order)
      |> assign(:sort_dir, :asc)
      |> assign(:sort_options, @sort_options)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {sort_by, sort_dir} = parse_sort_params(params)
    current_path = URI.parse(uri).path

    socket =
      socket
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:current_path, current_path)
      |> reload_prompts()

    {:noreply, socket}
  end

  @valid_sort_fields Enum.map(@sort_options, fn {field, _} -> Atom.to_string(field) end)

  defp parse_sort_params(params) do
    sort_by =
      case params["sort"] do
        field when is_binary(field) ->
          if field in @valid_sort_fields do
            String.to_existing_atom(field)
          else
            :sort_order
          end

        _ ->
          :sort_order
      end

    sort_dir =
      case params["dir"] do
        "asc" -> :asc
        "desc" -> :desc
        _ -> :asc
      end

    {sort_by, sort_dir}
  end

  # ===========================================
  # PROMPT ACTIONS
  # ===========================================

  @impl true
  def handle_event("toggle_prompt", %{"id" => id}, socket) do
    prompt = AI.get_prompt!(String.to_integer(id))

    case AI.update_prompt(prompt, %{enabled: !prompt.enabled}) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> reload_prompts()
         |> put_flash(:info, "Prompt #{if prompt.enabled, do: "disabled", else: "enabled"}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update prompt")}
    end
  end

  @impl true
  def handle_event("delete_prompt", %{"id" => id}, socket) do
    prompt = AI.get_prompt!(String.to_integer(id))

    case AI.delete_prompt(prompt) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload_prompts()
         |> put_flash(:info, "Prompt deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete prompt")}
    end
  end

  @impl true
  def handle_event("sort", %{"by" => field}, socket) do
    # Validate field before converting to atom to prevent crashes from malicious input
    field =
      if field in @valid_sort_fields do
        String.to_existing_atom(field)
      else
        :sort_order
      end

    current_sort_by = socket.assigns.sort_by
    current_sort_dir = socket.assigns.sort_dir

    # Toggle direction if same field, otherwise default to desc for usage/last_used, asc for others
    sort_dir =
      if field == current_sort_by do
        if current_sort_dir == :asc, do: :desc, else: :asc
      else
        if field in [:usage_count, :last_used_at, :inserted_at], do: :desc, else: :asc
      end

    path = Routes.ai_path() <> "/prompts?sort=#{field}&dir=#{sort_dir}"
    {:noreply, push_patch(socket, to: path)}
  end

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp reload_prompts(socket) do
    sort_by = socket.assigns.sort_by
    sort_dir = socket.assigns.sort_dir

    prompts = AI.list_prompts(sort_by: sort_by, sort_dir: sort_dir)

    assign(socket, :prompts, prompts)
  end

  defp get_current_path(socket, session) do
    case socket.assigns do
      %{__changed__: _, current_path: path} when is_binary(path) -> path
      _ -> session["current_path"] || Routes.ai_path() <> "/prompts"
    end
  end
end
