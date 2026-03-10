defmodule PhoenixKit.Modules.Newsletters.Web.BroadcastEditor do
  @moduledoc """
  LiveView for creating and editing newsletter broadcasts with Markdown editor and live preview.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Newsletters
  alias PhoenixKit.Modules.Newsletters.Broadcaster
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Newsletters.enabled?() do
      project_title = Settings.get_project_title()
      lists = Newsletters.list_lists(%{status: "active"})
      templates = Templates.list_templates(%{status: "active"})

      default_template_uuid = Settings.get_setting("newsletters_default_template")

      socket =
        socket
        |> assign(:page_title, "New Broadcast")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/newsletters/broadcasts/new"))
        |> assign(:lists, lists)
        |> assign(:templates, templates)
        |> assign(:broadcast, nil)
        |> assign(:subject, "")
        |> assign(:list_uuid, "")
        |> assign(:template_uuid, default_template_uuid || "")
        |> assign(:markdown_content, "")
        |> assign(:preview_html, "")
        |> assign(:scheduled_at, "")
        |> assign(:saving, false)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Newsletters module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, %{assigns: %{live_action: :edit}} = socket) do
    broadcast = Newsletters.get_broadcast!(id)

    {:noreply,
     socket
     |> assign(:page_title, "Edit Broadcast")
     |> assign(:url_path, Routes.path("/admin/newsletters/broadcasts/#{id}/edit"))
     |> assign(:broadcast, broadcast)
     |> assign(:subject, broadcast.subject || "")
     |> assign(:list_uuid, broadcast.list_uuid || "")
     |> assign(:template_uuid, broadcast.template_uuid || "")
     |> assign(:markdown_content, broadcast.markdown_body || "")
     |> assign(
       :preview_html,
       render_preview(broadcast.markdown_body, broadcast.template_uuid, socket.assigns.templates)
     )}
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> put_flash(:error, "Broadcast not found")
       |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", params, socket) do
    subject = params["subject"] || socket.assigns.subject
    list_uuid = params["list_uuid"] || socket.assigns.list_uuid
    template_uuid = params["template_uuid"] || socket.assigns.template_uuid
    scheduled_at = params["scheduled_at"] || socket.assigns.scheduled_at

    preview_html =
      render_preview(socket.assigns.markdown_content, template_uuid, socket.assigns.templates)

    {:noreply,
     socket
     |> assign(:subject, subject)
     |> assign(:list_uuid, list_uuid)
     |> assign(:template_uuid, template_uuid)
     |> assign(:scheduled_at, scheduled_at)
     |> assign(:preview_html, preview_html)}
  end

  @impl true
  def handle_event("save_draft", params, socket) do
    socket = update_assigns_from_params(socket, params)
    save_broadcast(socket, "draft")
  end

  @impl true
  def handle_event("send_now", params, socket) do
    socket = update_assigns_from_params(socket, params)

    case save_broadcast_and_return(socket) do
      {:ok, broadcast} ->
        case Broadcaster.send(broadcast) do
          {:ok, _broadcast} ->
            {:noreply,
             socket
             |> put_flash(:info, "Broadcast is being sent")
             |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts/#{broadcast.uuid}"))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("schedule", params, socket) do
    socket = update_assigns_from_params(socket, params)

    case socket.assigns.scheduled_at do
      "" ->
        {:noreply, put_flash(socket, :error, "Please select a schedule date and time")}

      scheduled_at_str ->
        save_broadcast(socket, "scheduled", %{scheduled_at: parse_datetime(scheduled_at_str)})
    end
  end

  @impl true
  def handle_info({:editor_content_changed, %{content: content}}, socket) do
    preview_html = render_preview(content, socket.assigns.template_uuid, socket.assigns.templates)

    {:noreply,
     socket
     |> assign(:markdown_content, content)
     |> assign(:preview_html, preview_html)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp update_assigns_from_params(socket, params) do
    socket
    |> assign(:subject, params["subject"] || socket.assigns.subject)
    |> assign(:list_uuid, params["list_uuid"] || socket.assigns.list_uuid)
    |> assign(:template_uuid, params["template_uuid"] || socket.assigns.template_uuid)
    |> assign(:scheduled_at, params["scheduled_at"] || socket.assigns.scheduled_at)
  end

  defp save_broadcast(socket, status, extra_attrs \\ %{}) do
    socket = assign(socket, :saving, true)

    attrs =
      Map.merge(
        %{
          subject: socket.assigns.subject,
          list_uuid: socket.assigns.list_uuid,
          template_uuid:
            if(socket.assigns.template_uuid == "", do: nil, else: socket.assigns.template_uuid),
          markdown_body: socket.assigns.markdown_content,
          status: status
        },
        extra_attrs
      )

    result =
      case socket.assigns.broadcast do
        nil -> Newsletters.create_broadcast(attrs)
        broadcast -> Newsletters.update_broadcast(broadcast, attrs)
      end

    case result do
      {:ok, broadcast} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:broadcast, broadcast)
         |> put_flash(:info, "Broadcast saved as #{status}")
         |> push_navigate(to: Routes.path("/admin/newsletters/broadcasts"))}

      {:error, changeset} ->
        errors =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        {:noreply,
         socket
         |> assign(:saving, false)
         |> put_flash(:error, "Validation failed: #{errors}")}
    end
  end

  defp save_broadcast_and_return(socket) do
    attrs = %{
      subject: socket.assigns.subject,
      list_uuid: socket.assigns.list_uuid,
      template_uuid:
        if(socket.assigns.template_uuid == "", do: nil, else: socket.assigns.template_uuid),
      markdown_body: socket.assigns.markdown_content,
      status: "draft"
    }

    case socket.assigns.broadcast do
      nil -> Newsletters.create_broadcast(attrs)
      broadcast -> Newsletters.update_broadcast(broadcast, attrs)
    end
  end

  defp render_preview(markdown, template_uuid, templates) do
    case Earmark.as_html(markdown || "") do
      {:ok, html, _} ->
        inject_into_template(html, template_uuid, templates)

      _ ->
        ""
    end
  end

  defp inject_into_template(html, template_uuid, templates)
       when is_binary(template_uuid) and template_uuid != "" do
    case Enum.find(templates, fn t -> t.uuid == template_uuid end) do
      nil ->
        html

      template ->
        String.replace(template.html_body || "", "{{content}}", html)
    end
  end

  defp inject_into_template(html, _, _), do: html

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str <> ":00Z") do
      {:ok, dt, _} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(str <> ":00") do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp parse_datetime(_), do: nil
end
