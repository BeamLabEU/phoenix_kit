defmodule PhoenixKit.Users.RelationshipTypes do
  @moduledoc """
  The kinds of link between accounts, as data. An app or an admin adds its own
  without a core release; one built-in type, `manager`, stands for what a grant has
  always done.

  ## Lifecycle

    * **create** — a type with a key and access flags that never change afterwards.
    * **update** — translated names and order.
    * **archive / restore** — an archived type keeps its links and their sessions
      but is no longer offered for new ones. The built-in cannot be archived.
    * **delete** — only a custom type nothing uses. The foreign keys are
      `ON DELETE RESTRICT`, so a type in use can only be archived.

  These functions decide nothing about who may call them: the page checks the
  `users` permission, and passes `:actor_uuid` for the activity log.

  ## Hosts that need a type to exist

  `ensure/3` creates a type idempotently, at boot or in a migration, and never
  overwrites what an admin has since edited:

      RelationshipTypes.ensure("employee",
        names: %{"en" => "Employee", "de" => "Mitarbeiter"},
        inverse_names: %{"en" => "Employees", "de" => "Mitarbeiter"},
        from_kind: "person",
        to_kind: "organization",
        can_act: true,
        can_manage: false
      )

  It answers `{:error, :type_conflict}` when the flags or kinds asked for differ from
  the stored ones, because they cannot change and a host must not boot believing a
  type is safer than it is.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Utils.Multilang

  @resource_type "relationship_type"
  @position_step 10

  @link_fkey :pk_org_managers_relationship_type_fkey
  @invitation_fkey :pk_org_invitations_relationship_type_fkey

  defp repo, do: RepoHelper.repo()

  @doc """
  Types in display order.

  ## Options

    * `:status` — `:all` (default), `:active` or `:archived`
  """
  @spec list_types(keyword()) :: [RelationshipType.t()]
  def list_types(opts \\ []) do
    RelationshipType
    |> filter_status(Keyword.get(opts, :status, :all))
    |> order_by([t], asc: t.position, asc: t.inserted_at, asc: t.key)
    |> repo().all()
  end

  defp filter_status(query, :active), do: where(query, [t], t.status == "active")
  defp filter_status(query, :archived), do: where(query, [t], t.status == "archived")
  defp filter_status(query, :all), do: query

  @doc "A type by uuid, or `nil`."
  @spec get_type(term()) :: RelationshipType.t() | nil
  def get_type(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(RelationshipType, uuid)
      :error -> nil
    end
  end

  def get_type(_uuid), do: nil

  @doc "A type by key, or `nil`."
  @spec get_type_by_key(term()) :: RelationshipType.t() | nil
  def get_type_by_key(key) when is_binary(key), do: repo().get_by(RelationshipType, key: key)
  def get_type_by_key(_key), do: nil

  @doc "The built-in `manager` type."
  @spec manager_type() :: RelationshipType.t()
  def manager_type, do: repo().get!(RelationshipType, RelationshipType.manager_uuid())

  @doc """
  A changeset for the add or edit form: a new type (no uuid yet) as a creation, a
  saved one as an edit. The primary-language names are filled in from `data` for the
  form's primary tab.
  """
  @spec change_type(RelationshipType.t(), map()) :: Ecto.Changeset.t()
  def change_type(%RelationshipType{} = type, attrs \\ %{}) do
    type = hydrate(type)
    attrs = stringify_keys(attrs)

    if is_nil(type.uuid),
      do: RelationshipType.create_changeset(type, attrs),
      else: RelationshipType.update_changeset(type, attrs)
  end

  @doc "Fills the virtual `name` and `inverse_name` from the primary-language `data`."
  @spec hydrate(RelationshipType.t()) :: RelationshipType.t()
  def hydrate(%RelationshipType{} = type) do
    %{
      type
      | name: type.name || Multilang.text_field(type.data, "name"),
        inverse_name: type.inverse_name || Multilang.text_field(type.data, "inverse_name")
    }
  end

  @doc """
  Creates a type. `attrs` takes `key`, `from_kind`, `to_kind`, `can_act`, `can_manage`,
  `data` or `name` and `inverse_name`, `position` and `status`. `position` defaults to
  the end of the list.

  Pass `:actor_uuid` in `opts` for the activity log.
  """
  @spec create_type(map(), keyword()) ::
          {:ok, RelationshipType.t()} | {:error, Ecto.Changeset.t()}
  def create_type(attrs, opts \\ []) do
    attrs = attrs |> stringify_keys() |> Map.put_new_lazy("position", &next_position/0)

    %RelationshipType{}
    |> RelationshipType.create_changeset(attrs)
    |> repo().insert()
    |> log_on_ok("relationship_type.created", opts)
  end

  @doc "Updates a type's names and order; the rest is fixed at creation."
  @spec update_type(RelationshipType.t(), map(), keyword()) ::
          {:ok, RelationshipType.t()} | {:error, Ecto.Changeset.t()}
  def update_type(%RelationshipType{} = type, attrs, opts \\ []) do
    type
    |> RelationshipType.update_changeset(stringify_keys(attrs))
    |> repo().update()
    |> log_on_ok("relationship_type.updated", opts)
  end

  @doc "Archives a type: no new links, every existing link and session intact."
  @spec archive_type(RelationshipType.t(), keyword()) ::
          {:ok, RelationshipType.t()} | {:error, Ecto.Changeset.t()}
  def archive_type(%RelationshipType{} = type, opts \\ []) do
    type
    |> RelationshipType.update_changeset(%{"status" => "archived"})
    |> repo().update()
    |> log_on_ok("relationship_type.archived", opts)
  end

  @doc "Makes an archived type available again."
  @spec restore_type(RelationshipType.t(), keyword()) ::
          {:ok, RelationshipType.t()} | {:error, Ecto.Changeset.t()}
  def restore_type(%RelationshipType{} = type, opts \\ []) do
    type
    |> RelationshipType.update_changeset(%{"status" => "active"})
    |> repo().update()
    |> log_on_ok("relationship_type.restored", opts)
  end

  @doc """
  Deletes a custom type nothing uses. The built-in is `{:error, :builtin}`, and a type
  with a link or an invitation is `{:error, :in_use}` and can only be archived.
  """
  @spec delete_type(RelationshipType.t(), keyword()) ::
          {:ok, RelationshipType.t()} | {:error, :builtin | :in_use | :not_found}
  def delete_type(type, opts \\ [])

  def delete_type(%RelationshipType{builtin: true}, _opts), do: {:error, :builtin}

  def delete_type(%RelationshipType{} = type, opts) do
    if in_use?(type) do
      {:error, :in_use}
    else
      type
      |> Ecto.Changeset.change()
      # The check above is not atomic: a link landing between it and the DELETE
      # trips the RESTRICT key, which is the same answer.
      |> Ecto.Changeset.foreign_key_constraint(:uuid, name: @link_fkey, message: "in use")
      |> Ecto.Changeset.foreign_key_constraint(:uuid, name: @invitation_fkey, message: "in use")
      |> repo().delete()
      |> case do
        {:ok, deleted} -> log_on_ok({:ok, deleted}, "relationship_type.deleted", opts)
        {:error, %Ecto.Changeset{}} -> {:error, :in_use}
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  @doc "Whether a link or an invitation uses the type."
  @spec in_use?(RelationshipType.t()) :: boolean()
  def in_use?(%RelationshipType{uuid: uuid}) do
    repo().exists?(from(m in OrganizationManager, where: m.relationship_type_uuid == ^uuid)) or
      repo().exists?(from(i in OrganizationInvitation, where: i.relationship_type_uuid == ^uuid))
  end

  @doc """
  Sets the display order from a list of type uuids: the first gets the lowest
  position. Types left out keep theirs, and unknown uuids are skipped.
  """
  @spec reorder([String.t()]) :: :ok
  def reorder(uuids) when is_list(uuids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, :ok} =
      repo().transaction(fn ->
        uuids
        |> Enum.with_index(1)
        |> Enum.each(fn {uuid, index} -> set_position(uuid, index * @position_step, now) end)
      end)

    :ok
  end

  defp set_position(uuid, position, now) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} ->
        RelationshipType
        |> where([t], t.uuid == ^uuid)
        |> repo().update_all(set: [position: position, updated_at: now])

      :error ->
        :skip
    end
  end

  @doc """
  Creates a type idempotently. An existing type is returned untouched, so it is safe
  on every boot. See the module documentation.

  ## Options (in `attrs`, atom or string keys)

    * `:names`, `:inverse_names` — `%{lang => text}`, or a string for the primary
      language. Or `:data`, a ready-made translations map
    * `:from_kind`, `:to_kind`, `:can_act`, `:can_manage`, `:position`
  """
  @spec ensure(String.t(), map() | keyword(), keyword()) ::
          {:ok, RelationshipType.t()} | {:error, :type_conflict | Ecto.Changeset.t()}
  def ensure(key, attrs \\ %{}, opts \\ []) when is_binary(key) do
    attrs = attrs |> Map.new() |> stringify_keys()

    case get_type_by_key(key) do
      %RelationshipType{} = type -> matching(type, attrs)
      nil -> key |> ensure_attrs(attrs) |> create_type(opts) |> reconcile_ensure(key, attrs)
    end
  end

  defp matching(type, attrs) do
    conflict? =
      Enum.any?(RelationshipType.fixed_fields(), fn field ->
        case Map.fetch(attrs, Atom.to_string(field)) do
          {:ok, value} -> Map.fetch!(type, field) != value
          :error -> false
        end
      end)

    if conflict?, do: {:error, :type_conflict}, else: {:ok, type}
  end

  defp ensure_attrs(key, attrs) do
    data =
      Map.get_lazy(attrs, "data", fn ->
        Multilang.build_text_data(%{
          "_name" => attrs["names"],
          "_inverse_name" => attrs["inverse_names"]
        })
      end)

    attrs
    |> Map.drop(["names", "inverse_names"])
    |> Map.merge(%{"key" => key, "data" => data})
  end

  # Two boots racing: the loser sees the winner's row, not an error.
  defp reconcile_ensure({:error, %Ecto.Changeset{errors: errors} = changeset}, key, attrs) do
    with true <- Keyword.has_key?(errors, :key),
         %RelationshipType{} = winner <- get_type_by_key(key) do
      matching(winner, attrs)
    else
      _ -> {:error, changeset}
    end
  end

  defp reconcile_ensure(result, _key, _attrs), do: result

  @doc """
  The type's name in `lang` (default: the viewer's language), falling back to the
  primary language, then for the built-in to its gettext string, then to the key.
  """
  @spec name(RelationshipType.t(), String.t() | nil) :: String.t()
  def name(%RelationshipType{} = type, lang \\ nil) do
    Multilang.text_field(type.data, "name", lang || Multilang.current_locale()) ||
      builtin_name(type.key) || type.key
  end

  @doc "The name of the other end (\"Clients\"), or `name/2` when there is none."
  @spec inverse_name(RelationshipType.t(), String.t() | nil) :: String.t()
  def inverse_name(%RelationshipType{} = type, lang \\ nil) do
    Multilang.text_field(type.data, "inverse_name", lang || Multilang.current_locale()) ||
      builtin_inverse_name(type.key) || name(type, lang)
  end

  defp builtin_name("manager"), do: gettext("Manager")
  defp builtin_name(_key), do: nil

  defp builtin_inverse_name("manager"), do: gettext("Managers")
  defp builtin_inverse_name(_key), do: nil

  defp next_position do
    max = RelationshipType |> select([t], max(t.position)) |> repo().one()
    (max || 0) + @position_step
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp log_on_ok({:ok, %RelationshipType{} = type} = ok, action, opts) do
    PhoenixKit.Activity.log(%{
      action: action,
      module: "users",
      mode: "manual",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: @resource_type,
      resource_uuid: type.uuid,
      metadata: %{"key" => type.key}
    })

    ok
  end

  defp log_on_ok(error, _action, _opts), do: error
end
