defmodule PhoenixKit.Modules.Publishing.Web.Editor.Preview do
  @moduledoc """
  Preview functionality for the publishing editor.

  Handles preview payload building, preview mode initialization,
  and preview-related state management.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Utils.Routes

  # ============================================================================
  # Preview Payload Building
  # ============================================================================

  @doc """
  Builds the preview payload from the current socket state.
  """
  def build_preview_payload(socket) do
    form = socket.assigns.form || %{}
    post = socket.assigns.post

    metadata = %{
      status: map_get_with_fallback(form, "status", metadata_value(post, :status), "draft"),
      published_at:
        map_get_with_fallback(
          form,
          "published_at",
          metadata_value(post, :published_at),
          ""
        ),
      slug: preview_slug(form, post),
      featured_image_id: Map.get(form, "featured_image_id", ""),
      url_slug: Map.get(form, "url_slug", "")
    }

    %{
      blog_slug: socket.assigns.blog_slug,
      path: post.path,
      mode: Map.get(post, :mode) || Map.get(post, "mode") || infer_mode(socket),
      language: socket.assigns.current_language,
      available_languages: post.available_languages || [],
      metadata: metadata,
      content: socket.assigns.content || "",
      is_new_post:
        Map.get(socket.assigns, :is_new_post, false) ||
          is_nil(post.path)
    }
  end

  defp map_get_with_fallback(map, key, fallback, default) do
    case Map.get(map, key) do
      nil -> fallback || default
      value -> value
    end
  end

  defp preview_slug(form, post) do
    form_slug =
      form
      |> Map.get("slug")
      |> case do
        nil -> nil
        slug -> String.trim(to_string(slug))
      end

    cond do
      form_slug && form_slug != "" ->
        form_slug

      Map.get(post, :slug) && post.slug != "" ->
        post.slug

      Map.get(post, "slug") && post["slug"] != "" ->
        post["slug"]

      metadata_value(post, :slug) ->
        metadata_value(post, :slug)

      metadata_value(post, "slug") ->
        metadata_value(post, "slug")

      true ->
        ""
    end
  end

  defp metadata_value(post, key) do
    metadata = Map.get(post, :metadata) || %{}

    cond do
      is_atom(key) ->
        Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

      is_binary(key) ->
        Map.get(metadata, key) ||
          try do
            Map.get(metadata, String.to_existing_atom(key))
          rescue
            ArgumentError -> nil
          end

      true ->
        nil
    end
  end

  defp infer_mode(socket) do
    case socket.assigns[:blog_mode] do
      "slug" -> :slug
      :slug -> :slug
      _ -> :timestamp
    end
  end

  # ============================================================================
  # Preview URL Building
  # ============================================================================

  @doc """
  Builds the preview URL query params.
  """
  def build_preview_query_params(preview_payload, token) do
    %{"preview_token" => token}
    |> maybe_put_preview_path(preview_payload.path)
    |> maybe_put_preview_new_flag(preview_payload)
  end

  def maybe_put_preview_path(params, path) when is_binary(path) and path != "" do
    Map.put(params, "path", path)
  end

  def maybe_put_preview_path(params, _), do: params

  def maybe_put_preview_new_flag(params, %{is_new_post: true}) do
    Map.put(params, "new", "true")
  end

  def maybe_put_preview_new_flag(params, _), do: params

  @doc """
  Builds the editor path for preview mode.
  """
  def preview_editor_path(socket, data, token, params) do
    blog_slug = data[:blog_slug] || socket.assigns.blog_slug

    query_params =
      %{}
      |> maybe_put_preview_path(Map.get(params, "path") || data[:path])
      |> maybe_put_preview_new_flag(%{is_new_post: data[:is_new_post] || false})
      |> Map.put("preview_token", token)

    query =
      case URI.encode_query(query_params) do
        "" -> ""
        encoded -> "?" <> encoded
      end

    Routes.path("/admin/publishing/#{blog_slug}/edit#{query}")
  end

  # ============================================================================
  # Preview State Application
  # ============================================================================

  @doc """
  Applies preview payload data to the socket.
  """
  def apply_preview_payload(socket, data) do
    blog_slug = data[:blog_slug] || socket.assigns.blog_slug
    mode = data[:mode] || :timestamp
    language = data[:language] || socket.assigns.current_language || "en"
    metadata = normalize_preview_metadata(data[:metadata] || %{}, mode)

    post = build_preview_post(data, blog_slug, mode, language, metadata)
    {post, disk_post} = enrich_from_disk(post, blog_slug)
    form = build_preview_form(metadata, mode, disk_post)

    apply_preview_assigns(socket, post, form, blog_slug, mode, data, disk_post)
  end

  defp build_preview_post(data, blog_slug, mode, language, metadata) do
    {date, time} = derive_datetime_fields(mode, metadata[:published_at])
    path = data[:path] || derive_preview_path(blog_slug, metadata[:slug], language, mode)
    full_path = if path, do: Storage.absolute_path(path), else: nil
    available_languages = data[:available_languages] || []

    available_languages =
      [language | available_languages] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      group: blog_slug,
      slug: metadata[:slug],
      date: date,
      time: time,
      path: path,
      full_path: full_path,
      metadata: metadata,
      content: data[:content] || "",
      language: language,
      available_languages: available_languages,
      mode: mode,
      is_legacy_structure: false
    }
  end

  defp build_preview_form(metadata, mode, disk_post) do
    alias PhoenixKit.Modules.Publishing.Web.Editor.Forms

    %{
      "title" => metadata[:title] || "",
      "status" => metadata[:status] || "draft",
      "published_at" => metadata[:published_at] || "",
      "featured_image_id" => metadata[:featured_image_id] || "",
      "url_slug" => metadata[:url_slug] || ""
    }
    |> maybe_put_form_slug(metadata[:slug], mode)
    |> supplement_form_from_disk(disk_post)
    |> Forms.normalize_form()
  end

  # Fill in any form fields that are empty with on-disk values
  defp supplement_form_from_disk(form, nil), do: form

  defp supplement_form_from_disk(form, disk_post) do
    Enum.reduce(
      [
        {"featured_image_id", Map.get(disk_post.metadata, :featured_image_id)},
        {"url_slug", Map.get(disk_post.metadata, :url_slug) || Map.get(disk_post, :url_slug)}
      ],
      form,
      fn {key, disk_value}, acc ->
        current = Map.get(acc, key, "")

        if current in [nil, ""] and disk_value not in [nil, ""] do
          Map.put(acc, key, to_string(disk_value))
        else
          acc
        end
      end
    )
  end

  defp apply_preview_assigns(socket, post, form, blog_slug, mode, data, disk_post) do
    language = post.language

    alias PhoenixKit.Modules.Publishing.Web.Editor.Forms
    alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers

    has_changes =
      case disk_post do
        nil -> true
        dp -> Forms.dirty?(dp, form, data[:content] || "")
      end

    # Derive on-disk status for save logic (saved_status tracks what's actually on disk)
    {saved_status, editing_published} =
      case disk_post do
        nil ->
          {"draft", false}

        dp ->
          status = Map.get(dp.metadata, :status, "draft")
          {status, status == "published"}
      end

    socket
    |> Phoenix.Component.assign(:blog_mode, mode_to_string(mode))
    |> Phoenix.Component.assign(:blog_slug, blog_slug)
    |> Phoenix.Component.assign(:post, post)
    |> Forms.assign_form_with_tracking(form, slug_manually_set: false)
    |> Phoenix.Component.assign(:content, data[:content] || "")
    |> Phoenix.Component.assign(:available_languages, post.available_languages)
    |> Phoenix.Component.assign(:all_enabled_languages, Storage.enabled_language_codes())
    |> Helpers.assign_current_language(language)
    |> Phoenix.Component.assign(:has_pending_changes, has_changes)
    |> Phoenix.Component.assign(:is_new_post, data[:is_new_post] || false)
    |> Phoenix.Component.assign(:public_url, Helpers.build_public_url(post, language))
    |> Phoenix.Component.assign(:blog_name, Publishing.group_name(blog_slug) || blog_slug)
    |> Phoenix.Component.assign(:current_version, Map.get(post, :version))
    |> Phoenix.Component.assign(:available_versions, Map.get(post, :available_versions, []))
    |> Phoenix.Component.assign(:version_statuses, Map.get(post, :version_statuses, %{}))
    |> Phoenix.Component.assign(:version_dates, Map.get(post, :version_dates, %{}))
    |> Phoenix.Component.assign(:editing_published_version, editing_published)
    |> Phoenix.Component.assign(:viewing_older_version, false)
    |> Phoenix.Component.assign(:saved_status, saved_status)
  end

  defp enrich_from_disk(post, blog_slug) do
    if post.path do
      case Publishing.read_post(blog_slug, post.path) do
        {:ok, disk_post} ->
          # Merge disk metadata as base, with preview metadata on top.
          # This preserves non-form fields (description, created_at, version_created_at,
          # previous_url_slugs, etc.) that aren't carried in the preview token,
          # preventing silent data loss if the user saves after returning from preview.
          preview_meta_values =
            post.metadata |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

          merged_metadata = Map.merge(disk_post.metadata, preview_meta_values)

          enriched =
            post
            |> Map.put(:metadata, merged_metadata)
            |> Map.put(:language_statuses, Map.get(disk_post, :language_statuses, %{}))
            |> Map.put(:available_versions, Map.get(disk_post, :available_versions, []))
            |> Map.put(:version_statuses, Map.get(disk_post, :version_statuses, %{}))
            |> Map.put(:version_dates, Map.get(disk_post, :version_dates, %{}))
            |> Map.put(:version, Map.get(disk_post, :version))
            |> Map.put(:primary_language, Map.get(disk_post, :primary_language))
            |> Map.put(:is_legacy_structure, Map.get(disk_post, :is_legacy_structure, false))

          {enriched, disk_post}

        {:error, reason} ->
          Logger.debug("Preview enrich_from_disk failed for #{post.path}: #{inspect(reason)}")
          fallback_status = Map.get(post.metadata, :status, "draft")
          enriched = Map.put(post, :language_statuses, %{post.language => fallback_status})
          {enriched, nil}
      end
    else
      fallback_status = Map.get(post.metadata, :status, "draft")
      enriched = Map.put(post, :language_statuses, %{post.language => fallback_status})
      {enriched, nil}
    end
  end

  defp normalize_preview_metadata(metadata, mode) do
    metadata_map =
      Enum.reduce(metadata, %{}, fn
        {key, value}, acc
        when key in [:status, :published_at, :slug, :featured_image_id, :url_slug] ->
          Map.put(acc, key, value)

        {"status", value}, acc ->
          Map.put(acc, :status, value)

        {"published_at", value}, acc ->
          Map.put(acc, :published_at, value)

        {"slug", value}, acc ->
          Map.put(acc, :slug, value)

        {"featured_image_id", value}, acc ->
          Map.put(acc, :featured_image_id, value)

        {"url_slug", value}, acc ->
          Map.put(acc, :url_slug, value)

        _, acc ->
          acc
      end)

    defaults =
      case mode do
        :slug -> %{status: "draft", published_at: "", slug: ""}
        _ -> %{status: "draft", published_at: "", slug: nil}
      end

    Map.merge(defaults, metadata_map)
  end

  defp derive_datetime_fields(:timestamp, published_at) do
    alias PhoenixKit.Modules.Publishing.Web.Editor.Forms

    with value when is_binary(value) and value != "" <- published_at,
         {:ok, dt, _offset} <- DateTime.from_iso8601(value) do
      floored = Forms.floor_datetime_to_minute(dt)

      {DateTime.to_date(floored), DateTime.to_time(floored)}
    else
      _ -> {nil, nil}
    end
  end

  defp derive_datetime_fields(_, _), do: {nil, nil}

  defp derive_preview_path(_blog_slug, _slug, _language, :timestamp), do: nil

  defp derive_preview_path(blog_slug, slug, language, :slug)
       when is_binary(slug) and slug != "" do
    Path.join([blog_slug, slug, "#{language}.phk"])
  end

  defp derive_preview_path(_, _, _, _), do: nil

  defp maybe_put_form_slug(form, slug, :slug) do
    Map.put(form, "slug", slug || "")
  end

  defp maybe_put_form_slug(form, _slug, _mode), do: form

  defp mode_to_string(:slug), do: "slug"
  defp mode_to_string(_), do: "timestamp"
end
