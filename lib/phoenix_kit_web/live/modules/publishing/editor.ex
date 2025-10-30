defmodule PhoenixKitWeb.Live.Modules.Publishing.Editor do
  @moduledoc """
  Markdown editor for publishing entries.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitWeb.Live.Modules.Publishing
  alias PhoenixKitWeb.Live.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(%{"type" => type_slug} = params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Publishing Editor")
      |> assign(:type_slug, type_slug)

    {:ok, socket}
  end

  def handle_params(%{"new" => "true"}, _uri, socket) do
    type_slug = socket.assigns.type_slug
    all_enabled_languages = Storage.enabled_language_codes()
    primary_language = hd(all_enabled_languages)

    # Create a virtual entry structure for a new post
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> floor_datetime_to_minute()
    date = DateTime.to_date(now)
    time = DateTime.to_time(now)

    # Build the path where the file will be saved
    time_folder =
      "#{String.pad_leading(to_string(time.hour), 2, "0")}:#{String.pad_leading(to_string(time.minute), 2, "0")}"

    virtual_path =
      Path.join([type_slug, Date.to_iso8601(date), time_folder, "#{primary_language}.phk"])

    virtual_entry = %{
      type: type_slug,
      date: date,
      time: time,
      path: virtual_path,
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now)
      },
      content: "",
      language: primary_language,
      available_languages: []
    }

    socket =
      socket
      |> assign(:entry, virtual_entry)
      |> assign(:type_name, Publishing.type_name(type_slug) || type_slug)
      |> assign(:form, entry_form(virtual_entry))
      |> assign(:content, "")
      |> assign(:current_language, primary_language)
      |> assign(:available_languages, [])
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{type_slug}/edit",
          locale: socket.assigns.current_locale
        )
      )
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_entry, true)
      |> push_event("changes-status", %{has_changes: false})

    {:noreply, socket}
  end

  def handle_params(%{"path" => path} = params, _uri, socket) do
    type_slug = socket.assigns.type_slug

    case Publishing.read_entry(type_slug, path) do
      {:ok, entry} ->
        # Get all enabled languages to show in switcher
        all_enabled_languages = Storage.enabled_language_codes()

        # Check if we should switch to a different language
        switch_to_lang = Map.get(params, "switch_to")

        socket =
          if switch_to_lang && switch_to_lang not in entry.available_languages do
            # Create virtual entry for the new language
            new_path =
              path
              |> Path.dirname()
              |> Path.join("#{switch_to_lang}.phk")

            virtual_entry = %{
              entry
              | path: new_path,
                language: switch_to_lang,
                content: "",
                metadata: Map.put(entry.metadata, :title, "")
            }

            socket
            |> assign(:entry, virtual_entry)
            |> assign(:type_name, Publishing.type_name(type_slug) || type_slug)
            |> assign(:form, entry_form(virtual_entry))
            |> assign(:content, "")
            |> assign(:current_language, switch_to_lang)
            |> assign(:available_languages, entry.available_languages)
            |> assign(:all_enabled_languages, all_enabled_languages)
            |> assign(
              :current_path,
              Routes.path("/admin/publishing/#{type_slug}/edit",
                locale: socket.assigns.current_locale
              )
            )
            |> assign(:has_pending_changes, false)
            |> assign(:is_new_translation, true)
            |> assign(:original_entry_path, path)
            |> push_event("changes-status", %{has_changes: false})
          else
            socket
            |> assign(:entry, entry)
            |> assign(:type_name, Publishing.type_name(type_slug) || type_slug)
            |> assign(:form, entry_form(entry))
            |> assign(:content, entry.content)
            |> assign(:current_language, entry.language)
            |> assign(:available_languages, entry.available_languages)
            |> assign(:all_enabled_languages, all_enabled_languages)
            |> assign(
              :current_path,
              Routes.path("/admin/publishing/#{type_slug}/edit",
                locale: socket.assigns.current_locale
              )
            )
            |> assign(:has_pending_changes, false)
            |> push_event("changes-status", %{has_changes: false})
          end

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Entry not found"))
         |> push_navigate(
           to:
             Routes.path("/admin/publishing/#{type_slug}", locale: socket.assigns.current_locale)
         )}
    end
  end

  def handle_event("update_meta", params, socket) do
    params = Map.drop(params, ["_target"])

    new_form =
      socket.assigns.form
      |> Map.merge(params)
      |> normalize_form()

    has_changes = dirty?(socket.assigns.entry, new_form, socket.assigns.content)

    {:noreply,
     socket
     |> assign(:form, new_form)
     |> assign(:has_pending_changes, has_changes)
     |> push_event("changes-status", %{has_changes: has_changes})}
  end

  def handle_event("update_content", %{"content" => content}, socket) do
    has_changes = dirty?(socket.assigns.entry, socket.assigns.form, content)

    socket =
      socket
      |> assign(:content, content)
      |> assign(:has_pending_changes, has_changes)

    # Notify JavaScript hook about changes status
    {:noreply, push_event(socket, "changes-status", %{has_changes: has_changes})}
  end

  def handle_event("save", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    params =
      socket.assigns.form
      |> Map.take(["title", "status", "published_at"])
      |> Map.put("content", socket.assigns.content)

    is_new_entry = Map.get(socket.assigns, :is_new_entry, false)
    is_new_translation = Map.get(socket.assigns, :is_new_translation, false)

    cond do
      is_new_entry ->
        # Creating a completely new entry (from "Create Post" button)
        case Publishing.create_entry(socket.assigns.type_slug) do
          {:ok, new_entry} ->
            # Now update it with the user's content
            case Publishing.update_entry(socket.assigns.type_slug, new_entry, params) do
              {:ok, updated_entry} ->
                {:noreply,
                 socket
                 |> assign(:entry, updated_entry)
                 |> assign(:form, entry_form(updated_entry))
                 |> assign(:content, updated_entry.content)
                 |> assign(:available_languages, updated_entry.available_languages)
                 |> assign(:has_pending_changes, false)
                 |> assign(:is_new_entry, false)
                 |> push_event("changes-status", %{has_changes: false})
                 |> put_flash(:info, gettext("Entry created and saved"))
                 |> push_patch(
                   to:
                     Routes.path(
                       "/admin/publishing/#{socket.assigns.type_slug}/edit?path=#{URI.encode(updated_entry.path)}",
                       locale: socket.assigns.current_locale
                     )
                 )}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, gettext("Failed to save entry"))}
            end

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to create entry"))}
        end

      is_new_translation ->
        # Creating a new translation file
        original_path = Map.get(socket.assigns, :original_entry_path, socket.assigns.entry.path)

        case Publishing.add_language_to_entry(
               socket.assigns.type_slug,
               original_path,
               socket.assigns.current_language
             ) do
          {:ok, new_entry} ->
            # Now update it with the user's content
            case Publishing.update_entry(socket.assigns.type_slug, new_entry, params) do
              {:ok, updated_entry} ->
                {:noreply,
                 socket
                 |> assign(:entry, updated_entry)
                 |> assign(:form, entry_form(updated_entry))
                 |> assign(:content, updated_entry.content)
                 |> assign(:available_languages, updated_entry.available_languages)
                 |> assign(:has_pending_changes, false)
                 |> assign(:is_new_translation, false)
                 |> assign(:original_entry_path, nil)
                 |> push_event("changes-status", %{has_changes: false})
                 |> put_flash(:info, gettext("Translation created and saved"))
                 |> push_patch(
                   to:
                     Routes.path(
                       "/admin/publishing/#{socket.assigns.type_slug}/edit?path=#{URI.encode(updated_entry.path)}",
                       locale: socket.assigns.current_locale
                     )
                 )}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, gettext("Failed to save translation"))}
            end

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to create translation file"))}
        end

      true ->
        # Normal save for existing file
        case Publishing.update_entry(socket.assigns.type_slug, socket.assigns.entry, params) do
          {:ok, entry} ->
            {:noreply,
             socket
             |> assign(:entry, entry)
             |> assign(:form, entry_form(entry))
             |> assign(:content, entry.content)
             |> assign(:has_pending_changes, false)
             |> push_event("changes-status", %{has_changes: false})
             |> put_flash(:info, gettext("Entry saved"))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to save entry"))}
        end
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("preview", _params, socket) do
    # Simple preview - just navigate to preview page
    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/publishing/#{socket.assigns.type_slug}/preview?path=#{URI.encode(socket.assigns.entry.path)}",
           locale: socket.assigns.current_locale
         )
     )}
  end

  def handle_event("attempt_cancel", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    handle_event("cancel", %{}, socket)
  end

  def handle_event("attempt_cancel", _params, socket) do
    {:noreply, push_event(socket, "confirm-navigation", %{})}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> push_event("changes-status", %{has_changes: false})
     |> push_navigate(
       to:
         Routes.path("/admin/publishing/#{socket.assigns.type_slug}",
           locale: socket.assigns.current_locale
         )
     )}
  end

  def handle_event("back_to_list", _params, socket) do
    handle_event("attempt_cancel", %{}, socket)
  end

  def handle_event("switch_language", %{"language" => new_language}, socket) do
    entry = socket.assigns.entry
    type_slug = socket.assigns.type_slug

    # Build path with new language
    new_path =
      entry.path
      |> Path.dirname()
      |> Path.join("#{new_language}.phk")

    # Check if file exists
    file_exists = new_language in entry.available_languages

    if file_exists do
      # File exists, just switch to it
      {:noreply,
       push_patch(socket,
         to:
           Routes.path(
             "/admin/publishing/#{type_slug}/edit?path=#{URI.encode(new_path)}",
             locale: socket.assigns.current_locale
           )
       )}
    else
      # File doesn't exist - create a virtual entry for editing
      # It will be created when user saves
      virtual_entry = %{
        entry
        | path: new_path,
          language: new_language,
          content: "",
          metadata: Map.put(entry.metadata, :title, "")
      }

      socket =
        socket
        |> assign(:entry, virtual_entry)
        |> assign(:form, entry_form(virtual_entry))
        |> assign(:content, "")
        |> assign(:current_language, new_language)
        |> assign(:has_pending_changes, false)
        |> assign(:is_new_translation, true)
        |> assign(:original_entry_path, entry.path)
        |> push_event("changes-status", %{has_changes: false})

      {:noreply, socket}
    end
  end

  defp entry_form(entry) do
    %{
      "title" => entry.metadata.title || "",
      "status" => entry.metadata.status || "draft",
      "published_at" =>
        entry.metadata.published_at ||
          DateTime.utc_now()
          |> floor_datetime_to_minute()
          |> DateTime.to_iso8601()
    }
    |> normalize_form()
  end

  defp datetime_local_value(nil), do: ""

  defp datetime_local_value(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt
        |> floor_datetime_to_minute()
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()

      _ ->
        value
    end
  end

  defp floor_datetime_to_minute(%DateTime{} = datetime) do
    %DateTime{datetime | second: 0, microsecond: {0, 0}}
  end

  defp dirty?(entry, form, content) do
    normalized_form = normalize_form(form)
    normalized_form != entry_form(entry) || content != entry.content
  end

  defp normalize_form(form) when is_map(form) do
    %{
      "title" => Map.get(form, "title", "") || "",
      "status" => Map.get(form, "status", "draft") || "draft",
      "published_at" => normalize_published_at(Map.get(form, "published_at"))
    }
  end

  defp normalize_form(_), do: %{"title" => "", "status" => "draft", "published_at" => ""}

  defp normalize_published_at(nil), do: ""

  defp normalize_published_at(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        ""

      # Handle datetime-local input format (YYYY-MM-DDTHH:MM)
      String.length(trimmed) == 16 and String.contains?(trimmed, "T") ->
        trimmed <> ":00Z"

      # Parse and normalize ISO8601 datetime
      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, dt, _} ->
            dt
            |> floor_datetime_to_minute()
            |> DateTime.to_iso8601()

          _ ->
            trimmed
        end
    end
  end

  defp normalize_published_at(_), do: ""
end
