defmodule PhoenixKit.Users.RelationshipType do
  @moduledoc """
  One kind of link between accounts, defined by the app or an admin as data.

    * `key` — the stable machine value (`manager`). Lowercase letters, digits and
      `_`, starting with a letter. Never translated.
    * `from_kind` / `to_kind` — `person` or `organization` on each end.
    * `can_act` — the from-person may enter the to-company through the switcher.
      A link of this type lives in `phoenix_kit_organization_managers`, and every
      row of that table means "may act", so the session code needs no type filter.
    * `can_manage` — they may also manage the company's people and profile.
    * `data` — core's multilang JSONB (`PhoenixKit.Utils.Multilang`): the translated
      `_name` and `_inverse_name` ("Client of" and "Clients"). The built-in type is
      seeded with an empty `data`, so its name is a gettext string until an admin
      overrides it.
    * `status` — `active` or `archived`. Archiving stops new links; existing links
      and their sessions carry on.
    * `builtin` — seeded by the migration, never castable. It cannot be archived or
      deleted.

  ⚠️ `key`, the two kinds, `can_act` and `can_manage` are **fixed at creation**:
  `update_changeset/2` does not cast them. `can_act` decides which table a link lives
  in, and turning off `can_manage` would leave companies without a manager, past
  the last-manager rule, with nobody asked. To change one, make a new type and move
  the links.

  Only acting types exist for now: `create_changeset/2` refuses `can_act: false`
  until the table for links that grant no access arrives.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  import Ecto.Changeset

  alias PhoenixKit.Utils.Multilang

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  # The built-in `manager` type, seeded by V229 and named by the column default of
  # `phoenix_kit_organization_managers.relationship_type_uuid`.
  @manager_uuid "019a0000-0000-7000-8000-000000000229"

  @statuses ~w(active archived)
  @kinds ~w(person organization)
  @key_format ~r/\A[a-z][a-z0-9_]*\z/
  @key_max 64

  @fixed ~w(key from_kind to_kind can_act can_manage)a
  @editable ~w(data status position)a
  @virtual ~w(name inverse_name)a

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          key: String.t() | nil,
          data: map(),
          from_kind: String.t() | nil,
          to_kind: String.t() | nil,
          can_act: boolean(),
          can_manage: boolean(),
          status: String.t(),
          position: integer(),
          builtin: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_relationship_types" do
    field :key, :string
    field :data, :map, default: %{}
    field :from_kind, :string
    field :to_kind, :string
    field :can_act, :boolean, default: false
    field :can_manage, :boolean, default: false
    field :status, :string, default: "active"
    field :position, :integer, default: 0
    field :builtin, :boolean, default: false

    # The primary-language names, for the form's primary tab. Never persisted:
    # `sync_data/1` folds a change into `data`.
    field :name, :string, virtual: true
    field :inverse_name, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc "The uuid of the built-in `manager` type."
  @spec manager_uuid() :: String.t()
  def manager_uuid, do: @manager_uuid

  @doc "The fields fixed at creation, for comparing what a host asks of `ensure/3`."
  @spec fixed_fields() :: [atom()]
  def fixed_fields, do: @fixed

  @doc "Changeset for a new type. `builtin` is never castable."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t(t())
  def create_changeset(%__MODULE__{} = type, attrs) do
    type
    |> cast(attrs, @fixed ++ @editable ++ @virtual)
    |> validate_data_shape()
    |> sync_data()
    |> validate_required(@fixed)
    |> validate_key()
    |> validate_inclusion(:from_kind, @kinds)
    |> validate_inclusion(:to_kind, @kinds)
    |> validate_acting_only()
    |> validate_editable()
    |> validate_primary_name()
    |> unique_constraint(:key,
      name: :phoenix_kit_relationship_types_key_index,
      message: "is already taken"
    )
    |> check_constraint(:can_manage, name: :phoenix_kit_relationship_types_manage_check)
    |> check_constraint(:can_act, name: :phoenix_kit_relationship_types_act_check)
  end

  @doc """
  Changeset for edits: names, position and status only. A built-in cannot be archived.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t(t())
  def update_changeset(%__MODULE__{} = type, attrs) do
    type
    |> cast(attrs, @editable ++ @virtual)
    |> validate_data_shape()
    |> sync_data()
    |> validate_editable()
    |> validate_builtin_stays_active()
    |> validate_primary_name()
  end

  # The form edits the primary-language names as plain fields and, with translations
  # on, ships the merged `data` alongside them. When only the plain fields arrive
  # they fold into `data` under the primary language. When `data` is supplied it is
  # the truth: the form already merged it.
  defp sync_data(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp sync_data(changeset) do
    fields =
      for {field, key} <- [name: "_name", inverse_name: "_inverse_name"],
          Map.has_key?(changeset.params, Atom.to_string(field)),
          into: %{},
          do: {key, get_field(changeset, field) || ""}

    if Map.has_key?(changeset.params, "data") or fields == %{} do
      changeset
    else
      existing = get_field(changeset, :data) || %{}
      primary = existing["_primary_language"] || Multilang.primary_language()
      merged = Map.merge(Multilang.get_primary_data(existing), fields)
      put_change(changeset, :data, Multilang.put_language_data(existing, primary, merged))
    end
  end

  defp validate_key(changeset) do
    changeset
    |> validate_length(:key, min: 1, max: @key_max)
    |> validate_format(:key, @key_format,
      message: "must be lowercase letters, digits and _, starting with a letter"
    )
  end

  defp validate_acting_only(changeset) do
    can_act? = get_field(changeset, :can_act)

    changeset
    |> then(fn cs ->
      if can_act?, do: cs, else: add_error(cs, :can_act, "only acting types are available")
    end)
    |> then(fn cs ->
      if can_act? and
           (get_field(cs, :from_kind) != "person" or get_field(cs, :to_kind) != "organization"),
         do: add_error(cs, :can_act, "needs a person acting for an organization"),
         else: cs
    end)
  end

  defp validate_editable(changeset) do
    changeset
    |> validate_required(@editable)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  defp validate_builtin_stays_active(changeset) do
    if changeset.data.builtin and get_field(changeset, :status) != "active",
      do: add_error(changeset, :status, "a built-in type cannot be archived"),
      else: changeset
  end

  # `data` is the one castable free-form field, and a string or list there would
  # crash every reader.
  defp validate_data_shape(changeset) do
    if Multilang.valid_text_data?(get_field(changeset, :data)),
      do: changeset,
      else: add_error(changeset, :data, "is invalid")
  end

  # A built-in falls back to its gettext name; every other type needs one.
  defp validate_primary_name(%{data: %{builtin: true}} = changeset), do: changeset

  defp validate_primary_name(changeset) do
    if Multilang.text_field(get_field(changeset, :data), "name"),
      do: changeset,
      else: add_error(changeset, :name, "can't be blank")
  end
end
