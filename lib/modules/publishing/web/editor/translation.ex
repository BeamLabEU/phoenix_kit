defmodule PhoenixKit.Modules.Publishing.Web.Editor.Translation do
  @moduledoc """
  AI translation functionality for the publishing editor.

  Handles translation workflow, Oban job enqueuing, and
  translation progress tracking.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.AI
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PresenceHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker
  alias PhoenixKit.Settings

  @translation_prompt_slug "translate-publishing-posts"

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
        # Use UUID for dropdown values (stable across systems, matches settings storage)
        {endpoints, _total} -> Enum.map(endpoints, &{&1.uuid, &1.name})
        endpoints when is_list(endpoints) -> Enum.map(endpoints, &{&1.uuid, &1.name})
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Lists available AI prompts for translation.
  """
  def list_ai_prompts do
    if AI.enabled?() do
      case AI.list_prompts(enabled: true) do
        {prompts, _total} -> Enum.map(prompts, &{&1.uuid, &1.name})
        prompts when is_list(prompts) -> Enum.map(prompts, &{&1.uuid, &1.name})
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Gets the default AI endpoint UUID from settings.
  """
  def get_default_ai_endpoint_uuid do
    case Settings.get_setting("publishing_translation_endpoint_uuid") do
      nil -> nil
      "" -> nil
      id -> id
    end
  end

  @doc """
  Gets the default AI prompt UUID for translation from settings.
  """
  def get_default_ai_prompt_uuid do
    case Settings.get_setting("publishing_translation_prompt_uuid") do
      nil -> fallback_prompt_uuid()
      "" -> fallback_prompt_uuid()
      id -> id
    end
  end

  defp fallback_prompt_uuid do
    if AI.enabled?() do
      case AI.get_prompt_by_slug(@translation_prompt_slug) do
        nil -> nil
        prompt -> prompt.uuid
      end
    else
      nil
    end
  end

  @doc """
  Checks if the default translation prompt already exists.
  """
  def default_translation_prompt_exists? do
    AI.enabled?() and AI.get_prompt_by_slug(@translation_prompt_slug) != nil
  end

  @doc """
  Generates the default translation prompt in the AI prompts system.
  Returns {:ok, prompt} or {:error, changeset}.
  """
  def generate_default_translation_prompt do
    attrs = %{
      name: "Translate Publishing Posts",
      description: "Default prompt for translating publishing posts between languages",
      content: """
      Translate the following content from {{SourceLanguage}} to {{TargetLanguage}}.

      RULES:
      - Preserve the EXACT formatting of the original (headings, line breaks, spacing, etc.)
      - If the original has a # heading, keep it. If it doesn't, don't add one.
      - Preserve all Markdown formatting (bold, italic, links, code blocks, lists)
      - Do NOT translate text inside code blocks or inline code
      - Translate naturally and idiomatically
      - Keep HTML tags and special syntax unchanged

      OUTPUT FORMAT - respond with ONLY this format, nothing else before or after:

      ---TITLE---
      [translated title - just the title text, no # symbol]
      ---SLUG---
      [url-friendly-slug-in-target-language]
      ---CONTENT---
      [translated content - preserve EXACT original formatting]

      SLUG RULES:
      - Lowercase letters only (a-z)
      - Numbers allowed (0-9)
      - Use hyphens (-) to separate words
      - No spaces, accents, or special characters
      - Keep it short and SEO-friendly
      - Example: "getting-started" -> "primeros-pasos" (Spanish)

      === SOURCE CONTENT ===

      Title: {{Title}}

      {{Content}}
      """
    }

    AI.create_prompt(attrs)
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
    primary_language = post[:primary_language] || Publishing.get_primary_language()
    available_languages = post.available_languages || []

    Publishing.enabled_language_codes()
    |> Enum.reject(&(&1 == primary_language or &1 in available_languages))
  end

  @doc """
  Gets all target languages for translation (all except primary).
  """
  def get_all_target_languages(socket) do
    post = socket.assigns.post
    # Use post's stored primary language to exclude from targets
    primary_language = post[:primary_language] || Publishing.get_primary_language()

    Publishing.enabled_language_codes()
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

      is_nil(socket.assigns.ai_selected_endpoint_uuid) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI endpoint"))}

      is_nil(socket.assigns[:ai_selected_prompt_uuid]) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI prompt"))}

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
    user_uuid = if user, do: user.user.uuid, else: nil
    post = socket.assigns.post

    # Get the source language from the post's stored primary_language
    source_language =
      post[:primary_language] ||
        socket.assigns[:current_language] ||
        Publishing.get_primary_language()

    case TranslatePostWorker.enqueue(
           socket.assigns.group_slug,
           post.uuid,
           endpoint_uuid: socket.assigns.ai_selected_endpoint_uuid,
           prompt_uuid: socket.assigns[:ai_selected_prompt_uuid],
           version: socket.assigns.current_version,
           user_uuid: user_uuid,
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
        info = Publishing.get_language_info(code)
        if info, do: info.name, else: code
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

    # Check if any target languages are currently being edited by other users
    active_editors = get_active_editors_for_languages(socket, target_languages)

    warnings =
      if active_editors != [] do
        editor_warnings =
          Enum.map(active_editors, fn {lang_code, editor_email} ->
            lang_name = get_language_display_name(lang_code)

            {:warning,
             gettext(
               "%{language} is currently being edited by %{user}. They will be locked out and unsaved changes will be discarded.",
               language: lang_name,
               user: editor_email
             )}
          end)

        editor_warnings ++ warnings
      else
        warnings
      end

    # Also check source language
    warnings = check_source_language_editor(socket, warnings)

    Enum.reverse(warnings)
  end

  defp get_active_editors_for_languages(socket, target_languages) do
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug

    Enum.flat_map(target_languages, fn lang_code ->
      form_key =
        PublishingPubSub.generate_form_key(group_slug, %{uuid: post.uuid, language: lang_code})

      case PresenceHelpers.get_lock_owner(form_key) do
        nil ->
          []

        owner_meta ->
          # Don't warn about ourselves
          current_user = socket.assigns[:phoenix_kit_current_scope]
          current_uuid = if current_user, do: current_user.user.uuid, else: nil

          if owner_meta.user_uuid != current_uuid do
            [{lang_code, owner_meta.user_email}]
          else
            []
          end
      end
    end)
  end

  @doc """
  Returns the source language for translation based on the post's primary language
  or the system default.
  """
  def source_language_for_translation(socket) do
    post = socket.assigns[:post]
    (post && post[:primary_language]) || Publishing.get_primary_language()
  end

  defp check_source_language_editor(socket, warnings) do
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug
    source_language = source_language_for_translation(socket)
    current_language = socket.assigns[:current_language]

    # If we're currently on the source language, we are the editor — no warning needed
    if current_language == source_language do
      warnings
    else
      form_key =
        PublishingPubSub.generate_form_key(group_slug, %{
          uuid: post.uuid,
          language: source_language
        })

      case PresenceHelpers.get_lock_owner(form_key) do
        nil ->
          warnings

        owner_meta ->
          current_user = socket.assigns[:phoenix_kit_current_scope]
          current_uuid = if current_user, do: current_user.user.uuid, else: nil

          if owner_meta.user_uuid != current_uuid do
            lang_name = get_language_display_name(source_language)

            [
              {:warning,
               gettext(
                 "%{language} (source) is currently being edited by %{user}. They will be locked out during translation.",
                 language: lang_name,
                 user: owner_meta.user_email
               )}
              | warnings
            ]
          else
            warnings
          end
      end
    end
  end

  defp get_language_display_name(lang_code) do
    case Publishing.get_language_info(lang_code) do
      %{name: name} -> name
      _ -> String.upcase(lang_code)
    end
  end

  defp get_existing_translation_languages(socket, target_languages) do
    post = socket.assigns.post
    available = post.available_languages || []

    Enum.filter(target_languages, fn lang -> lang in available end)
  end

  defp format_language_names(language_codes) do
    Enum.map_join(language_codes, ", ", fn code ->
      info = Publishing.get_language_info(code)
      if info, do: info.name, else: code
    end)
  end

  @doc """
  Checks if the source content is blank.
  """
  def source_content_blank?(socket) do
    post = socket.assigns.post

    source_language =
      post[:primary_language] ||
        socket.assigns[:current_language] ||
        Publishing.get_primary_language()

    current_version = socket.assigns[:current_version]

    # If we're on the primary language, check current content
    if socket.assigns[:current_language] == source_language do
      content = socket.assigns.content || ""
      String.trim(content) == ""
    else
      # Read the source language content from the database
      case Publishing.read_post_by_uuid(post.uuid, source_language, current_version) do
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

      is_nil(socket.assigns.ai_selected_endpoint_uuid) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI endpoint"))}

      is_nil(socket.assigns[:ai_selected_prompt_uuid]) ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, gettext("Please select an AI prompt"))}

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

  @doc """
  Restores translation status from an active Oban job if one exists for this post.
  Call on mount to survive page refreshes.
  """
  def maybe_restore_translation_status(socket) do
    post = socket.assigns[:post]

    if post && post[:uuid] do
      case TranslatePostWorker.active_job(post.uuid) do
        nil ->
          socket

        job ->
          target_languages = Map.get(job.args, "target_languages", [])
          source_language = Map.get(job.args, "source_language")
          current_lang = socket.assigns[:current_language]

          # Lock this editor if the current language is being translated or is the source
          should_lock =
            current_lang != nil and
              (current_lang == source_language or current_lang in target_languages)

          socket
          |> Phoenix.Component.assign(:ai_translation_status, :in_progress)
          |> Phoenix.Component.assign(:ai_translation_progress, 0)
          |> Phoenix.Component.assign(:ai_translation_total, length(target_languages))
          |> Phoenix.Component.assign(:ai_translation_languages, target_languages)
          |> Phoenix.Component.assign(:translation_locked?, should_lock)
      end
    else
      socket
    end
  end
end
