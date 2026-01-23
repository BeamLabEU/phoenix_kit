defmodule PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker do
  @moduledoc """
  Oban worker for translating publishing posts to multiple languages using AI.

  This worker translates the primary language version of a post to all enabled
  languages (or a specified subset). Each language translation is processed
  sequentially to avoid overwhelming the AI endpoint.

  ## Usage

      # Translate to all enabled languages
      PhoenixKit.Modules.Publishing.translate_post_to_all_languages(
        "docs",
        "getting-started",
        endpoint_id: 1
      )

      # Or enqueue directly
      %{
        "group_slug" => "docs",
        "post_slug" => "getting-started",
        "endpoint_id" => 1
      }
      |> TranslatePostWorker.new()
      |> Oban.insert()

  ## Job Arguments

  - `group_slug` - The publishing group slug
  - `post_slug` - The post slug (for slug mode) or date/time path (for timestamp mode)
  - `endpoint_id` - AI endpoint ID to use for translation
  - `source_language` - Source language to translate from (optional, defaults to primary language)
  - `target_languages` - List of target languages (optional, defaults to all enabled except source)
  - `version` - Version number to translate (optional, defaults to latest/published)
  - `user_id` - User ID for audit trail (optional)

  ## Configuration

  Set the default AI endpoint for translations in Settings:

      PhoenixKit.Settings.update_setting("publishing_translation_endpoint_id", "1")

  """

  use Oban.Worker, queue: :default, max_attempts: 3

  # Suppress dialyzer warnings for pattern matches where dialyzer incorrectly infers
  # that {:ok, _} patterns can never match. The Publishing context functions do return
  # {:ok, _} on success. This cascades to all downstream helper functions.
  @dialyzer {:nowarn_function, do_translate: 7}
  @dialyzer {:nowarn_function, translate_to_languages: 5}
  @dialyzer {:nowarn_function, translate_single_language: 5}
  @dialyzer {:nowarn_function, save_translation: 8}
  @dialyzer {:nowarn_function, check_translation_exists: 4}
  @dialyzer {:nowarn_function, update_translation: 6}
  @dialyzer {:nowarn_function, create_translation: 8}
  @dialyzer {:nowarn_function, extract_title: 1}
  @dialyzer {:nowarn_function, build_translation_prompt: 4}
  @dialyzer {:nowarn_function, parse_translated_response: 1}
  @dialyzer {:nowarn_function, sanitize_slug: 1}
  @dialyzer {:nowarn_function, parse_markdown_response: 1}
  @dialyzer {:nowarn_function, build_scope: 1}

  require Logger

  alias PhoenixKit.Modules.AI
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    group_slug = Map.fetch!(args, "group_slug")
    post_slug = Map.fetch!(args, "post_slug")
    endpoint_id = Map.get(args, "endpoint_id") || get_default_endpoint_id()
    source_language = Map.get(args, "source_language") || Storage.get_primary_language()
    target_languages = Map.get(args, "target_languages") || get_target_languages(source_language)
    version = Map.get(args, "version")
    user_id = Map.get(args, "user_id")

    Logger.info(
      "[TranslatePostWorker] Starting translation of #{group_slug}/#{post_slug} " <>
        "from #{source_language} to #{length(target_languages)} languages"
    )

    # Validate AI module is enabled
    if AI.enabled?() do
      # Validate endpoint exists and is enabled
      do_translate(
        group_slug,
        post_slug,
        endpoint_id,
        source_language,
        target_languages,
        version,
        user_id
      )
    else
      Logger.error("[TranslatePostWorker] AI module is not enabled")
      {:error, "AI module is not enabled"}
    end
  end

  defp do_translate(
         group_slug,
         post_slug,
         endpoint_id,
         source_language,
         target_languages,
         version,
         user_id
       ) do
    case AI.get_endpoint(endpoint_id) do
      nil ->
        Logger.error("[TranslatePostWorker] AI endpoint #{endpoint_id} not found")
        {:error, "AI endpoint not found"}

      %{enabled: false} ->
        Logger.error("[TranslatePostWorker] AI endpoint #{endpoint_id} is disabled")
        {:error, "AI endpoint is disabled"}

      endpoint ->
        # Read the source post
        case Publishing.read_post(group_slug, post_slug, source_language, version) do
          {:ok, source_post} ->
            translate_to_languages(
              source_post,
              target_languages,
              endpoint,
              source_language,
              user_id
            )

          {:error, reason} ->
            Logger.error("[TranslatePostWorker] Failed to read source post: #{inspect(reason)}")

            {:error, "Failed to read source post: #{inspect(reason)}"}
        end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  # Translate to all target languages sequentially
  defp translate_to_languages(source_post, target_languages, endpoint, source_language, user_id) do
    group_slug = source_post.group
    post_slug = source_post.slug

    # Broadcast that translation has started
    PublishingPubSub.broadcast_translation_started(group_slug, post_slug, target_languages)

    results =
      target_languages
      |> Enum.map(fn target_language ->
        # Note: Per-language progress broadcasts were removed as nothing subscribes to them.
        # The blog listing uses translation_started/completed events on posts_topic instead.
        case translate_single_language(
               source_post,
               target_language,
               endpoint,
               source_language,
               user_id
             ) do
          :ok ->
            Logger.info("[TranslatePostWorker] Successfully translated to #{target_language}")
            {:ok, target_language}

          {:error, reason} ->
            Logger.warning(
              "[TranslatePostWorker] Failed to translate to #{target_language}: #{inspect(reason)}"
            )

            {:error, target_language, reason}
        end
      end)

    # Count successes and failures
    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    success_count = length(successes)
    failure_count = length(failures)

    # Broadcast completion
    PublishingPubSub.broadcast_translation_completed(group_slug, post_slug, %{
      succeeded: Enum.map(successes, fn {:ok, lang} -> lang end),
      failed: Enum.map(failures, fn {:error, lang, _} -> lang end),
      success_count: success_count,
      failure_count: failure_count
    })

    Logger.info(
      "[TranslatePostWorker] Completed: #{success_count} succeeded, #{failure_count} failed"
    )

    if failure_count > 0 do
      failed_langs = Enum.map(failures, fn {:error, lang, _} -> lang end)

      {:error,
       "Translation failed for #{failure_count} languages: #{Enum.join(failed_langs, ", ")}"}
    else
      :ok
    end
  end

  # Translate a single language
  defp translate_single_language(source_post, target_language, endpoint, source_language, user_id) do
    group_slug = source_post.group
    post_slug = source_post.slug
    version = source_post.version

    # Get language names for the prompt
    source_lang_info = Storage.get_language_info(source_language)
    target_lang_info = Storage.get_language_info(target_language)

    source_lang_name = source_lang_info[:name] || source_language
    target_lang_name = target_lang_info[:name] || target_language

    Logger.info(
      "[TranslatePostWorker] Translating to #{target_language} (#{target_lang_name})..."
    )

    # Extract title and content from source post
    source_title = extract_title(source_post)
    source_content = source_post.content || ""

    # Build the translation prompt
    prompt =
      build_translation_prompt(source_title, source_content, source_lang_name, target_lang_name)

    # Call AI for translation
    Logger.debug(
      "[TranslatePostWorker] Calling AI endpoint #{endpoint.id} for #{target_language}..."
    )

    start_time = System.monotonic_time(:millisecond)

    result = AI.ask(endpoint.id, prompt, source: "Publishing.TranslatePostWorker")

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("[TranslatePostWorker] AI call for #{target_language} completed in #{elapsed}ms")

    case result do
      {:ok, response} ->
        case AI.extract_content(response) do
          {:ok, translated_text} ->
            # Parse the translated title, slug, and content
            {translated_title, translated_slug, translated_content} =
              parse_translated_response(translated_text)

            if translated_slug do
              Logger.info(
                "[TranslatePostWorker] Got translated slug for #{target_language}: #{translated_slug}"
              )
            end

            # Create or update the translation
            save_translation(
              group_slug,
              post_slug,
              target_language,
              translated_title,
              translated_slug,
              translated_content,
              version,
              user_id
            )

          {:error, reason} ->
            {:error, "Failed to extract AI response: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "AI request failed: #{inspect(reason)}"}
    end
  end

  # Extract title from post (first # heading or metadata title)
  defp extract_title(post) do
    content = post.content || ""

    case Regex.run(~r/^#\s+(.+)$/m, content) do
      [_, title] -> String.trim(title)
      nil -> Map.get(post.metadata || %{}, :title, "Untitled")
    end
  end

  # Build the translation prompt
  defp build_translation_prompt(title, content, source_lang, target_lang) do
    """
    Translate the following content from #{source_lang} to #{target_lang}.

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

    Title: #{title}

    #{content}
    """
  end

  # Parse the translated response to extract title, slug, and content
  # Returns {title, slug, content} tuple
  defp parse_translated_response(response) do
    # Try to parse the structured format with slug
    case Regex.run(
           ~r/---TITLE---\s*\n(.+?)\n---SLUG---\s*\n(.+?)\n---CONTENT---\s*\n(.+)/s,
           response
         ) do
      [_, title, slug, content] ->
        # Found full structured format with slug
        {String.trim(title), sanitize_slug(slug), String.trim(content)}

      nil ->
        # Try format without slug
        case Regex.run(~r/---TITLE---\s*\n(.+?)\n---CONTENT---\s*\n(.+)/s, response) do
          [_, title, content] ->
            {String.trim(title), nil, String.trim(content)}

          nil ->
            # No structured format found - try to extract from markdown
            {title, content} = parse_markdown_response(response)
            {title, nil, content}
        end
    end
  end

  # Sanitize and validate the translated slug
  defp sanitize_slug(slug) do
    sanitized =
      slug
      |> String.trim()
      |> String.downcase()
      # Replace invalid chars with hyphens
      |> String.replace(~r/[^a-z0-9-]/, "-")
      # Collapse multiple hyphens
      |> String.replace(~r/-+/, "-")
      # Remove leading/trailing hyphens
      |> String.replace(~r/^-|-$/, "")

    if sanitized == "" or String.length(sanitized) < 2 do
      # Invalid slug, don't use it
      nil
    else
      sanitized
    end
  end

  # Parse a response that's just markdown (no markers)
  defp parse_markdown_response(response) do
    # Clean up the response - remove any stray marker text that might have been partially output
    cleaned =
      response
      |> String.replace(~r/---TITLE---.*$/s, "")
      |> String.replace(~r/---SLUG---.*$/s, "")
      |> String.replace(~r/---CONTENT---.*$/s, "")
      |> String.trim()

    # Try to find a markdown heading as the title
    case Regex.run(~r/^#\s+(.+)$/m, cleaned) do
      [full_heading, title] ->
        # Remove the heading from content since we'll add it back
        content = String.replace(cleaned, full_heading, "", global: false) |> String.trim()
        {String.trim(title), content}

      nil ->
        # No heading found - treat first line as title
        case String.split(cleaned, "\n", parts: 2) do
          [first_line, rest] ->
            {String.trim(first_line), String.trim(rest)}

          [only_line] ->
            {String.trim(only_line), ""}
        end
    end
  end

  # Save the translation (create or update)
  defp save_translation(
         group_slug,
         post_slug,
         language,
         title,
         url_slug,
         content,
         version,
         user_id
       ) do
    Logger.info("[TranslatePostWorker] Saving translation for #{language}...")

    # Check if translation file already exists for this exact language
    # We need to check if the file exists directly because read_post has fallback behavior
    # that returns a different language if the requested one doesn't exist
    case check_translation_exists(group_slug, post_slug, language, version) do
      {:ok, existing_post} ->
        # Update existing translation - verify it's actually the right language
        if existing_post.language == language do
          Logger.info("[TranslatePostWorker] Updating existing #{language} translation")
          update_translation(group_slug, existing_post, title, url_slug, content, user_id)
        else
          # Fallback returned wrong language, create new translation instead
          Logger.info(
            "[TranslatePostWorker] Creating new #{language} translation (fallback detected)"
          )

          create_translation(
            group_slug,
            post_slug,
            language,
            title,
            url_slug,
            content,
            version,
            user_id
          )
        end

      {:error, _} ->
        # Create new translation
        Logger.info("[TranslatePostWorker] Creating new #{language} translation")

        create_translation(
          group_slug,
          post_slug,
          language,
          title,
          url_slug,
          content,
          version,
          user_id
        )
    end
  end

  # Check if a translation exists for the exact language (no fallback)
  defp check_translation_exists(group_slug, post_slug, language, version) do
    # Try to read the post and verify the language matches
    case Publishing.read_post(group_slug, post_slug, language, version) do
      {:ok, post} ->
        # Verify the returned post is actually for the requested language
        if post.language == language do
          {:ok, post}
        else
          {:error, :wrong_language}
        end

      error ->
        error
    end
  end

  defp update_translation(group_slug, existing_post, title, url_slug, content, user_id) do
    params = %{
      "title" => title,
      "content" => content
    }

    # Add url_slug if provided
    params = if url_slug, do: Map.put(params, "url_slug", url_slug), else: params

    scope = build_scope(user_id)

    case Publishing.update_post(group_slug, existing_post, params, scope: scope) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_translation(
         group_slug,
         post_slug,
         language,
         title,
         url_slug,
         content,
         version,
         user_id
       ) do
    case Publishing.add_language_to_post(group_slug, post_slug, language, version) do
      {:ok, new_post} ->
        params = %{
          "title" => title,
          "content" => content
        }

        # Add url_slug if provided
        params = if url_slug, do: Map.put(params, "url_slug", url_slug), else: params

        scope = build_scope(user_id)

        case Publishing.update_post(group_slug, new_post, params, scope: scope) do
          {:ok, _} ->
            Logger.info(
              "[TranslatePostWorker] Successfully saved #{language} translation with slug: #{url_slug || "(default)"}"
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "[TranslatePostWorker] Failed to update new #{language} translation: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "[TranslatePostWorker] Failed to create #{language} translation: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Build scope for audit trail
  defp build_scope(nil), do: nil

  defp build_scope(user_id) do
    case Auth.get_user(user_id) do
      nil -> nil
      user -> Scope.for_user(user)
    end
  end

  # Get target languages (all enabled except source)
  defp get_target_languages(source_language) do
    Storage.enabled_language_codes()
    |> Enum.reject(&(&1 == source_language))
  end

  # Get default endpoint ID from settings
  defp get_default_endpoint_id do
    case Settings.get_setting("publishing_translation_endpoint_id") do
      nil -> nil
      "" -> nil
      id -> String.to_integer(id)
    end
  end

  @doc """
  Creates a new translation job for a post.

  ## Options

  - `:endpoint_id` - AI endpoint ID (required if not set in settings)
  - `:source_language` - Source language (defaults to primary language)
  - `:target_languages` - List of target languages (defaults to all enabled except source)
  - `:version` - Version to translate (defaults to latest)
  - `:user_id` - User ID for audit trail

  ## Examples

      TranslatePostWorker.create_job("docs", "getting-started", endpoint_id: 1)
      TranslatePostWorker.create_job("docs", "getting-started",
        endpoint_id: 1,
        target_languages: ["es", "fr"]
      )

  """
  def create_job(group_slug, post_slug, opts \\ []) do
    args =
      %{
        "group_slug" => group_slug,
        "post_slug" => post_slug
      }
      |> maybe_put("endpoint_id", Keyword.get(opts, :endpoint_id))
      |> maybe_put("source_language", Keyword.get(opts, :source_language))
      |> maybe_put("target_languages", Keyword.get(opts, :target_languages))
      |> maybe_put("version", Keyword.get(opts, :version))
      |> maybe_put("user_id", Keyword.get(opts, :user_id))

    new(args)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Enqueues a translation job for a post.

  See `create_job/3` for options.

  ## Examples

      {:ok, job} = TranslatePostWorker.enqueue("docs", "getting-started", endpoint_id: 1)

  """
  def enqueue(group_slug, post_slug, opts \\ []) do
    group_slug
    |> create_job(post_slug, opts)
    |> Oban.insert()
  end
end
