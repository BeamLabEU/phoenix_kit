defmodule PhoenixKit.Modules.Publishing.Web.Editor.Forms do
  @moduledoc """
  Form building and management for the publishing editor.

  Handles form construction, normalization, slug tracking,
  and form state management.
  """

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Utils.Slug

  # ============================================================================
  # Form Building
  # ============================================================================

  @doc """
  Builds a form map from a post.
  """
  def post_form(post) do
    base_form(post)
    |> add_slug_field_if_needed(post)
    |> normalize_form()
  end

  @doc """
  Build form for a post, handling new translations appropriately.

  For new translations (no file on disk yet), inherits status from the primary language.
  For existing files, uses the file's own status to avoid confusion between
  what the dropdown shows and what the language switcher shows.
  """
  def post_form_with_primary_status(group_slug, post, version) do
    form = post_form(post)
    primary_language = post[:primary_language] || Storage.get_primary_language()
    original_language = post[:original_language] || post.language
    is_new_translation = Map.get(post, :is_new_translation, false)

    # If primary language OR existing translation (not new), use own status
    if original_language == primary_language or not is_new_translation do
      form
    else
      # For NEW translations only, inherit status from primary language as a default
      # Use appropriate identifier based on post mode
      post_identifier = get_post_identifier(post)

      case Publishing.read_post(group_slug, post_identifier, primary_language, version) do
        {:ok, primary_post} ->
          primary_status = Map.get(primary_post.metadata, :status, "draft")
          Map.put(form, "status", primary_status)

        {:error, _} ->
          form
      end
    end
  end

  # Get the correct post identifier based on mode
  # For timestamp mode: extract date/time from path (e.g., "2025-12-31/03:42")
  # For slug mode: use the post slug
  defp get_post_identifier(post) do
    case Map.get(post, :mode) do
      :timestamp -> extract_timestamp_identifier(post.path)
      _ -> post.slug
    end
  end

  # Extract timestamp identifier (date/time) from a timestamp mode path
  defp extract_timestamp_identifier(path) when is_binary(path) do
    case Regex.run(~r/(\d{4}-\d{2}-\d{2}\/\d{2}:\d{2})/, path) do
      [_, timestamp] -> timestamp
      nil -> path
    end
  end

  defp extract_timestamp_identifier(path), do: path

  defp base_form(post) do
    %{
      "title" => get_title_for_form(post),
      "status" => post.metadata.status || "draft",
      "published_at" => get_published_at(post),
      "featured_image_id" => Map.get(post.metadata, :featured_image_id, ""),
      "url_slug" => get_url_slug_for_form(post)
    }
  end

  defp get_title_for_form(post) do
    title = Map.get(post.metadata, :title) || Map.get(post.metadata, "title") || ""
    if title == "Untitled", do: "", else: title
  end

  defp get_published_at(post) do
    post.metadata.published_at ||
      DateTime.utc_now()
      |> floor_datetime_to_minute()
      |> DateTime.to_iso8601()
  end

  defp get_url_slug_for_form(post) do
    url_slug_from_metadata = Map.get(post.metadata, :url_slug)
    url_slug_from_post = Map.get(post, :url_slug)

    cond do
      url_slug_from_metadata not in [nil, ""] ->
        url_slug_from_metadata

      url_slug_from_post not in [nil, ""] and url_slug_from_post != post.slug ->
        url_slug_from_post

      true ->
        ""
    end
  end

  defp add_slug_field_if_needed(form, post) do
    case get_post_mode(post) do
      :slug -> Map.put(form, "slug", get_post_slug(post))
      _ -> form
    end
  end

  defp get_post_mode(post) do
    Map.get(post, :mode) || Map.get(post, "mode")
  end

  defp get_post_slug(post) do
    post.slug || post["slug"] || Map.get(post.metadata, :slug) || ""
  end

  # ============================================================================
  # Form Normalization
  # ============================================================================

  @doc """
  Normalizes a form map to ensure consistent values.
  """
  def normalize_form(form) when is_map(form) do
    # Normalize title: trim only (preserve case)
    title =
      form
      |> Map.get("title", "")
      |> to_string()
      |> String.trim()

    featured_image_id =
      form
      |> Map.get("featured_image_id", "")
      |> to_string()
      |> String.trim()

    # Normalize url_slug: trim and downcase, empty string if nil
    url_slug =
      form
      |> Map.get("url_slug", "")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    base =
      %{
        "title" => title,
        "status" => Map.get(form, "status", "draft") || "draft",
        "published_at" => normalize_published_at(Map.get(form, "published_at")),
        "featured_image_id" => featured_image_id,
        "url_slug" => url_slug
      }

    case Map.fetch(form, "slug") do
      {:ok, slug} ->
        # Normalize slug: trim and downcase to match validation requirements
        normalized_slug = slug |> to_string() |> String.trim() |> String.downcase()
        Map.put(base, "slug", normalized_slug)

      :error ->
        base
    end
  end

  def normalize_form(_),
    do: %{
      "title" => "",
      "status" => "draft",
      "published_at" => "",
      "slug" => "",
      "featured_image_id" => "",
      "url_slug" => ""
    }

  defp normalize_published_at(nil), do: ""

  defp normalize_published_at(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        ""

      String.length(trimmed) == 16 and String.contains?(trimmed, "T") ->
        trimmed <> ":00Z"

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

  # ============================================================================
  # Form Tracking
  # ============================================================================

  @doc """
  Assigns form with tracking for slug auto-generation.
  """
  def assign_form_with_tracking(socket, form, opts \\ []) do
    {slug_manually_set, last_auto_slug} = resolve_slug_tracking(socket, form, opts)
    {url_slug_manually_set, last_auto_url_slug} = resolve_url_slug_tracking(socket, form, opts)
    {title_manually_set, last_auto_title} = resolve_title_tracking(socket, form, opts)

    socket
    |> Phoenix.Component.assign(:form, form)
    |> Phoenix.Component.assign(:last_auto_slug, last_auto_slug)
    |> Phoenix.Component.assign(:slug_manually_set, slug_manually_set)
    |> Phoenix.Component.assign(:last_auto_url_slug, last_auto_url_slug)
    |> Phoenix.Component.assign(:url_slug_manually_set, url_slug_manually_set)
    |> Phoenix.Component.assign(:last_auto_title, last_auto_title)
    |> Phoenix.Component.assign(:title_manually_set, title_manually_set)
  end

  defp resolve_slug_tracking(socket, form, opts) do
    slug = Map.get(form, "slug", "")

    manually_set =
      case Keyword.fetch(opts, :slug_manually_set) do
        {:ok, value} -> value
        :error -> Map.get(socket.assigns, :slug_manually_set, false)
      end

    last_auto =
      case Keyword.fetch(opts, :last_auto_slug) do
        {:ok, value} -> value
        :error -> slug
      end

    {manually_set, last_auto}
  end

  defp resolve_url_slug_tracking(socket, form, opts) do
    url_slug = Map.get(form, "url_slug", "")
    post_slug = Map.get(socket.assigns.post || %{}, :slug, "")

    manually_set =
      case Keyword.fetch(opts, :url_slug_manually_set) do
        {:ok, value} ->
          value

        :error ->
          existing = Map.get(socket.assigns, :url_slug_manually_set, false)
          existing || (url_slug != "" and url_slug != post_slug)
      end

    last_auto =
      case Keyword.fetch(opts, :last_auto_url_slug) do
        {:ok, value} -> value
        :error -> Map.get(socket.assigns, :last_auto_url_slug, "")
      end

    {manually_set, last_auto}
  end

  defp resolve_title_tracking(socket, form, opts) do
    manually_set =
      case Keyword.fetch(opts, :title_manually_set) do
        {:ok, value} ->
          value

        :error ->
          existing = Map.get(socket.assigns, :title_manually_set, false)
          title = Map.get(form, "title", "")
          last_auto = Map.get(socket.assigns, :last_auto_title, "")
          existing || (title != "" and last_auto != "" and title != last_auto)
      end

    last_auto =
      case Keyword.fetch(opts, :last_auto_title) do
        {:ok, value} -> value
        :error -> Map.get(socket.assigns, :last_auto_title, "")
      end

    {manually_set, last_auto}
  end

  # ============================================================================
  # Slug Auto-Generation
  # ============================================================================

  @doc """
  Updates slug from content if applicable.
  Returns {socket, new_form, slug_events}.
  """
  def maybe_update_slug_from_content(socket, content, opts \\ []) do
    content = content || ""

    cond do
      not slug_update_applicable?(socket, content) ->
        no_slug_update(socket)

      Map.get(socket.assigns, :is_primary_language, true) ->
        maybe_update_primary_slug(socket, content, opts)

      true ->
        maybe_update_translation_url_slug(socket, content, opts)
    end
  end

  defp slug_update_applicable?(socket, content) do
    socket.assigns.group_mode == "slug" and String.trim(content) != ""
  end

  defp maybe_update_primary_slug(socket, content, opts) do
    force? = Keyword.get(opts, :force, false)
    slug_manually_set? = Map.get(socket.assigns, :slug_manually_set, false)

    if not force? and slug_manually_set? do
      no_slug_update(socket)
    else
      update_slug_from_content(socket, content)
    end
  end

  defp maybe_update_translation_url_slug(socket, content, opts) do
    force? = Keyword.get(opts, :force, false)
    url_slug_manually_set? = Map.get(socket.assigns, :url_slug_manually_set, false)

    if not force? and url_slug_manually_set? do
      no_slug_update(socket)
    else
      update_url_slug_from_content(socket, content)
    end
  end

  defp no_slug_update(socket), do: {socket, socket.assigns.form, []}

  defp update_slug_from_content(socket, content) do
    title = Metadata.extract_title_from_content(content)
    current_slug = socket.assigns.post.slug || Map.get(socket.assigns.form, "slug", "")

    case Storage.generate_unique_slug(socket.assigns.group_slug, title, nil,
           current_slug: current_slug
         ) do
      {:ok, ""} ->
        no_slug_update(socket)

      {:ok, new_slug} ->
        apply_new_slug(socket, new_slug)

      {:error, _reason} ->
        no_slug_update(socket)
    end
  end

  defp update_url_slug_from_content(socket, content) do
    title = Metadata.extract_title_from_content(content)
    current_url_slug = Map.get(socket.assigns.form, "url_slug", "")

    # Generate a slug from the title
    new_url_slug = Slug.slugify(title)

    if new_url_slug == "" do
      no_slug_update(socket)
    else
      apply_new_url_slug(socket, new_url_slug, current_url_slug)
    end
  end

  defp apply_new_slug(socket, new_slug) do
    current_slug = Map.get(socket.assigns.form, "slug", "")

    if new_slug != current_slug do
      form =
        socket.assigns.form
        |> Map.put("slug", new_slug)
        |> normalize_form()

      socket =
        socket
        |> Phoenix.Component.assign(:last_auto_slug, new_slug)
        |> Phoenix.Component.assign(:slug_manually_set, false)

      {socket, form, [{"update-slug", %{slug: new_slug}}]}
    else
      socket =
        socket
        |> Phoenix.Component.assign(:last_auto_slug, new_slug)
        |> Phoenix.Component.assign(:slug_manually_set, false)

      {socket, socket.assigns.form, []}
    end
  end

  defp apply_new_url_slug(socket, new_url_slug, current_url_slug) do
    if new_url_slug != current_url_slug do
      form =
        socket.assigns.form
        |> Map.put("url_slug", new_url_slug)
        |> normalize_form()

      socket =
        socket
        |> Phoenix.Component.assign(:last_auto_url_slug, new_url_slug)
        |> Phoenix.Component.assign(:url_slug_manually_set, false)

      {socket, form, [{"update-url-slug", %{url_slug: new_url_slug}}]}
    else
      socket =
        socket
        |> Phoenix.Component.assign(:last_auto_url_slug, new_url_slug)
        |> Phoenix.Component.assign(:url_slug_manually_set, false)

      {socket, socket.assigns.form, []}
    end
  end

  # ============================================================================
  # Title Auto-Generation
  # ============================================================================

  @doc """
  Updates the title from content if not manually set.
  Returns {socket, form, events}.
  """
  def maybe_update_title_from_content(socket, content) do
    content = content || ""
    title_manually_set? = Map.get(socket.assigns, :title_manually_set, false)

    if title_manually_set? do
      {socket, socket.assigns.form, []}
    else
      extracted = Metadata.extract_title_from_content(content)
      new_title = if extracted == "Untitled", do: "", else: extracted
      current_title = Map.get(socket.assigns.form, "title", "")

      if new_title != "" and new_title != current_title do
        form = Map.put(socket.assigns.form, "title", new_title)

        socket =
          socket
          |> Phoenix.Component.assign(:last_auto_title, new_title)
          |> Phoenix.Component.assign(:title_manually_set, false)

        {socket, form, [{"update-title", %{title: new_title}}]}
      else
        socket =
          if new_title != "" do
            Phoenix.Component.assign(socket, :last_auto_title, new_title)
          else
            socket
          end

        {socket, socket.assigns.form, []}
      end
    end
  end

  @doc """
  Preserve auto-generated title when browser sends empty value.
  """
  def preserve_auto_title(params, socket) do
    browser_title = Map.get(params, "title", "")
    last_auto = Map.get(socket.assigns, :last_auto_title, "")
    manually_set = Map.get(socket.assigns, :title_manually_set, false)

    if browser_title == "" and last_auto != "" and not manually_set do
      Map.put(params, "title", last_auto)
    else
      params
    end
  end

  @doc """
  Detects whether the user manually set the title field.
  Returns {form, title_manually_set}.
  """
  def detect_title_manual_set(params, form, socket) do
    if Map.has_key?(params, "title") do
      title_value = Map.get(form, "title", "")

      if title_value != "" do
        manually_set = title_value != Map.get(socket.assigns, :last_auto_title, "")
        {form, manually_set}
      else
        # User cleared title — revert to auto from H1
        revert_title_to_auto(form, socket)
      end
    else
      {form, Map.get(socket.assigns, :title_manually_set, false)}
    end
  end

  @doc """
  Reverts the title to the auto-extracted H1 heading.
  Returns {form, false}.
  """
  def revert_title_to_auto(form, socket) do
    extracted = Metadata.extract_title_from_content(socket.assigns.content || "")
    auto_title = if extracted == "Untitled", do: "", else: extracted

    if auto_title != "" do
      {Map.put(form, "title", auto_title), false}
    else
      {form, false}
    end
  end

  @doc """
  Preserve auto-generated url_slug when browser sends empty value.
  """
  def preserve_auto_url_slug(params, socket) do
    browser_url_slug = Map.get(params, "url_slug", "")
    last_auto = Map.get(socket.assigns, :last_auto_url_slug, "")
    manually_set = Map.get(socket.assigns, :url_slug_manually_set, false)

    if browser_url_slug == "" and last_auto != "" and not manually_set do
      Map.put(params, "url_slug", last_auto)
    else
      params
    end
  end

  @doc """
  Push slug events to the client.
  """
  def push_slug_events(socket, events) do
    Enum.reduce(events, socket, fn {event, data}, acc ->
      Phoenix.LiveView.push_event(acc, event, data)
    end)
  end

  # ============================================================================
  # Change Detection
  # ============================================================================

  @doc """
  Checks if the form has changes compared to the original post.
  """
  def dirty?(post, form, content) do
    normalized_form = normalize_form(form)
    normalized_form != post_form(post) || content != post.content
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Floors a DateTime to the minute (sets seconds and microseconds to 0).
  """
  def floor_datetime_to_minute(%DateTime{} = datetime) do
    %DateTime{datetime | second: 0, microsecond: {0, 0}}
  end

  @doc """
  Converts a published_at value to datetime-local input format.
  """
  def datetime_local_value(nil), do: ""

  def datetime_local_value(value) do
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

  @doc """
  Updates form with selected media file.
  """
  def update_form_with_media(form, file_id) do
    Map.put(form, "featured_image_id", file_id)
  end
end
