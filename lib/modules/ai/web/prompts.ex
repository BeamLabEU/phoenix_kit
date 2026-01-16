defmodule PhoenixKit.Modules.AI.Web.Prompts do
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

  alias PhoenixKit.Modules.AI
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @sort_options [
    {:sort_order, "Order"},
    {:name, "Name"},
    {:usage_count, "Usage"},
    {:last_used_at, "Last Used"},
    {:inserted_at, "Created"}
  ]

  @page_size 20

  @impl true
  def mount(_params, session, socket) do
    current_path = get_current_path(socket, session)
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Subscribe to real-time updates
    if connected?(socket) do
      AI.subscribe_prompts()
    end

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "AI Prompts")
      |> assign(:project_title, project_title)
      |> assign(:prompts, [])
      |> assign(:sort_by, :sort_order)
      |> assign(:sort_dir, :asc)
      |> assign(:sort_options, @sort_options)
      |> assign(:page, 1)
      |> assign(:page_size, @page_size)
      |> assign(:total_prompts, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {sort_by, sort_dir, page} = parse_sort_params(params)
    current_path = URI.parse(uri).path

    socket =
      socket
      |> assign(:sort_by, sort_by)
      |> assign(:sort_dir, sort_dir)
      |> assign(:page, page)
      |> assign(:current_path, current_path)
      |> reload_prompts()

    {:noreply, socket}
  end

  @valid_sort_fields Enum.map(@sort_options, fn {field, _} -> Atom.to_string(field) end)

  defp parse_sort_params(params) do
    {
      parse_sort_field(params["sort"], @valid_sort_fields, :sort_order),
      parse_sort_dir(params["dir"]),
      parse_page(params["page"])
    }
  end

  defp parse_sort_field(field, valid_fields, default) when is_binary(field) do
    if field in valid_fields, do: String.to_existing_atom(field), else: default
  end

  defp parse_sort_field(_, _valid_fields, default), do: default

  defp parse_sort_dir("asc"), do: :asc
  defp parse_sort_dir("desc"), do: :desc
  defp parse_sort_dir(_), do: :asc

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1

  defp parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

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

    # Reset to page 1 when sorting changes
    path = Routes.ai_path() <> "/prompts?sort=#{field}&dir=#{sort_dir}"
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("goto_page", %{"page" => page_str}, socket) do
    case Integer.parse(page_str) do
      {page, ""} when page > 0 ->
        sort_by = socket.assigns.sort_by
        sort_dir = socket.assigns.sort_dir

        path = build_prompts_url(sort_by, sort_dir, page)
        {:noreply, push_patch(socket, to: path)}

      _ ->
        {:noreply, socket}
    end
  end

  # ===========================================
  # PUBSUB HANDLERS - Real-time updates
  # ===========================================

  @impl true
  def handle_info({event, _prompt}, socket)
      when event in [:prompt_created, :prompt_updated, :prompt_deleted] do
    # Reload prompts list when any prompt changes
    {:noreply, reload_prompts(socket)}
  end

  # Catch-all for other PubSub messages
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ===========================================
  # PRIVATE HELPERS
  # ===========================================

  defp reload_prompts(socket) do
    sort_by = socket.assigns.sort_by
    sort_dir = socket.assigns.sort_dir
    page = socket.assigns.page
    page_size = socket.assigns.page_size

    {prompts, total} =
      AI.list_prompts(
        sort_by: sort_by,
        sort_dir: sort_dir,
        page: page,
        page_size: page_size
      )

    socket
    |> assign(:prompts, prompts)
    |> assign(:total_prompts, total)
  end

  defp build_prompts_url(sort_by, sort_dir, page) do
    base = Routes.ai_path() <> "/prompts?sort=#{sort_by}&dir=#{sort_dir}"

    if page > 1 do
      base <> "&page=#{page}"
    else
      base
    end
  end

  defp get_current_path(socket, session) do
    case socket.assigns do
      %{__changed__: _, current_path: path} when is_binary(path) -> path
      _ -> session["current_path"] || Routes.ai_path() <> "/prompts"
    end
  end
end
