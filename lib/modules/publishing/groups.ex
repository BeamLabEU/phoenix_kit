defmodule PhoenixKit.Modules.Publishing.Groups do
  @moduledoc """
  Group management functions for the Publishing module.

  Handles creating, listing, updating, and removing publishing groups,
  as well as slug generation, type/mode normalization, and item naming.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.StaleFixer

  alias PhoenixKit.Modules.Publishing.Constants

  @default_group_mode Constants.default_mode()
  @default_group_type Constants.default_type()
  @preset_types Constants.preset_types()
  @valid_types Constants.valid_types()
  @type_regex ~r/^[a-z][a-z0-9-]{0,31}$/

  @type_item_names %{
    "blog" => {"post", "posts"},
    "faq" => {"question", "questions"},
    "legal" => {"document", "documents"}
  }
  @default_item_singular "item"
  @default_item_plural "items"

  @type group :: map()

  @doc """
  Returns all publishing groups from the database.
  """
  @spec list_groups() :: [group()]
  def list_groups do
    DBStorage.list_groups()
    |> Enum.map(fn group -> group |> StaleFixer.fix_stale_group() |> db_group_to_map() end)
  end

  @doc "Lists groups filtered by status (e.g. 'active', 'trashed')."
  @spec list_groups(String.t()) :: [group()]
  def list_groups(status) do
    DBStorage.list_groups(status)
    |> Enum.map(&db_group_to_map/1)
  end

  @doc """
  Gets a publishing group by slug.

  ## Examples

      iex> Groups.get_group("news")
      {:ok, %{"name" => "News", "slug" => "news", ...}}

      iex> Groups.get_group("nonexistent")
      {:error, :not_found}
  """
  @spec get_group(String.t()) :: {:ok, group()} | {:error, :not_found}
  def get_group(slug) when is_binary(slug) do
    case DBStorage.get_group_by_slug(slug) do
      nil -> {:error, :not_found}
      db_group -> {:ok, db_group |> StaleFixer.fix_stale_group() |> db_group_to_map()}
    end
  end

  @doc """
  Adds a new publishing group.

  ## Parameters

    * `name` - Display name for the group
    * `opts` - Keyword list or map with options:
      * `:mode` - Post mode: "timestamp" or "slug" (default: "timestamp")
      * `:slug` - Optional custom slug, auto-generated from name if nil
      * `:type` - Content type: "blog", "faq", "legal", or custom (default: "blog")
      * `:item_singular` - Singular name for items (default: based on type, e.g., "post")
      * `:item_plural` - Plural name for items (default: based on type, e.g., "posts")

  ## Examples

      iex> Groups.add_group("News")
      {:ok, %{"name" => "News", "slug" => "news", "mode" => "timestamp", "type" => "blog", ...}}

      iex> Groups.add_group("FAQ", type: "faq", mode: "slug")
      {:ok, %{"name" => "FAQ", "slug" => "faq", "mode" => "slug", "type" => "faq", "item_singular" => "question", ...}}

      iex> Groups.add_group("Recipes", type: "custom", item_singular: "recipe", item_plural: "recipes")
      {:ok, %{"name" => "Recipes", ..., "item_singular" => "recipe", "item_plural" => "recipes"}}
  """
  @spec add_group(String.t(), keyword() | map()) :: {:ok, group()} | {:error, atom()}
  def add_group(name, opts \\ [])

  def add_group(name, opts) when is_binary(name) and (is_list(opts) or is_map(opts)) do
    trimmed = String.trim(name)
    mode = opts |> fetch_option(:mode) |> normalize_mode_with_default()
    normalized_type = opts |> fetch_option(:type) |> normalize_type()

    cond do
      trimmed == "" ->
        {:error, :invalid_name}

      is_nil(mode) ->
        {:error, :invalid_mode}

      is_nil(normalized_type) ->
        {:error, :invalid_type}

      true ->
        groups = list_groups()
        preferred_slug = fetch_option(opts, :slug)

        with {:ok, requested_slug} <- derive_requested_slug(preferred_slug, trimmed),
             :ok <- check_slug_availability(requested_slug, groups, preferred_slug) do
          slug = ensure_unique_slug(requested_slug, groups)

          {default_singular, default_plural} = default_item_names(normalized_type)

          item_singular =
            opts
            |> fetch_option(:item_singular)
            |> normalize_item_name(default_singular)

          item_plural =
            opts
            |> fetch_option(:item_plural)
            |> normalize_item_name(default_plural)

          db_attrs = %{
            name: trimmed,
            slug: slug,
            mode: mode,
            data: %{
              "type" => normalized_type,
              "item_singular" => item_singular,
              "item_plural" => item_plural
            }
          }

          case DBStorage.create_group(db_attrs) do
            {:ok, db_group} ->
              group = db_group_to_map(db_group)
              PublishingPubSub.broadcast_group_created(group)
              {:ok, group}

            {:error, _changeset} ->
              {:error, :already_exists}
          end
        end
    end
  end

  @doc """
  Removes a publishing group by slug.
  """
  @spec remove_group(String.t()) :: {:ok, any()} | {:error, any()}
  def remove_group(slug) when is_binary(slug) do
    remove_group(slug, force: false)
  end

  @doc """
  Removes a publishing group by slug.

  By default, refuses to delete groups that contain posts.
  Pass `force: true` to cascade-delete the group and all its posts.
  """
  def remove_group(slug, opts) when is_binary(slug) do
    force = Keyword.get(opts, :force, false)

    case DBStorage.get_group_by_slug(slug) do
      nil ->
        {:error, :not_found}

      db_group ->
        post_count = DBStorage.count_posts(db_group.slug)

        if post_count > 0 and not force do
          {:error, {:has_posts, post_count}}
        else
          case DBStorage.delete_group(db_group) do
            {:ok, _} ->
              ListingCache.invalidate(slug)
              PublishingPubSub.broadcast_group_deleted(slug)
              {:ok, slug}

            error ->
              error
          end
        end
    end
  end

  @doc """
  Updates a publishing group's display name and slug.
  """
  @spec update_group(String.t(), map() | keyword()) :: {:ok, group()} | {:error, atom()}
  def update_group(slug, params) when is_binary(slug) do
    case DBStorage.get_group_by_slug(slug) do
      nil ->
        {:error, :not_found}

      db_group ->
        with {:ok, name} <- extract_and_validate_name(db_group, params),
             {:ok, sanitized_slug} <- extract_and_validate_slug(db_group, params, name) do
          case DBStorage.update_group(db_group, %{name: name, slug: sanitized_slug}) do
            {:ok, updated} ->
              group = db_group_to_map(updated)
              PublishingPubSub.broadcast_group_updated(group)
              {:ok, group}

            {:error, _} = error ->
              error
          end
        end
    end
  end

  @doc """
  Moves a publishing group to trash (soft-delete).

  Sets the group status to "trashed". The group and its posts remain in the
  database and can be restored. Trashed groups are hidden from list_groups/0.
  """
  @spec trash_group(String.t()) :: {:ok, String.t()} | {:error, any()}
  def trash_group(slug) when is_binary(slug) do
    case DBStorage.get_group_by_slug(slug) do
      nil ->
        {:error, :not_found}

      db_group ->
        case DBStorage.trash_group(db_group) do
          {:ok, _} ->
            ListingCache.invalidate(slug)
            PublishingPubSub.broadcast_group_deleted(slug)
            {:ok, slug}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Restores a trashed publishing group.
  """
  @spec restore_group(String.t()) :: {:ok, String.t()} | {:error, any()}
  def restore_group(slug) when is_binary(slug) do
    case DBStorage.get_group_by_slug(slug) do
      nil ->
        {:error, :not_found}

      db_group ->
        # Check if an active group already uses this slug (created while this was trashed)
        active_conflict =
          DBStorage.list_groups("active")
          |> Enum.any?(fn g -> g.slug == slug and g.uuid != db_group.uuid end)

        if active_conflict do
          {:error, :slug_taken}
        else
          case DBStorage.restore_group(db_group) do
            {:ok, _} ->
              ListingCache.regenerate(slug)

              PublishingPubSub.broadcast_group_created(%{
                "slug" => slug,
                "name" => db_group.name
              })

              {:ok, slug}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  @doc """
  Lists trashed publishing groups.
  """
  @spec list_trashed_groups() :: [map()]
  def list_trashed_groups do
    DBStorage.list_groups("trashed")
    |> Enum.map(&db_group_to_map/1)
  end

  @doc """
  Looks up a publishing group name from its slug.
  """
  @spec group_name(String.t()) :: String.t() | nil
  def group_name(slug) do
    case DBStorage.get_group_by_slug(slug) do
      nil -> nil
      db_group -> db_group.name
    end
  end

  @doc """
  Returns the configured post mode for a publishing group slug.
  """
  @spec get_group_mode(String.t()) :: String.t()
  def get_group_mode(group_slug) do
    case DBStorage.get_group_by_slug(group_slug) do
      nil -> @default_group_mode
      db_group -> db_group.mode || @default_group_mode
    end
  end

  @doc """
  Returns the preset content types with their default item names.
  """
  @spec preset_types() :: [map()]
  def preset_types do
    [
      %{type: "blog", label: "Blog", item_singular: "post", item_plural: "posts"},
      %{type: "faq", label: "FAQ", item_singular: "question", item_plural: "questions"},
      %{type: "legal", label: "Legal", item_singular: "document", item_plural: "documents"}
    ]
  end

  @doc """
  Returns the list of valid group type values.
  """
  @spec valid_types() :: [String.t()]
  def valid_types, do: @valid_types

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp extract_and_validate_name(db_group, params) do
    name =
      params
      |> fetch_option(:name)
      |> case do
        nil -> db_group.name
        value -> String.trim(to_string(value || ""))
      end

    if name == "", do: {:error, :invalid_name}, else: {:ok, name}
  end

  defp extract_and_validate_slug(db_group, params, name) do
    desired_slug =
      params
      |> fetch_option(:slug)
      |> case do
        nil -> db_group.slug
        value -> String.trim(to_string(value || ""))
      end

    cond do
      desired_slug == "" ->
        auto_slug = Publishing.slugify(name)

        if Publishing.valid_slug?(auto_slug),
          do: {:ok, auto_slug},
          else: {:error, :invalid_slug}

      Publishing.valid_slug?(desired_slug) ->
        {:ok, desired_slug}

      true ->
        {:error, :invalid_slug}
    end
  end

  defp db_group_to_map(%{name: name, slug: slug, mode: mode, data: data}) do
    %{
      "name" => name,
      "slug" => slug,
      "mode" => mode || @default_group_mode,
      "type" => Map.get(data, "type", @default_group_type),
      "item_singular" => Map.get(data, "item_singular", @default_item_singular),
      "item_plural" => Map.get(data, "item_plural", @default_item_plural)
    }
  end

  defp derive_requested_slug(nil, fallback_name) do
    slugified = Publishing.slugify(fallback_name)
    if slugified == "", do: {:error, :invalid_slug}, else: {:ok, slugified}
  end

  defp derive_requested_slug(slug, fallback_name) when is_binary(slug) do
    trimmed = slug |> String.trim()

    cond do
      trimmed == "" ->
        slugified = Publishing.slugify(fallback_name)
        if slugified == "", do: {:error, :invalid_slug}, else: {:ok, slugified}

      Publishing.valid_slug?(trimmed) ->
        {:ok, trimmed}

      true ->
        {:error, :invalid_slug}
    end
  end

  defp derive_requested_slug(_other, fallback_name) do
    slugified = Publishing.slugify(fallback_name)
    if slugified == "", do: {:error, :invalid_slug}, else: {:ok, slugified}
  end

  # Check if explicit slug already exists (only when preferred_slug is provided)
  defp check_slug_availability(slug, groups, preferred_slug) when not is_nil(preferred_slug) do
    if Enum.any?(groups, &(&1["slug"] == slug)) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  defp check_slug_availability(_slug, _groups, nil), do: :ok

  defp ensure_unique_slug(slug, groups), do: ensure_unique_slug(slug, groups, 2)

  defp ensure_unique_slug(slug, groups, counter) do
    if Enum.any?(groups, &(&1["slug"] == slug)) do
      ensure_unique_slug("#{slug}-#{counter}", groups, counter + 1)
    else
      slug
    end
  end

  defp normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.downcase()
    |> case do
      "slug" -> "slug"
      "timestamp" -> "timestamp"
      _ -> nil
    end
  end

  defp normalize_mode(mode) when is_atom(mode), do: normalize_mode(Atom.to_string(mode))
  defp normalize_mode(_), do: nil

  # Normalize mode with default fallback
  defp normalize_mode_with_default(nil), do: @default_group_mode
  defp normalize_mode_with_default(mode), do: normalize_mode(mode) || @default_group_mode

  # Normalize and validate type
  # Preset types are passed through, custom types are validated and normalized
  defp normalize_type(nil), do: @default_group_type

  defp normalize_type(type) when is_binary(type) do
    trimmed = String.trim(type)
    downcased = String.downcase(trimmed)

    cond do
      # Preset type - pass through as-is
      downcased in @preset_types ->
        downcased

      # Empty after trim - use default
      trimmed == "" ->
        @default_group_type

      # Custom type - validate format
      true ->
        # Normalize: downcase, replace spaces/underscores with hyphens
        normalized =
          downcased
          |> String.replace(~r/[\s_]+/, "-")
          |> String.replace(~r/[^a-z0-9-]/, "")
          |> String.slice(0, 32)

        # Validate against type regex
        if Regex.match?(@type_regex, normalized) do
          normalized
        else
          nil
        end
    end
  end

  defp normalize_type(type) when is_atom(type), do: normalize_type(Atom.to_string(type))
  defp normalize_type(_), do: nil

  # Get default item names for a type
  defp default_item_names(type) do
    Map.get(@type_item_names, type, {@default_item_singular, @default_item_plural})
  end

  # Normalize item name, using default if nil/empty
  defp normalize_item_name(nil, default), do: default
  defp normalize_item_name("", default), do: default

  defp normalize_item_name(name, default) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: default, else: trimmed
  end

  defp normalize_item_name(_, default), do: default

  @doc false
  defdelegate fetch_option(opts, key), to: Shared
end
