defmodule PhoenixKit.Modules.Pages.Storage.Helpers do
  @moduledoc """
  Shared helper functions for pages storage.

  Contains audit metadata helpers, path utilities, and other
  common functionality used across storage modules.
  """

  alias PhoenixKit.Modules.Pages.Metadata
  alias PhoenixKit.Modules.Pages.Storage.Languages

  # ============================================================================
  # Audit Metadata Helpers
  # ============================================================================

  @doc """
  Applies creation audit metadata to a metadata map.
  Sets both created_by and updated_by fields.
  """
  @spec apply_creation_audit_metadata(map(), map()) :: map()
  def apply_creation_audit_metadata(metadata, audit_meta) do
    created_id = audit_value(audit_meta, :created_by_uuid)
    created_email = audit_value(audit_meta, :created_by_email)
    updated_id = audit_value(audit_meta, :updated_by_uuid) || created_id
    updated_email = audit_value(audit_meta, :updated_by_email) || created_email

    metadata
    |> maybe_put_audit_field(:created_by_uuid, created_id)
    |> maybe_put_audit_field(:created_by_email, created_email)
    |> maybe_put_audit_field(:updated_by_uuid, updated_id)
    |> maybe_put_audit_field(:updated_by_email, updated_email)
  end

  @doc """
  Applies update audit metadata to a metadata map.
  Only sets updated_by fields.
  """
  @spec apply_update_audit_metadata(map(), map()) :: map()
  def apply_update_audit_metadata(metadata, audit_meta) do
    metadata
    |> maybe_put_audit_field(:updated_by_uuid, audit_value(audit_meta, :updated_by_uuid))
    |> maybe_put_audit_field(:updated_by_email, audit_value(audit_meta, :updated_by_email))
  end

  defp audit_value(audit_meta, key) do
    audit_meta
    |> Map.get(key)
    |> case do
      nil -> Map.get(audit_meta, Atom.to_string(key))
      value -> value
    end
    |> normalize_audit_value()
  end

  defp maybe_put_audit_field(metadata, _key, nil), do: metadata

  defp maybe_put_audit_field(metadata, key, value) do
    Map.put(metadata, key, value)
  end

  defp normalize_audit_value(nil), do: nil

  defp normalize_audit_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_audit_value(value), do: to_string(value)

  # ============================================================================
  # Metadata Helpers
  # ============================================================================

  @doc """
  Gets a value from metadata, checking both atom and string keys.
  """
  @spec metadata_value(map(), atom(), any()) :: any()
  def metadata_value(metadata, key, fallback \\ nil) do
    Map.get(metadata, key) ||
      Map.get(metadata, Atom.to_string(key)) ||
      fallback
  end

  @doc """
  Resolves featured_image_uuid from params or existing metadata.
  """
  @spec resolve_featured_image_uuid(map(), map()) :: String.t() | nil
  def resolve_featured_image_uuid(params, metadata) do
    case Map.fetch(params, "featured_image_uuid") do
      {:ok, value} -> normalize_featured_image_uuid(value)
      :error -> metadata_value(metadata, :featured_image_uuid)
    end
  end

  defp normalize_featured_image_uuid(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_featured_image_uuid(_), do: nil

  @doc """
  Resolves url_slug from params or existing metadata.
  Empty string clears the custom slug.
  """
  @spec resolve_url_slug(map(), map()) :: String.t() | nil
  def resolve_url_slug(params, metadata) do
    case Map.get(params, "url_slug") do
      nil -> Map.get(metadata, :url_slug)
      "" -> nil
      slug when is_binary(slug) -> String.trim(slug)
      _ -> Map.get(metadata, :url_slug)
    end
  end

  @doc """
  Resolves previous_url_slugs, tracking old slugs for 301 redirects.
  When url_slug changes, the old value is added to previous_url_slugs.
  """
  @spec resolve_previous_url_slugs(map(), map()) :: [String.t()]
  def resolve_previous_url_slugs(params, metadata) do
    current_slugs = Map.get(metadata, :previous_url_slugs) || []
    old_url_slug = Map.get(metadata, :url_slug)
    new_url_slug = Map.get(params, "url_slug")

    cond do
      new_url_slug == nil ->
        current_slugs

      new_url_slug == "" and old_url_slug not in [nil, ""] ->
        add_to_previous_slugs(current_slugs, old_url_slug)

      is_binary(new_url_slug) and new_url_slug != "" and old_url_slug not in [nil, ""] and
          String.trim(new_url_slug) != old_url_slug ->
        add_to_previous_slugs(current_slugs, old_url_slug)

      true ->
        current_slugs
    end
  end

  defp add_to_previous_slugs(current_slugs, slug) do
    if slug in current_slugs do
      current_slugs
    else
      current_slugs ++ [slug]
    end
  end

  @doc """
  Resolves allow_version_access from params or existing metadata.
  """
  @spec resolve_allow_version_access(map(), map()) :: boolean()
  def resolve_allow_version_access(params, metadata) do
    case Map.get(params, "allow_version_access") do
      nil -> Map.get(metadata, :allow_version_access, false)
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _ -> Map.get(metadata, :allow_version_access, false)
    end
  end

  @doc """
  Gets slug from metadata, falling back to provided default if nil or empty.
  """
  @spec get_slug_with_fallback(map(), String.t()) :: String.t()
  def get_slug_with_fallback(metadata, fallback) do
    case Map.get(metadata, :slug) do
      nil -> fallback
      "" -> fallback
      slug -> slug
    end
  end

  # ============================================================================
  # Time Helpers
  # ============================================================================

  @doc """
  Formats a Time struct as a time folder string (HH:MM).
  """
  @spec format_time_folder(Time.t()) :: String.t()
  def format_time_folder(%Time{} = time) do
    {hour, minute, _second} = Time.to_erl(time)
    "#{pad(hour)}:#{pad(minute)}"
  end

  @doc """
  Parses a time folder string (HH:MM) into a Time struct.
  """
  @spec parse_time_folder(String.t()) :: {:ok, Time.t()} | {:error, :invalid_time}
  def parse_time_folder(folder) do
    case String.split(folder, ":") do
      [hour, minute] ->
        with {h, ""} <- Integer.parse(hour),
             {m, ""} <- Integer.parse(minute),
             true <- h in 0..23,
             true <- m in 0..59 do
          {:ok, Time.new!(h, m, 0)}
        else
          _ -> {:error, :invalid_time}
        end

      _ ->
        {:error, :invalid_time}
    end
  end

  @doc """
  Floors a DateTime to the minute (sets seconds and microseconds to 0).
  """
  @spec floor_to_minute(DateTime.t()) :: DateTime.t()
  def floor_to_minute(%DateTime{} = datetime) do
    %DateTime{datetime | second: 0, microsecond: {0, 0}}
  end

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: Integer.to_string(value)

  # ============================================================================
  # Path Helpers
  # ============================================================================

  @doc """
  Extracts date and time from a relative path.
  Handles both legacy (4 parts) and versioned (5 parts) paths.
  """
  @spec date_time_from_path(String.t()) :: {:ok, {Date.t(), Time.t()}} | {:error, :invalid_path}
  def date_time_from_path(path) do
    parts = String.split(path, "/", trim: true)

    {date_part, time_part} =
      case parts do
        [_type, date_part, time_part, _file] ->
          {date_part, time_part}

        [_type, date_part, time_part, _version, _file] ->
          {date_part, time_part}

        _ ->
          {nil, nil}
      end

    if date_part && time_part do
      with {:ok, date} <- Date.from_iso8601(date_part),
           {:ok, time} <- parse_time_folder(time_part) do
        {:ok, {date, time}}
      else
        _ -> {:error, :invalid_path}
      end
    else
      {:error, :invalid_path}
    end
  rescue
    _ -> {:error, :invalid_path}
  end

  @doc """
  Extracts date and time from a relative path, raising on error.
  """
  @spec date_time_from_path!(String.t()) :: {Date.t(), Time.t()}
  def date_time_from_path!(path) do
    case date_time_from_path(path) do
      {:ok, result} -> result
      _ -> raise ArgumentError, "invalid blogging path #{inspect(path)}"
    end
  end

  @doc """
  Extracts language code from a path (e.g., "blog/post/en.phk" -> "en").
  """
  @spec extract_language_from_path(String.t()) :: String.t()
  def extract_language_from_path(relative_path) do
    relative_path
    |> Path.basename()
    |> String.replace_suffix(".phk", "")
  end

  @doc """
  Builds a relative path for a timestamp-mode post with language.
  """
  @spec relative_path_with_language(String.t(), Date.t(), Time.t(), String.t()) :: String.t()
  def relative_path_with_language(group_slug, date, time, language_code) do
    date_part = Date.to_iso8601(date)
    time_part = format_time_folder(time)

    Path.join([group_slug, date_part, time_part, Languages.language_filename(language_code)])
  end

  @doc """
  Builds a relative path for a versioned timestamp-mode post with language.
  """
  @spec relative_path_with_language_versioned(
          String.t(),
          Date.t(),
          Time.t(),
          integer(),
          String.t()
        ) :: String.t()
  def relative_path_with_language_versioned(group_slug, date, time, version, language_code) do
    date_part = Date.to_iso8601(date)
    time_part = format_time_folder(time)

    Path.join([
      group_slug,
      date_part,
      time_part,
      "v#{version}",
      Languages.language_filename(language_code)
    ])
  end

  # ============================================================================
  # Update Metadata Builder
  # ============================================================================

  @doc """
  Builds updated metadata for a post update operation.
  """
  @spec build_update_metadata(map(), map(), map(), boolean()) :: map()
  def build_update_metadata(post, params, audit_meta, _becoming_published?) do
    current_title =
      metadata_value(post.metadata, :title) ||
        Metadata.extract_title_from_content(post.content || "")

    current_status = metadata_value(post.metadata, :status, "draft")
    new_status = Map.get(params, "status", current_status)

    post.metadata
    |> Map.put(:title, Map.get(params, "title", current_title))
    |> Map.put(:status, new_status)
    |> Map.put(
      :published_at,
      Map.get(params, "published_at", metadata_value(post.metadata, :published_at))
    )
    |> Map.put(:featured_image_uuid, resolve_featured_image_uuid(params, post.metadata))
    |> Map.put(:created_at, Map.get(post.metadata, :created_at))
    |> Map.put(:slug, post.slug)
    |> Map.put(:version, Map.get(post.metadata, :version, 1))
    |> Map.put(:version_created_at, Map.get(post.metadata, :version_created_at))
    |> Map.put(:version_created_from, Map.get(post.metadata, :version_created_from))
    |> Map.put(:allow_version_access, resolve_allow_version_access(params, post.metadata))
    |> Map.put(:url_slug, resolve_url_slug(params, post.metadata))
    |> Map.put(:previous_url_slugs, resolve_previous_url_slugs(params, post.metadata))
    |> Map.delete(:is_live)
    |> Map.delete(:legacy_is_live)
    |> apply_update_audit_metadata(audit_meta)
  end
end
