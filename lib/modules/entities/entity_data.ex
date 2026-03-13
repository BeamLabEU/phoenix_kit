defmodule PhoenixKit.Modules.Entities.EntityData do
  @moduledoc """
  Entity data records for PhoenixKit entities system.

  This module manages actual data records that follow entity blueprints.
  Each record is associated with an entity type and stores its field values
  in a JSONB column for flexibility.

  ## Schema Fields

  - `entity_uuid`: Foreign key to the entity blueprint
  - `title`: Display title/name for the record
  - `slug`: URL-friendly identifier (optional)
  - `status`: Record status ("draft", "published", "archived")
  - `data`: JSONB map of all field values based on entity definition
  - `metadata`: JSONB map for additional information (tags, categories, etc.)
  - `created_by`: User UUID who created the record
  - `date_created`: When the record was created
  - `date_updated`: When the record was last modified

  ## Core Functions

  ### Data Management
  - `list_all/0` - Get all entity data records
  - `list_by_entity/1` - Get all records for a specific entity
  - `list_by_entity_and_status/2` - Filter records by entity and status
  - `get!/1` - Get a record by ID (raises if not found)
  - `get_by_slug/2` - Get a record by entity and slug
  - `create/1` - Create a new record
  - `update/2` - Update an existing record
  - `delete/1` - Delete a record
  - `change/2` - Get changeset for forms

  ### Query Helpers
  - `search_by_title/2` - Search records by title
  - `filter_by_status/1` - Get records by status
  - `count_by_entity/1` - Count records for an entity
  - `published_records/1` - Get all published records for an entity

  ## Usage Examples

      # Create a brand data record
      {:ok, data} = PhoenixKit.Modules.Entities.EntityData.create(%{
        entity_uuid: brand_entity.uuid,
        title: "Acme Corporation",
        slug: "acme-corporation",
        status: "published",
        created_by_uuid: user.uuid,
        data: %{
          "name" => "Acme Corporation",
          "tagline" => "Quality products since 1950",
          "description" => "<p>Leading manufacturer of innovative products</p>",
          "industry" => "Manufacturing",
          "founded_date" => "1950-03-15",
          "featured" => true
        },
        metadata: %{
          "tags" => ["manufacturing", "industrial"],
          "contact_email" => "info@acme.com"
        }
      })

      # Get all records for an entity
      records = PhoenixKit.Modules.Entities.EntityData.list_by_entity(brand_entity.uuid)

      # Search by title
      results = PhoenixKit.Modules.Entities.EntityData.search_by_title("Acme", brand_entity.uuid)
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Modules.Entities.Events
  alias PhoenixKit.Modules.Entities.HtmlSanitizer
  alias PhoenixKit.Modules.Entities.Mirror.Exporter
  alias PhoenixKit.Modules.Entities.Multilang
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @derive {Jason.Encoder,
           only: [
             :uuid,
             :title,
             :slug,
             :status,
             :position,
             :data,
             :metadata,
             :date_created,
             :date_updated
           ]}

  schema "phoenix_kit_entity_data" do
    field :title, :string
    field :slug, :string
    field :status, :string, default: "published"
    field :data, :map
    field :metadata, :map
    field :position, :integer
    field :created_by_uuid, UUIDv7
    field :date_created, :utc_datetime
    field :date_updated, :utc_datetime

    belongs_to :entity, Entities, foreign_key: :entity_uuid, references: :uuid, type: UUIDv7

    belongs_to :creator, User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7
  end

  @valid_statuses ~w(draft published archived)

  @doc """
  Creates a changeset for entity data creation and updates.

  Validates that entity exists, title is present, and data validates against entity definition.
  Automatically sets date_created on new records.
  """
  def changeset(entity_data, attrs) do
    entity_data
    |> cast(attrs, [
      :entity_uuid,
      :title,
      :slug,
      :status,
      :position,
      :data,
      :metadata,
      :created_by_uuid,
      :date_created,
      :date_updated
    ])
    |> validate_required([:title])
    |> validate_entity_reference()
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_slug_format()
    |> sanitize_rich_text_data()
    |> validate_data_against_entity()
    |> foreign_key_constraint(:entity_uuid)
    |> maybe_set_timestamps()
  end

  defp validate_entity_reference(changeset) do
    entity_uuid = get_field(changeset, :entity_uuid)

    if is_nil(entity_uuid) do
      add_error(changeset, :entity_uuid, "entity_uuid must be present")
    else
      changeset
    end
  end

  defp validate_slug_format(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        changeset

      "" ->
        changeset

      slug ->
        if Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, slug) do
          changeset
        else
          add_error(
            changeset,
            :slug,
            gettext("must contain only lowercase letters, numbers, and hyphens")
          )
        end
    end
  end

  defp sanitize_rich_text_data(changeset) do
    entity_uuid = get_field(changeset, :entity_uuid)
    data = get_field(changeset, :data)

    case {entity_uuid, data} do
      {nil, _} ->
        changeset

      {_, nil} ->
        changeset

      {id, data} ->
        try do
          entity = Entities.get_entity!(id)
          fields_definition = entity.fields_definition || []

          sanitized_data =
            if Multilang.multilang_data?(data) do
              # Sanitize each language's data independently
              Enum.reduce(data, %{}, fn
                {"_primary_language", value}, acc ->
                  Map.put(acc, "_primary_language", value)

                {lang_code, lang_data}, acc when is_map(lang_data) ->
                  sanitized =
                    HtmlSanitizer.sanitize_rich_text_fields(fields_definition, lang_data)

                  Map.put(acc, lang_code, sanitized)

                {key, value}, acc ->
                  Map.put(acc, key, value)
              end)
            else
              HtmlSanitizer.sanitize_rich_text_fields(fields_definition, data)
            end

          put_change(changeset, :data, sanitized_data)
        rescue
          Ecto.NoResultsError -> changeset
        end
    end
  end

  defp validate_data_against_entity(changeset) do
    entity_uuid = get_field(changeset, :entity_uuid)
    data = get_field(changeset, :data)

    case entity_uuid do
      nil ->
        changeset

      uuid ->
        case Entities.get_entity!(uuid) do
          nil ->
            add_error(changeset, :entity_uuid, gettext("does not exist"))

          entity ->
            validate_data_fields(changeset, entity, data || %{})
        end
    end
  rescue
    Ecto.NoResultsError ->
      add_error(changeset, :entity_uuid, gettext("does not exist"))
  end

  defp validate_data_fields(changeset, entity, data) do
    fields_definition = entity.fields_definition || []

    # For multilang data, validate the primary language data (which must be complete)
    validation_data =
      if Multilang.multilang_data?(data) do
        Multilang.get_primary_data(data)
      else
        data
      end

    Enum.reduce(fields_definition, changeset, fn field_def, acc ->
      validate_single_data_field(acc, field_def, validation_data)
    end)
  end

  defp validate_single_data_field(changeset, field_def, data) do
    field_key = field_def["key"]
    field_value = data[field_key]
    is_required = field_def["required"] || false

    cond do
      is_required && (is_nil(field_value) || field_value == "") ->
        add_error(
          changeset,
          :data,
          gettext("field '%{label}' is required", label: field_def["label"])
        )

      !is_nil(field_value) && field_value != "" ->
        validate_field_type(changeset, field_def, field_value)

      true ->
        changeset
    end
  end

  defp validate_field_type(changeset, field_def, value) do
    case field_def["type"] do
      "number" -> validate_number_field(changeset, field_def, value)
      "boolean" -> validate_boolean_field(changeset, field_def, value)
      "email" -> validate_email_field(changeset, field_def, value)
      "url" -> validate_url_field(changeset, field_def, value)
      "date" -> validate_date_field(changeset, field_def, value)
      "select" -> validate_select_field(changeset, field_def, value)
      _ -> changeset
    end
  end

  defp validate_number_field(changeset, field_def, value) do
    if is_number(value) || (is_binary(value) && Regex.match?(~r/^\d+(\.\d+)?$/, value)) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a number", label: field_def["label"])
      )
    end
  end

  defp validate_boolean_field(changeset, field_def, value) do
    if is_boolean(value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be true or false", label: field_def["label"])
      )
    end
  end

  defp validate_email_field(changeset, field_def, value) do
    if is_binary(value) && Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a valid email", label: field_def["label"])
      )
    end
  end

  defp validate_url_field(changeset, field_def, value) do
    if is_binary(value) && String.starts_with?(value, ["http://", "https://"]) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a valid URL", label: field_def["label"])
      )
    end
  end

  defp validate_date_field(changeset, field_def, value) do
    if is_binary(value) && Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be a valid date (YYYY-MM-DD)", label: field_def["label"])
      )
    end
  end

  defp validate_select_field(changeset, field_def, value) do
    options = field_def["options"] || []

    if value in options do
      changeset
    else
      add_error(
        changeset,
        :data,
        gettext("field '%{label}' must be one of: %{options}",
          label: field_def["label"],
          options: Enum.join(options, ", ")
        )
      )
    end
  end

  defp maybe_set_timestamps(changeset) do
    now = UtilsDate.utc_now()

    case changeset.data.__meta__.state do
      :built ->
        changeset
        |> put_change(:date_created, now)
        |> put_change(:date_updated, now)

      :loaded ->
        put_change(changeset, :date_updated, now)
    end
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :created) do
    Events.broadcast_data_created(entity_data.entity_uuid, entity_data.uuid)
    maybe_mirror_data(entity_data)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :updated) do
    Events.broadcast_data_updated(entity_data.entity_uuid, entity_data.uuid)
    maybe_mirror_data(entity_data)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :deleted) do
    Events.broadcast_data_deleted(entity_data.entity_uuid, entity_data.uuid)
    maybe_delete_mirrored_data(entity_data)
    {:ok, entity_data}
  end

  defp notify_data_event(result, _event), do: result

  # Broadcast a reorder event for an entity so live views refresh.
  defp notify_reorder_event(entity_uuid) when is_binary(entity_uuid) do
    Events.broadcast_data_reordered(entity_uuid)
  end

  defp notify_reorder_event(_), do: :ok

  # Resolve entity_uuid from the first record in a bulk update list
  defp resolve_entity_uuid_from_pairs([{uuid, _} | _]) do
    from(d in __MODULE__, where: d.uuid == ^uuid, select: d.entity_uuid)
    |> repo().one()
  end

  defp resolve_entity_uuid_from_pairs(_), do: nil

  # Mirror export helpers for auto-sync (per-entity settings)
  defp maybe_mirror_data(entity_data) do
    # Check if the parent entity has data mirroring enabled
    case Entities.get_entity(entity_data.entity_uuid) do
      nil ->
        :ok

      entity ->
        if Entities.mirror_data_enabled?(entity) do
          Task.start(fn -> Exporter.export_entity_data(entity_data) end)
        end
    end
  end

  defp maybe_delete_mirrored_data(entity_data) do
    # Re-export the entity file to update the data array
    # Only if the entity has data mirroring enabled
    case Entities.get_entity(entity_data.entity_uuid) do
      nil ->
        :ok

      entity ->
        if Entities.mirror_data_enabled?(entity) do
          Task.start(fn -> Exporter.export_entity(entity) end)
        end
    end
  end

  @doc """
  Returns all entity data records ordered by creation date.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.list_all()
      [%PhoenixKit.Modules.Entities.EntityData{}, ...]
  """
  def list_all(opts \\ []) do
    from(d in __MODULE__,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Returns all entity data records for a specific entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.list_by_entity(entity_uuid)
      [%PhoenixKit.Modules.Entities.EntityData{}, ...]
  """
  def list_by_entity(entity_uuid, opts \\ []) when is_binary(entity_uuid) do
    order = resolve_sort_order(entity_uuid, opts)

    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid,
      order_by: ^order,
      preload: [:entity, :creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Returns entity data records filtered by entity and status.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.list_by_entity_and_status(entity_uuid, "published")
      [%PhoenixKit.Modules.Entities.EntityData{status: "published"}, ...]
  """
  def list_by_entity_and_status(entity_uuid, status, opts \\ [])
      when is_binary(entity_uuid) and status in @valid_statuses do
    order = resolve_sort_order(entity_uuid, opts)

    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid and d.status == ^status,
      order_by: ^order,
      preload: [:entity, :creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Gets a single entity data record by UUID.

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get("invalid")
      nil
  """
  def get(uuid, opts \\ [])

  def get(uuid, opts) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      case repo().get_by(__MODULE__, uuid: uuid) do
        nil -> nil
        record -> record |> repo().preload([:entity, :creator]) |> maybe_resolve_lang(opts)
      end
    else
      nil
    end
  end

  def get(_, _opts), do: nil

  @doc """
  Gets a single entity data record by UUID.

  Raises `Ecto.NoResultsError` if the record does not exist.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get!("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get!("nonexistent-uuid")
      ** (Ecto.NoResultsError)
  """
  def get!(id, opts \\ []) do
    case get(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: __MODULE__
      record -> record
    end
  end

  @doc """
  Gets a single entity data record by entity and slug.

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get_by_slug(entity_uuid, "acme-corporation")
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get_by_slug(entity_uuid, "invalid")
      nil
  """
  def get_by_slug(entity_uuid, slug, opts \\ [])
      when is_binary(entity_uuid) and is_binary(slug) do
    case repo().get_by(__MODULE__, entity_uuid: entity_uuid, slug: slug) do
      nil -> nil
      record -> record |> repo().preload([:entity, :creator]) |> maybe_resolve_lang(opts)
    end
  end

  @doc """
  Checks if a secondary language slug exists for another record within the same entity.

  Queries the JSONB `data` column for `data->lang_code->>'_slug'` matches.
  Used for uniqueness checks on translated slugs.
  """
  def secondary_slug_exists?(entity_uuid, lang_code, slug, exclude_record_uuid)
      when is_binary(entity_uuid) do
    query =
      from(ed in __MODULE__,
        where: fragment("(? -> ? ->> '_slug') = ?", ed.data, ^lang_code, ^slug),
        where: ed.entity_uuid == ^entity_uuid,
        select: ed.uuid
      )

    query =
      if exclude_record_uuid do
        from(ed in query, where: ed.uuid != ^exclude_record_uuid)
      else
        query
      end

    repo().exists?(query)
  end

  @doc """
  Creates an entity data record.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.create(%{entity_uuid: entity_uuid, title: "Test"})
      {:ok, %PhoenixKit.Modules.Entities.EntityData{}}

      iex> PhoenixKit.Modules.Entities.EntityData.create(%{title: ""})
      {:error, %Ecto.Changeset{}}

  Note: `created_by` is auto-filled with the first admin or user ID if not provided,
  but only if at least one user exists in the system. If no users exist, the changeset
  will fail with a validation error on `created_by`.
  """
  def create(attrs \\ %{}) do
    # Transaction ensures next_position read + insert are atomic
    repo().transaction(fn ->
      attrs =
        attrs
        |> maybe_add_created_by()
        |> maybe_add_position()

      case %__MODULE__{} |> changeset(attrs) |> repo().insert() do
        {:ok, record} -> record
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
    |> notify_data_event(:created)
  end

  # Auto-fill created_by_uuid with first admin if not provided
  defp maybe_add_created_by(attrs) when is_map(attrs) do
    has_created_by_uuid =
      Map.has_key?(attrs, :created_by_uuid) or Map.has_key?(attrs, "created_by_uuid")

    if has_created_by_uuid do
      attrs
    else
      key = if Map.has_key?(attrs, :entity_uuid), do: :created_by_uuid, else: "created_by_uuid"

      case Auth.get_first_admin_uuid() do
        nil ->
          # Fall back to first user if no admin exists
          case Auth.get_first_user_uuid() do
            nil -> attrs
            user_uuid -> Map.put(attrs, key, user_uuid)
          end

        admin_uuid ->
          Map.put(attrs, key, admin_uuid)
      end
    end
  end

  # Auto-fill position with next value for the entity if not provided
  defp maybe_add_position(attrs) when is_map(attrs) do
    has_position = Map.has_key?(attrs, :position) or Map.has_key?(attrs, "position")

    if has_position do
      attrs
    else
      entity_uuid =
        Map.get(attrs, :entity_uuid) || Map.get(attrs, "entity_uuid")

      if entity_uuid do
        next_pos = next_position(entity_uuid)
        key = if Map.has_key?(attrs, :entity_uuid), do: :position, else: "position"
        Map.put(attrs, key, next_pos)
      else
        attrs
      end
    end
  end

  @doc """
  Gets the next available position for an entity's data records.

  ## Examples

      iex> next_position(entity_uuid)
      6
  """
  def next_position(entity_uuid) when is_binary(entity_uuid) do
    # FOR UPDATE locks matching rows within a transaction to prevent
    # concurrent creates from reading the same max position.
    # NOTE: The lock only takes effect inside a repo().transaction/1 block.
    # Called internally by create/1 which wraps in a transaction.
    # Fetch individual positions with row-level lock, then compute max in Elixir.
    # PostgreSQL does not allow FOR UPDATE with aggregate functions.
    positions =
      from(d in __MODULE__,
        where: d.entity_uuid == ^entity_uuid,
        select: d.position,
        lock: "FOR UPDATE"
      )
      |> repo().all()

    Enum.max(positions, fn -> 0 end) + 1
  end

  @doc """
  Updates the position of a single entity data record.

  ## Examples

      iex> update_position(record, 3)
      {:ok, %EntityData{position: 3}}
  """
  def update_position(%__MODULE__{} = entity_data, position) when is_integer(position) do
    __MODULE__.update(entity_data, %{position: position})
  end

  @doc """
  Bulk updates positions for multiple records.

  Accepts a list of `{uuid, position}` tuples. Each record is updated
  individually to trigger events and maintain consistency.

  ## Examples

      iex> bulk_update_positions([{"uuid1", 1}, {"uuid2", 2}, {"uuid3", 3}])
      :ok
  """
  def bulk_update_positions(uuid_position_pairs, opts \\ [])
      when is_list(uuid_position_pairs) do
    result =
      repo().transaction(fn ->
        now = UtilsDate.utc_now()

        Enum.each(uuid_position_pairs, fn {uuid, position} ->
          from(d in __MODULE__, where: d.uuid == ^uuid)
          |> repo().update_all(set: [position: position, date_updated: now])
        end)
      end)

    case result do
      {:ok, _} ->
        entity_uuid =
          Keyword.get(opts, :entity_uuid) || resolve_entity_uuid_from_pairs(uuid_position_pairs)

        notify_reorder_event(entity_uuid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Moves a record to a specific position within its entity, shifting other records.

  Records between the old and new positions are shifted up or down by 1 to
  make room. This is the operation that a drag-and-drop UI would call.

  ## Examples

      iex> move_to_position(record, 3)
      :ok
  """
  def move_to_position(%__MODULE__{} = record, new_position) when is_integer(new_position) do
    entity_uuid = record.entity_uuid

    result =
      repo().transaction(fn ->
        # Re-read position inside transaction to avoid stale data
        current = repo().get!(__MODULE__, record.uuid)
        old_position = current.position

        cond do
          is_nil(old_position) ->
            do_update_position!(current, new_position)

          old_position == new_position ->
            :noop

          true ->
            now = UtilsDate.utc_now()
            shift_neighbors(entity_uuid, current.uuid, old_position, new_position, now)
            do_update_position!(current, new_position)
        end
      end)

    case result do
      {:ok, :noop} ->
        :ok

      {:ok, _} ->
        notify_reorder_event(entity_uuid)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Update position inside a transaction, rolling back on failure
  defp do_update_position!(record, position) do
    case update_position(record, position) do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp shift_neighbors(entity_uuid, record_uuid, old_pos, new_pos, now)
       when old_pos < new_pos do
    # Moving down: shift records in (old, new] up by 1
    from(d in __MODULE__,
      where:
        d.entity_uuid == ^entity_uuid and
          d.position > ^old_pos and
          d.position <= ^new_pos and
          d.uuid != ^record_uuid
    )
    |> repo().update_all(inc: [position: -1], set: [date_updated: now])
  end

  defp shift_neighbors(entity_uuid, record_uuid, old_pos, new_pos, now) do
    # Moving up: shift records in [new, old) down by 1
    from(d in __MODULE__,
      where:
        d.entity_uuid == ^entity_uuid and
          d.position >= ^new_pos and
          d.position < ^old_pos and
          d.uuid != ^record_uuid
    )
    |> repo().update_all(inc: [position: 1], set: [date_updated: now])
  end

  @doc """
  Reorders all records for an entity based on a list of UUIDs in the desired order.

  This is the full reorder operation — takes a list of UUIDs representing the
  new order and assigns positions 1, 2, 3, ... accordingly.

  ## Examples

      iex> reorder(entity_uuid, ["uuid3", "uuid1", "uuid2"])
      :ok
  """
  def reorder(entity_uuid, ordered_uuids)
      when is_binary(entity_uuid) and is_list(ordered_uuids) do
    pairs =
      ordered_uuids
      |> Enum.with_index(1)
      |> Enum.map(fn {uuid, pos} -> {uuid, pos} end)

    bulk_update_positions(pairs, entity_uuid: entity_uuid)
  end

  @doc """
  Updates an entity data record.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.update(record, %{title: "Updated"})
      {:ok, %PhoenixKit.Modules.Entities.EntityData{}}

      iex> PhoenixKit.Modules.Entities.EntityData.update(record, %{title: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update(%__MODULE__{} = entity_data, attrs) do
    entity_data
    |> changeset(attrs)
    |> repo().update()
    |> notify_data_event(:updated)
  end

  @doc """
  Deletes an entity data record.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.delete(record)
      {:ok, %PhoenixKit.Modules.Entities.EntityData{}}

      iex> PhoenixKit.Modules.Entities.EntityData.delete(record)
      {:error, %Ecto.Changeset{}}
  """
  def delete(%__MODULE__{} = entity_data) do
    repo().delete(entity_data)
    |> notify_data_event(:deleted)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking entity data changes.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.change(record)
      %Ecto.Changeset{data: %PhoenixKit.Modules.Entities.EntityData{}}
  """
  def change(%__MODULE__{} = entity_data, attrs \\ %{}) do
    changeset(entity_data, attrs)
  end

  @doc """
  Searches entity data records by title.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.search_by_title("Acme")
      [%PhoenixKit.Modules.Entities.EntityData{}, ...]

      iex> PhoenixKit.Modules.Entities.EntityData.search_by_title("Acme", entity_uuid)
      [%PhoenixKit.Modules.Entities.EntityData{}, ...]

      iex> PhoenixKit.Modules.Entities.EntityData.search_by_title("Acme", entity_uuid, lang: "es")
      [%PhoenixKit.Modules.Entities.EntityData{}, ...]
  """
  def search_by_title(search_term) when is_binary(search_term),
    do: search_by_title(search_term, nil, [])

  def search_by_title(search_term, entity_uuid, opts \\ [])

  def search_by_title(search_term, entity_uuid, opts)
      when is_binary(search_term) do
    search_pattern = "%#{search_term}%"
    order = if entity_uuid, do: resolve_sort_order(entity_uuid, opts), else: [desc: :date_created]

    query =
      from(d in __MODULE__,
        where: ilike(d.title, ^search_pattern),
        order_by: ^order,
        preload: [:entity, :creator]
      )

    query =
      case entity_uuid do
        nil ->
          query

        uuid when is_binary(uuid) ->
          from(d in query, where: d.entity_uuid == ^uuid)
      end

    repo().all(query)
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Gets all published records for a specific entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.published_records(entity_uuid)
      [%PhoenixKit.Modules.Entities.EntityData{status: "published"}, ...]
  """
  def published_records(entity_uuid, opts \\ []) when is_binary(entity_uuid) do
    list_by_entity_and_status(entity_uuid, "published", opts)
  end

  @doc """
  Counts the total number of records for an entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.count_by_entity(entity_uuid)
      42
  """
  def count_by_entity(entity_uuid) when is_binary(entity_uuid) do
    from(d in __MODULE__, where: d.entity_uuid == ^entity_uuid, select: count(d.uuid))
    |> repo().one()
  end

  @doc """
  Gets records filtered by status across all entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.filter_by_status("draft")
      [%PhoenixKit.Modules.Entities.EntityData{status: "draft"}, ...]
  """
  def filter_by_status(status, opts \\ []) when status in @valid_statuses do
    from(d in __MODULE__,
      where: d.status == ^status,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
    |> maybe_resolve_langs(opts)
  end

  @doc """
  Alias for list_all/1 for consistency with LiveView naming.
  """
  def list_all_data(opts \\ []), do: list_all(opts)

  @doc """
  Alias for list_by_entity/2 for consistency with LiveView naming.
  """
  def list_data_by_entity(entity_uuid, opts \\ []), do: list_by_entity(entity_uuid, opts)

  @doc """
  Alias for filter_by_status/2 for consistency with LiveView naming.
  """
  def list_data_by_status(status, opts \\ []), do: filter_by_status(status, opts)

  @doc """
  Alias for search_by_title for consistency with LiveView naming.
  """
  def search_data(search_term) when is_binary(search_term),
    do: search_by_title(search_term, nil, [])

  def search_data(search_term, entity_uuid, opts \\ []),
    do: search_by_title(search_term, entity_uuid, opts)

  @doc """
  Alias for get!/2 for consistency with LiveView naming.
  """
  def get_data!(id, opts \\ []), do: get!(id, opts)

  @doc """
  Alias for delete/1 for consistency with LiveView naming.
  """
  def delete_data(entity_data), do: __MODULE__.delete(entity_data)

  @doc """
  Alias for update/2 for consistency with LiveView naming.
  """
  def update_data(entity_data, attrs), do: __MODULE__.update(entity_data, attrs)

  @doc """
  Bulk updates the status of multiple records by UUIDs.

  Returns a tuple with the count of updated records and nil.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.bulk_update_status(["uuid1", "uuid2"], "archived")
      {2, nil}
  """
  def bulk_update_status(uuids, status) when is_list(uuids) and status in @valid_statuses do
    now = UtilsDate.utc_now()

    from(d in __MODULE__, where: d.uuid in ^uuids)
    |> repo().update_all(set: [status: status, date_updated: now])
  end

  @doc """
  Bulk deletes multiple records by UUIDs.

  Returns a tuple with the count of deleted records and nil.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.bulk_delete(["uuid1", "uuid2"])
      {2, nil}
  """
  def bulk_delete(uuids) when is_list(uuids) do
    from(d in __MODULE__, where: d.uuid in ^uuids)
    |> repo().delete_all()
  end

  @doc """
  Gets statistical data about entity data records.

  Returns statistics about total records, published, draft, and archived counts.
  Optionally filters by entity_uuid if provided.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get_data_stats()
      %{
        total_records: 150,
        published_records: 120,
        draft_records: 25,
        archived_records: 5
      }

      iex> PhoenixKit.Modules.Entities.EntityData.get_data_stats("018e3c4a-9f6b-7890-abcd-ef1234567890")
      %{
        total_records: 15,
        published_records: 12,
        draft_records: 2,
        archived_records: 1
      }
  """
  def get_data_stats(entity_uuid \\ nil) do
    query =
      from(d in __MODULE__,
        select: {
          count(d.uuid),
          count(fragment("CASE WHEN ? = 'published' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'draft' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'archived' THEN 1 END", d.status))
        }
      )

    query =
      case entity_uuid do
        nil ->
          query

        uuid when is_binary(uuid) ->
          from(d in query, where: d.entity_uuid == ^uuid)
      end

    {total, published, draft, archived} = repo().one(query)

    %{
      total_records: total,
      published_records: published,
      draft_records: draft,
      archived_records: archived
    }
  end

  # ============================================================================
  # Translation convenience API
  # ============================================================================

  @doc """
  Gets the data fields for a specific language, merged with primary language defaults.

  For multilang records, returns `Map.merge(primary_data, language_overrides)`.
  For flat (non-multilang) records, returns the data as-is.

  ## Examples

      iex> get_translation(record, "es-ES")
      %{"name" => "Acme España", "category" => "Tech"}

      iex> get_translation(flat_record, "en-US")
      %{"name" => "Acme", "category" => "Tech"}
  """
  def get_translation(%__MODULE__{data: data}, lang_code) when is_binary(lang_code) do
    Multilang.get_language_data(data, lang_code)
  end

  @doc """
  Gets the raw (non-merged) data for a specific language.

  For secondary languages, returns only the override fields (not merged with primary).
  Useful for seeing which fields have explicit translations.

  ## Examples

      iex> get_raw_translation(record, "es-ES")
      %{"name" => "Acme España"}
  """
  def get_raw_translation(%__MODULE__{data: data}, lang_code) when is_binary(lang_code) do
    Multilang.get_raw_language_data(data, lang_code)
  end

  @doc """
  Gets translations for all languages in a record.

  Returns a map of language codes to their merged data.
  For flat records, returns the data under the primary language key.

  ## Examples

      iex> get_all_translations(record)
      %{
        "en-US" => %{"name" => "Acme", "category" => "Tech"},
        "es-ES" => %{"name" => "Acme España", "category" => "Tech"}
      }
  """
  def get_all_translations(%__MODULE__{data: data}) do
    if Multilang.multilang_data?(data) do
      Multilang.enabled_languages()
      |> Map.new(fn lang -> {lang, Multilang.get_language_data(data, lang)} end)
    else
      primary = Multilang.primary_language()
      %{primary => data || %{}}
    end
  end

  @doc """
  Sets the data translation for a specific language on a record.

  For the primary language, stores all fields.
  For secondary languages, only stores fields that differ from primary (overrides).
  Persists to the database.

  ## Examples

      iex> set_translation(record, "es-ES", %{"name" => "Acme España"})
      {:ok, %EntityData{}}

      iex> set_translation(record, "en-US", %{"name" => "Acme Corp", "category" => "Tech"})
      {:ok, %EntityData{}}
  """
  def set_translation(%__MODULE__{} = entity_data, lang_code, field_data)
      when is_binary(lang_code) and is_map(field_data) do
    updated_data = Multilang.put_language_data(entity_data.data, lang_code, field_data)
    __MODULE__.update(entity_data, %{data: updated_data})
  end

  @doc """
  Removes all data for a specific language from a record.

  Cannot remove the primary language. Returns `{:error, :cannot_remove_primary}`
  if the primary language is targeted.

  ## Examples

      iex> remove_translation(record, "es-ES")
      {:ok, %EntityData{}}

      iex> remove_translation(record, "en-US")
      {:error, :cannot_remove_primary}
  """
  def remove_translation(%__MODULE__{data: data} = entity_data, lang_code)
      when is_binary(lang_code) do
    if Multilang.multilang_data?(data) do
      primary = data["_primary_language"]

      if lang_code == primary do
        {:error, :cannot_remove_primary}
      else
        updated_data = Map.delete(data, lang_code)
        __MODULE__.update(entity_data, %{data: updated_data})
      end
    else
      {:error, :not_multilang}
    end
  end

  @doc """
  Gets the title translation for a specific language.

  Reads from `data[lang]["_title"]` (unified JSONB storage). Falls back to
  the old `metadata["translations"]` location for unmigrated records, and
  finally to the `title` column.

  ## Examples

      iex> get_title_translation(record, "en-US")
      "My Product"

      iex> get_title_translation(record, "es-ES")
      "Mi Producto"
  """
  def get_title_translation(%__MODULE__{} = entity_data, lang_code)
      when is_binary(lang_code) do
    case Multilang.get_language_data(entity_data.data, lang_code) do
      %{"_title" => title} when is_binary(title) and title != "" ->
        title

      _ ->
        # Transitional fallback: check old metadata location for unmigrated records
        case get_in(entity_data.metadata || %{}, ["translations", lang_code, "title"]) do
          title when is_binary(title) and title != "" -> title
          _ -> entity_data.title
        end
    end
  end

  @doc """
  Sets the title translation for a specific language.

  Stores `_title` in the JSONB `data` column using `put_language_data`.
  For the primary language, also updates the `title` DB column.

  ## Examples

      iex> set_title_translation(record, "es-ES", "Mi Producto")
      {:ok, %EntityData{}}

      iex> set_title_translation(record, "en-US", "My Product")
      {:ok, %EntityData{}}
  """
  def set_title_translation(%__MODULE__{} = entity_data, lang_code, title)
      when is_binary(lang_code) and is_binary(title) do
    # Merge _title into existing raw overrides to preserve other fields
    existing_lang_data = Multilang.get_raw_language_data(entity_data.data, lang_code)
    merged = Map.put(existing_lang_data, "_title", title)
    updated_data = Multilang.put_language_data(entity_data.data, lang_code, merged)

    # If setting primary language, also update the DB column
    primary = (entity_data.data || %{})["_primary_language"] || Multilang.primary_language()
    attrs = %{data: updated_data}
    attrs = if lang_code == primary, do: Map.put(attrs, :title, title), else: attrs

    __MODULE__.update(entity_data, attrs)
  end

  @doc """
  Gets all title translations for a record.

  Returns a map of language codes to title strings.

  ## Examples

      iex> get_all_title_translations(record)
      %{"en-US" => "My Product", "es-ES" => "Mi Producto", "fr-FR" => "Mon Produit"}
  """
  def get_all_title_translations(%__MODULE__{} = entity_data) do
    Multilang.enabled_languages()
    |> Map.new(fn lang ->
      {lang, get_title_translation(entity_data, lang)}
    end)
  end

  # ============================================================================
  # Language-aware API
  # ============================================================================

  @doc """
  Resolves translated fields on an entity data record for a given language.

  Resolves the `title` from `_title` in the language's data, and replaces
  the `data` field with the merged language data (primary as base + overrides).

  For the primary language or flat (non-multilang) data, the struct is
  returned with the primary language data resolved. When no translation
  exists for a field, the primary language value is used as fallback.

  ## Examples

      iex> resolve_language(record, "es-ES")
      %EntityData{title: "Mi Producto", data: %{"name" => "Acme España", ...}}

      iex> resolve_language(record, "en-US")  # primary language
      %EntityData{title: "My Product", data: %{"name" => "Acme", ...}}
  """
  @spec resolve_language(t(), String.t()) :: t()
  def resolve_language(%__MODULE__{} = record, lang_code) when is_binary(lang_code) do
    resolved_title = get_title_translation(record, lang_code)
    resolved_data = Multilang.get_language_data(record.data, lang_code)

    %{record | title: resolved_title, data: resolved_data}
  end

  @doc """
  Resolves translations on a list of entity data records.

  ## Examples

      iex> resolve_languages(records, "es-ES")
      [%EntityData{title: "Mi Producto"}, ...]
  """
  @spec resolve_languages([t()], String.t()) :: [t()]
  def resolve_languages(records, lang_code) when is_list(records) and is_binary(lang_code) do
    Enum.map(records, &resolve_language(&1, lang_code))
  end

  # Returns the Ecto order_by clause based on the entity's sort_mode setting.
  # "manual" mode sorts by position ASC (with nulls last via date_created fallback).
  # "auto" mode (default) sorts by date_created DESC.
  #
  # Accepts opts with :sort_mode to skip the entity lookup when the caller
  # already has the entity loaded. Falls back to a DB lookup by entity_uuid.
  defp resolve_sort_order(entity_uuid, opts) do
    mode =
      case Keyword.get(opts, :sort_mode) do
        nil -> entity_sort_mode_from_db(entity_uuid)
        mode -> mode
      end

    sort_order_for_mode(mode)
  end

  defp entity_sort_mode_from_db(entity_uuid) when is_binary(entity_uuid) do
    case Entities.get_entity(entity_uuid) do
      %{settings: %{"sort_mode" => mode}} -> mode
      _ -> "auto"
    end
  end

  defp entity_sort_mode_from_db(_), do: "auto"

  defp sort_order_for_mode("manual"), do: [asc_nulls_last: :position, desc: :date_created]
  defp sort_order_for_mode(_), do: [desc: :date_created]

  # Applies :lang option to a single record if present in opts
  defp maybe_resolve_lang(record, opts) when is_list(opts) do
    case Keyword.get(opts, :lang) do
      nil -> record
      lang -> resolve_language(record, lang)
    end
  end

  # Applies :lang option to a list of records if present in opts
  defp maybe_resolve_langs(records, opts) when is_list(records) and is_list(opts) do
    case Keyword.get(opts, :lang) do
      nil -> records
      lang -> resolve_languages(records, lang)
    end
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
