defmodule PhoenixKit.Modules.Storage.Library do
  @moduledoc """
  A storage library: a partition of the file store (V202).

  Every file, media folder and folder link belongs to exactly one library.
  **System** libraries are site-wide and managed by admins; everything that
  existed before V202 lives in the default one, **Media**
  (`PhoenixKit.Modules.Storage.Libraries.media_uuid/0`). **User** libraries
  (V203) belong to a user, are `private`, and may have members
  (`PhoenixKit.Modules.Storage.LibraryMember`). A trashed user library may
  outlive its owner (`owner_uuid` NULL) until it is purged. A system library
  is `site`, except a **hidden** one a module keeps its own files in, which is
  `private` (`PhoenixKit.Modules.Storage.Libraries.hidden?/1`).

  `key_prefix` is the first segment of the object key for files stored in the
  library from now on. `nil` keeps the historical layout, which is what Media
  uses, so nothing about an existing install's keys changes.

  Go through `PhoenixKit.Modules.Storage.Libraries` rather than this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Storage.Libraries

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(system user)
  @visibilities ~w(site private)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          kind: String.t(),
          owner_uuid: UUIDv7.t() | nil,
          visibility: String.t(),
          key_prefix: String.t() | nil,
          slug: String.t() | nil,
          settings: map(),
          is_default: boolean(),
          trashed_at: DateTime.t() | nil,
          storage_profile_uuid: UUIDv7.t() | nil,
          variant_set_uuid: UUIDv7.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_storage_libraries" do
    field :name, :string
    field :kind, :string, default: "system"
    field :visibility, :string, default: "site"
    field :key_prefix, :string
    # The URL name (`/admin/media/library/<slug>`); nil for the default
    # library, which is the bare `/admin/media`. Kept when the library is
    # renamed, so its links keep working.
    field :slug, :string
    # Includes the internal verification_last_started_at cooldown, which must
    # survive pruning job history. User-facing settings updates preserve it.
    field :settings, :map, default: %{}
    field :is_default, :boolean, default: false
    field :trashed_at, :utc_datetime
    # Where the library's bytes live and which sizes its uploads get (V205).
    # nil means the Default of each; set through `Storage.Profiles` and
    # `Storage.VariantSets`, never cast by the changesets here.
    field :storage_profile_uuid, UUIDv7
    field :variant_set_uuid, UUIDv7

    belongs_to :owner, PhoenixKit.Users.Auth.User,
      foreign_key: :owner_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  A new system library: a name, a URL slug and an object-key prefix. Always
  `site`; `Libraries.create_system_library/2` makes a hidden one `private`.
  """
  def create_system_changeset(library, attrs) do
    library
    |> cast(attrs, [:name, :key_prefix, :slug])
    |> put_change(:kind, "system")
    |> put_change(:visibility, "site")
    |> validate_name()
    |> validate_required([:key_prefix, :slug])
    |> validate_format(:key_prefix, ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    |> validate_length(:slug, max: 64)
    |> unique_constraint(:key_prefix, name: :phoenix_kit_storage_libraries_key_prefix_index)
    |> unique_constraint(:slug, name: :phoenix_kit_storage_libraries_owner_slug_index)
  end

  defp requested_visibility(attrs) when is_map(attrs),
    do: Map.get(attrs, :visibility) || Map.get(attrs, "visibility")

  @doc """
  A new user library: a name, its owner, a URL slug (unique among the
  owner's libraries) and an object-key prefix. `private` unless the caller says
  `visibility: "site"` (a public library, see `Libraries.create_user_library/3`,
  which is where that is allowed or refused: this changeset trusts its attrs).
  """
  def create_user_changeset(library, attrs) do
    # Read from the attrs, never from the changeset: the struct's own default is
    # "site", so a changeset that was not asked for "site" would still say it.
    visibility = if requested_visibility(attrs) == "site", do: "site", else: "private"

    library
    |> cast(attrs, [:name, :owner_uuid, :key_prefix, :slug, :is_default])
    |> put_change(:kind, "user")
    |> put_change(:visibility, visibility)
    |> validate_name()
    |> validate_required([:owner_uuid, :key_prefix, :slug])
    |> validate_format(:key_prefix, ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/)
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    |> validate_length(:slug, max: 64)
    |> unique_constraint(:key_prefix, name: :phoenix_kit_storage_libraries_key_prefix_index)
    |> unique_constraint(:slug, name: :phoenix_kit_storage_libraries_owner_slug_index)
    |> unique_constraint(:is_default, name: :phoenix_kit_storage_libraries_default_index)
  end

  @doc """
  The slug a name gives: lower-case letters and digits, hyphen-separated
  (`"Brand Assets 2026"` → `"brand-assets-2026"`). Letters outside ASCII
  are dropped with their accents where they have one; a name with nothing
  left is `"library"`.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 58)
    |> String.trim("-")
    |> case do
      "" -> "library"
      slug -> slug
    end
  end

  @doc "Renames a library. Its kind, owner and key prefix never change here."
  def rename_changeset(library, attrs) do
    library
    |> cast(attrs, [:name])
    |> validate_name()
  end

  @doc """
  Changes a user library's URL slug. Its name, owner and kind never change here. The slug
  keeps the shape `create_user_changeset/2` demands, is unique among the owner's libraries,
  and is not one the host has reserved (`PhoenixKit.Modules.Storage.Libraries.reserved_slug?/1`).
  """
  def slug_changeset(library, attrs) do
    library
    |> cast(attrs, [:slug])
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
    |> validate_length(:slug, max: 64)
    |> validate_change(:slug, fn :slug, slug ->
      if Libraries.reserved_slug?(slug),
        do: [slug: "is reserved"],
        else: []
    end)
    |> unique_constraint(:slug, name: :phoenix_kit_storage_libraries_owner_slug_index)
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:visibility, @visibilities)
    |> unique_constraint(:name,
      name: :phoenix_kit_storage_libraries_owner_name_index,
      message: "is already the name of another library"
    )
  end
end
