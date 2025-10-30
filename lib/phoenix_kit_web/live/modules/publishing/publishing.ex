defmodule PhoenixKitWeb.Live.Modules.Publishing do
  @moduledoc """
  Publishing module for managing structured content types and entries.

  This keeps content in the filesystem while providing an admin-friendly UI
  for creating timestamped markdown entries (blogs, news, etc).
  """

  alias PhoenixKitWeb.Live.Modules.Publishing.Storage
  alias PhoenixKit.Settings

  # Delegate language info function to Storage
  defdelegate get_language_info(language_code), to: Storage

  @enabled_key "publishing_enabled"
  @types_key "publishing_types"

  @type publishing_type :: map()

  @doc """
  Returns true when the publishing module is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting(@enabled_key, false)

  @doc """
  Enables the publishing module.
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system, do: Settings.update_boolean_setting(@enabled_key, true)

  @doc """
  Disables the publishing module.
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system, do: Settings.update_boolean_setting(@enabled_key, false)

  @doc """
  Returns all configured publishing types.
  """
  @spec list_types() :: [publishing_type()]
  def list_types do
    case Settings.get_json_setting(@types_key, %{"types" => []}) do
      %{"types" => types} when is_list(types) -> types
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Adds a new publishing type.
  """
  @spec add_type(String.t()) :: {:ok, publishing_type()} | {:error, atom()}
  def add_type(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, :invalid_name}

      true ->
        types = list_types()
        slug = slugify(trimmed)

        if Enum.any?(types, &(&1["slug"] == slug)) do
          {:error, :already_exists}
        else
          type = %{"name" => trimmed, "slug" => slug}
          updated = types ++ [type]
          payload = %{"types" => updated}

          with {:ok, _} <- Settings.update_json_setting(@types_key, payload),
               :ok <- Storage.ensure_type_root(slug) do
            {:ok, type}
          end
        end
    end
  end

  @doc """
  Removes a publishing type by slug.
  """
  @spec remove_type(String.t()) :: {:ok, any()} | {:error, any()}
  def remove_type(slug) when is_binary(slug) do
    updated =
      list_types()
      |> Enum.reject(&(&1["slug"] == slug))

    Settings.update_json_setting(@types_key, %{"types" => updated})
  end

  @doc """
  Looks up a type name from its slug.
  """
  @spec type_name(String.t()) :: String.t() | nil
  def type_name(slug) do
    Enum.find_value(list_types(), fn type ->
      if type["slug"] == slug, do: type["name"]
    end)
  end

  @doc """
  Lists entries for a given type slug.
  Accepts optional preferred_language to show titles in user's language.
  """
  @spec list_entries(String.t(), String.t() | nil) :: [Storage.entry()]
  def list_entries(type_slug, preferred_language \\ nil),
    do: Storage.list_entries(type_slug, preferred_language)

  @doc """
  Creates a new entry for the given type using the current timestamp.
  """
  @spec create_entry(String.t()) :: {:ok, Storage.entry()} | {:error, any()}
  def create_entry(type_slug), do: Storage.create_entry(type_slug)

  @doc """
  Reads an existing entry.
  """
  @spec read_entry(String.t(), String.t()) :: {:ok, Storage.entry()} | {:error, any()}
  def read_entry(type_slug, relative_path), do: Storage.read_entry(type_slug, relative_path)

  @doc """
  Updates an entry and moves the file if the publication timestamp changes.
  """
  @spec update_entry(String.t(), Storage.entry(), map()) ::
          {:ok, Storage.entry()} | {:error, any()}
  def update_entry(type_slug, entry, params),
    do: Storage.update_entry(type_slug, entry, params)

  @doc """
  Adds a new language file to an existing entry.
  """
  @spec add_language_to_entry(String.t(), String.t(), String.t()) ::
          {:ok, Storage.entry()} | {:error, any()}
  def add_language_to_entry(type_slug, entry_path, language_code),
    do: Storage.add_language_to_entry(type_slug, entry_path, language_code)

  @doc """
  Generates a slug from a user-provided type name.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "type"
      slug -> slug
    end
  end
end
