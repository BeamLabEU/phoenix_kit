defmodule PhoenixKit.Modules.Publishing.Web.Editor.Translation do
  @moduledoc """
  AI translation functionality for the publishing editor.

  Handles translation workflow, Oban job enqueuing, and
  translation progress tracking.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.AI
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker
  alias PhoenixKit.Settings

  # ============================================================================
  # Availability Checks
  # ============================================================================

  @doc """
  Checks if AI translation is available (AI module enabled + endpoints configured).
  """
  def ai_translation_available? do
    AI.enabled?() and list_ai_endpoints() != []
  end

  @doc """
  Lists available AI endpoints for translation.
  """
  def list_ai_endpoints do
    if AI.enabled?() do
      case AI.list_endpoints(enabled: true) do
        {endpoints, _total} -> Enum.map(endpoints, &{&1.id, &1.name})
        endpoints when is_list(endpoints) -> Enum.map(endpoints, &{&1.id, &1.name})
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Gets the default AI endpoint ID from settings.
  """
  def get_default_ai_endpoint_id do
    # endpoint_id is now a UUID string, no need to convert to integer
    case Settings.get_setting("publishing_translation_endpoint_id") do
      nil -> nil
      "" -> nil
      id -> id
    end
  end

  # ============================================================================
  # Target Language Resolution
  # ============================================================================

  @doc """
  Gets target languages for translation (missing languages only).
  """
  def get_target_languages_for_translation(socket) do
    post = socket.assigns.post
    # Use post's stored primary language for translation source
    primary_language = post[:primary_language] || Storage.get_primary_language()
    available_languages = post.available_languages || []

    Storage.enabled_language_codes()
    |> Enum.reject(&(&1 == primary_language or &1 in available_languages))
  end

  @doc """
  Gets all target languages for translation (all except primary).
  """
  def get_all_target_languages(socket) do
    post = socket.assigns.post
    # Use post's stored primary language to exclude from targets
    primary_language = post[:primary_language] || Storage.get_primary_language()

    Storage.enabled_language_codes()
    |> Enum.reject(&(&1 == primary_language))
  end

  # ============================================================================
  # Translation Enqueuing
  # ============================================================================

  @doc """
  Enqueues translation job with validation and warnings.
  Returns {:noreply, socket} for use in handle_event.
  """
  def enqueue_translation(socket, target_languages, {empty_level, empty_message}) do
    cond do
      socket.assigns.is_new_post ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Please save the post first before translating")
         )}

      is_nil(socket.assigns.ai_selected_endpoint_id) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI endpoint"))}

      target_languages == [] ->
        {:noreply, Phoenix.LiveView.put_flash(socket, empty_level, empty_message)}

      true ->
        # Build list of warnings for the confirmation modal
        warnings = build_translation_warnings(socket, target_languages)

        if warnings == [] do
          # No warnings - proceed directly
          do_enqueue_translation(socket, target_languages)
        else
          # Show confirmation modal with warnings
          {:noreply,
           socket
           |> Phoenix.Component.assign(:show_translation_confirm, true)
           |> Phoenix.Component.assign(:pending_translation_languages, target_languages)
           |> Phoenix.Component.assign(:translation_warnings, warnings)}
        end
    end
  end

  @doc """
  Actually enqueues the translation job (after confirmation if needed).
  """
  def do_enqueue_translation(socket, target_languages) do
    user = socket.assigns[:phoenix_kit_current_scope]
    user_id = if user, do: user.user.id, else: nil
    post = socket.assigns.post

    # Get the source language from the post's stored primary_language
    source_language =
      post[:primary_language] ||
        socket.assigns[:current_language] ||
        Storage.get_primary_language()

    # For timestamp mode, use date/time identifier; for slug mode, use slug
    post_identifier =
      case post.mode do
        :timestamp -> extract_timestamp_identifier(post.path)
        _ -> post.slug
      end

    case TranslatePostWorker.enqueue(
           socket.assigns.blog_slug,
           post_identifier,
           endpoint_id: socket.assigns.ai_selected_endpoint_id,
           version: socket.assigns.current_version,
           user_id: user_id,
           target_languages: target_languages,
           source_language: source_language
         ) do
      {:ok, %{conflict?: true}} ->
        # Job already exists for this post
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :info,
           gettext("A translation job is already running for this post")
         )}

      {:ok, _job} ->
        {:noreply, translation_success_socket(socket, target_languages)}

      {:error, _reason} ->
        {:noreply, translation_error_socket(socket)}
    end
  end

  defp translation_success_socket(socket, target_languages) do
    lang_names =
      Enum.map_join(target_languages, ", ", fn code ->
        info = Storage.get_language_info(code)
        info[:name] || code
      end)

    socket
    |> Phoenix.Component.assign(:ai_translation_status, :enqueued)
    |> Phoenix.LiveView.put_flash(
      :info,
      gettext("Translation job enqueued for: %{languages}", languages: lang_names)
    )
  end

  defp translation_error_socket(socket) do
    socket
    |> Phoenix.Component.assign(:ai_translation_status, :error)
    |> Phoenix.LiveView.put_flash(:error, gettext("Failed to enqueue translation job"))
  end

  # ============================================================================
  # Translation Warnings
  # ============================================================================

  @doc """
  Builds warnings for the translation confirmation modal.
  """
  def build_translation_warnings(socket, target_languages) do
    warnings = []

    # Check if source content is blank
    warnings =
      if source_content_blank?(socket) do
        [
          {:warning,
           gettext("The source content is empty. This will create empty translation files.")}
          | warnings
        ]
      else
        warnings
      end

    # Check if any target languages have existing content that will be overwritten
    existing_languages = get_existing_translation_languages(socket, target_languages)

    warnings =
      if existing_languages != [] do
        lang_names = format_language_names(existing_languages)

        [
          {:warning,
           gettext("This will overwrite existing content in: %{languages}",
             languages: lang_names
           )}
          | warnings
        ]
      else
        warnings
      end

    Enum.reverse(warnings)
  end

  defp get_existing_translation_languages(socket, target_languages) do
    post = socket.assigns.post
    available = post.available_languages || []

    Enum.filter(target_languages, fn lang -> lang in available end)
  end

  defp format_language_names(language_codes) do
    Enum.map_join(language_codes, ", ", fn code ->
      info = Storage.get_language_info(code)
      info[:name] || code
    end)
  end

  @doc """
  Checks if the source content is blank.
  """
  def source_content_blank?(socket) do
    post = socket.assigns.post
    blog_slug = socket.assigns.blog_slug

    source_language =
      post[:primary_language] ||
        socket.assigns[:current_language] ||
        Storage.get_primary_language()

    current_version = socket.assigns[:current_version]

    # If we're on the primary language, check current content
    if socket.assigns[:current_language] == source_language do
      content = socket.assigns.content || ""
      String.trim(content) == ""
    else
      # For timestamp mode, use date/time identifier; for slug mode, use slug
      post_identifier =
        case post.mode do
          :timestamp -> extract_timestamp_identifier(post.path)
          _ -> post.slug
        end

      # Read the source language content from disk
      case Publishing.read_post(blog_slug, post_identifier, source_language, current_version) do
        {:ok, source_post} ->
          content = source_post.content || ""
          String.trim(content) == ""

        {:error, _} ->
          # Can't read source - assume it's blank to be safe
          true
      end
    end
  end

  # ============================================================================
  # Translation to Current Language
  # ============================================================================

  @doc """
  Starts translation to the current (non-primary) language.
  """
  def start_translation_to_current(socket) do
    cond do
      socket.assigns.is_new_post ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Please save the post first before translating")
         )}

      is_nil(socket.assigns.ai_selected_endpoint_id) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI endpoint"))}

      true ->
        target_language = socket.assigns.current_language
        # Enqueue as Oban job with single target language
        enqueue_translation(socket, [target_language], {:info, nil})
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Clears completed translation status when switching languages.
  """
  def maybe_clear_completed_translation_status(socket) do
    if socket.assigns[:ai_translation_status] == :completed do
      socket
      |> Phoenix.Component.assign(:ai_translation_status, nil)
      |> Phoenix.Component.assign(:ai_translation_progress, nil)
      |> Phoenix.Component.assign(:ai_translation_total, nil)
      |> Phoenix.Component.assign(:ai_translation_languages, [])
    else
      socket
    end
  end

  # Extract timestamp identifier (YYYY-MM-DD/HH:MM) from a post path
  defp extract_timestamp_identifier(path) when is_binary(path) do
    parts = String.split(path, "/", trim: true)

    case parts do
      # Versioned: [blog, date, time, version, file]
      [_blog, date, time, _version, _file] ->
        "#{date}/#{time}"

      # Legacy: [blog, date, time, file]
      [_blog, date, time, _file] ->
        "#{date}/#{time}"

      _ ->
        nil
    end
  end

  defp extract_timestamp_identifier(_), do: nil
end
