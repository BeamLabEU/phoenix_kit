defmodule PhoenixKit.Modules.Entities.EntityData do
  @moduledoc """
  Entity data records for PhoenixKit entities system.

  This module manages actual data records that follow entity blueprints.
  Each record is associated with an entity type and stores its field values
  in a JSONB column for flexibility.

  ## Schema Fields

  - `entity_id`: Foreign key to the entity blueprint
  - `title`: Display title/name for the record
  - `slug`: URL-friendly identifier (optional)
  - `status`: Record status ("draft", "published", "archived")
  - `data`: JSONB map of all field values based on entity definition
  - `metadata`: JSONB map for additional information (tags, categories, etc.)
  - `created_by`: User ID who created the record
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
        entity_id: brand_entity.id,
        title: "Acme Corporation",
        slug: "acme-corporation",
        status: "published",
        created_by: user.id,
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
      records = PhoenixKit.Modules.Entities.EntityData.list_by_entity(brand_entity.id)

      # Search by title
      results = PhoenixKit.Modules.Entities.EntityData.search_by_title("Acme", brand_entity.id)
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
  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @derive {Jason.Encoder,
           only: [
             :id,
             :uuid,
             :title,
             :slug,
             :status,
             :data,
             :metadata,
             :date_created,
             :date_updated
           ]}

  schema "phoenix_kit_entity_data" do
    field :id, :integer, read_after_writes: true
    field :title, :string
    field :slug, :string
    field :status, :string, default: "published"
    field :data, :map
    field :metadata, :map
    # legacy
    field :created_by, :integer
    field :created_by_uuid, UUIDv7
    field :date_created, :utc_datetime
    field :date_updated, :utc_datetime

    # legacy
    field :entity_id, :integer
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
      :entity_id,
      :entity_uuid,
      :title,
      :slug,
      :status,
      :data,
      :metadata,
      :created_by,
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
    entity_id = get_field(changeset, :entity_id)
    entity_uuid = get_field(changeset, :entity_uuid)

    if is_nil(entity_id) and is_nil(entity_uuid) do
      add_error(changeset, :entity_uuid, "either entity_id or entity_uuid must be present")
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
    entity_id = get_field(changeset, :entity_id) || get_field(changeset, :entity_uuid)
    data = get_field(changeset, :data)

    case {entity_id, data} do
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
    entity_id = get_field(changeset, :entity_id) || get_field(changeset, :entity_uuid)
    data = get_field(changeset, :data)

    case entity_id do
      nil ->
        changeset

      id ->
        case Entities.get_entity!(id) do
          nil ->
            add_error(changeset, :entity_id, gettext("does not exist"))

          entity ->
            validate_data_fields(changeset, entity, data || %{})
        end
    end
  rescue
    Ecto.NoResultsError ->
      add_error(changeset, :entity_id, gettext("does not exist"))
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
    Events.broadcast_data_created(entity_data.entity_id, entity_data.id)
    maybe_mirror_data(entity_data)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :updated) do
    Events.broadcast_data_updated(entity_data.entity_id, entity_data.id)
    maybe_mirror_data(entity_data)
    {:ok, entity_data}
  end

  defp notify_data_event({:ok, %__MODULE__{} = entity_data}, :deleted) do
    Events.broadcast_data_deleted(entity_data.entity_id, entity_data.id)
    maybe_delete_mirrored_data(entity_data)
    {:ok, entity_data}
  end

  defp notify_data_event(result, _event), do: result

  # Mirror export helpers for auto-sync (per-entity settings)
  defp maybe_mirror_data(entity_data) do
    # Check if the parent entity has data mirroring enabled
    case Entities.get_entity(entity_data.entity_id) do
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
    case Entities.get_entity(entity_data.entity_id) do
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
  def list_all do
    from(d in __MODULE__,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
  end

  @doc """
  Returns all entity data records for a specific entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.list_by_entity(1)
      [%PhoenixKit.Modules.Entities.EntityData{entity_id: 1}, ...]
  """
  def list_by_entity(entity_uuid) when is_binary(entity_uuid) do
    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
  end

  def list_by_entity(entity_id) when is_integer(entity_id) do
    from(d in __MODULE__,
      where: d.entity_id == ^entity_id,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
  end

  @doc """
  Returns entity data records filtered by entity and status.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.list_by_entity_and_status(1, "published")
      [%PhoenixKit.Modules.Entities.EntityData{entity_id: 1, status: "published"}, ...]
  """
  def list_by_entity_and_status(entity_uuid, status)
      when is_binary(entity_uuid) and status in @valid_statuses do
    from(d in __MODULE__,
      where: d.entity_uuid == ^entity_uuid and d.status == ^status,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
  end

  def list_by_entity_and_status(entity_id, status)
      when is_integer(entity_id) and status in @valid_statuses do
    from(d in __MODULE__,
      where: d.entity_id == ^entity_id and d.status == ^status,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
  end

  @doc """
  Gets a single entity data record by ID or UUID.

  Accepts:
  - Integer ID (primary key)
  - UUID string
  - String that parses to integer

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get(123)
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get(456)
      nil
  """
  def get(id) when is_integer(id) do
    case repo().get_by(__MODULE__, id: id) do
      nil -> nil
      record -> repo().preload(record, [:entity, :creator])
    end
  end

  def get(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      case repo().get_by(__MODULE__, uuid: id) do
        nil -> nil
        record -> repo().preload(record, [:entity, :creator])
      end
    else
      case Integer.parse(id) do
        {int_id, ""} -> get(int_id)
        _ -> nil
      end
    end
  end

  def get(_), do: nil

  @doc """
  Gets a single entity data record by ID or UUID.

  Accepts:
  - Integer ID (primary key)
  - UUID string
  - String that parses to integer

  Raises `Ecto.NoResultsError` if the record does not exist.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get!(123)
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get!("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get!(456)
      ** (Ecto.NoResultsError)
  """
  def get!(id) do
    case get(id) do
      nil -> raise Ecto.NoResultsError, queryable: __MODULE__
      record -> record
    end
  end

  @doc """
  Gets a single entity data record by entity and slug.

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get_by_slug(1, "acme-corporation")
      %PhoenixKit.Modules.Entities.EntityData{}

      iex> PhoenixKit.Modules.Entities.EntityData.get_by_slug(1, "invalid")
      nil
  """
  def get_by_slug(entity_uuid, slug) when is_binary(entity_uuid) and is_binary(slug) do
    case repo().get_by(__MODULE__, entity_uuid: entity_uuid, slug: slug) do
      nil -> nil
      record -> repo().preload(record, [:entity, :creator])
    end
  end

  def get_by_slug(entity_id, slug) when is_integer(entity_id) and is_binary(slug) do
    case repo().get_by(__MODULE__, entity_id: entity_id, slug: slug) do
      nil -> nil
      record -> repo().preload(record, [:entity, :creator])
    end
  end

  @doc """
  Creates an entity data record.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.create(%{entity_id: 1, title: "Test"})
      {:ok, %PhoenixKit.Modules.Entities.EntityData{}}

      iex> PhoenixKit.Modules.Entities.EntityData.create(%{title: ""})
      {:error, %Ecto.Changeset{}}

  Note: `created_by` is auto-filled with the first admin or user ID if not provided,
  but only if at least one user exists in the system. If no users exist, the changeset
  will fail with a validation error on `created_by`.
  """
  def create(attrs \\ %{}) do
    attrs = maybe_add_created_by(attrs)

    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
    |> notify_data_event(:created)
  end

  # Auto-fill created_by with first admin if not provided
  defp maybe_add_created_by(attrs) when is_map(attrs) do
    has_created_by =
      Map.has_key?(attrs, :created_by) or Map.has_key?(attrs, "created_by")

    if has_created_by do
      # Ensure created_by_uuid is also set when created_by is present
      has_uuid = Map.has_key?(attrs, :created_by_uuid) or Map.has_key?(attrs, "created_by_uuid")

      if has_uuid do
        attrs
      else
        created_by_val = attrs[:created_by] || attrs["created_by"]

        if is_integer(created_by_val) do
          put_created_by_with_uuid(attrs, created_by_val)
        else
          attrs
        end
      end
    else
      case Auth.get_first_admin_id() do
        nil ->
          # Fall back to first user if no admin exists
          case Auth.get_first_user_id() do
            nil -> attrs
            user_id -> put_created_by_with_uuid(attrs, user_id)
          end

        admin_id ->
          put_created_by_with_uuid(attrs, admin_id)
      end
    end
  end

  defp put_created_by_with_uuid(attrs, user_id) when is_integer(user_id) do
    import Ecto.Query, only: [from: 2]
    alias PhoenixKit.Users.Auth.User

    user_uuid =
      from(u in User, where: u.id == ^user_id, select: u.uuid)
      |> PhoenixKit.RepoHelper.repo().one()

    attrs
    |> Map.put(:created_by, user_id)
    |> Map.put(:created_by_uuid, user_uuid)
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

      iex> PhoenixKit.Modules.Entities.EntityData.search_by_title("Acme", 1)
      [%PhoenixKit.Modules.Entities.EntityData{}, ...]
  """
  def search_by_title(search_term, entity_id \\ nil) when is_binary(search_term) do
    search_pattern = "%#{search_term}%"

    query =
      from(d in __MODULE__,
        where: ilike(d.title, ^search_pattern),
        order_by: [desc: d.date_created],
        preload: [:entity, :creator]
      )

    query =
      case entity_id do
        nil ->
          query

        id when is_binary(id) ->
          from(d in query, where: d.entity_uuid == ^id)

        id when is_integer(id) ->
          from(d in query, where: d.entity_id == ^id)
      end

    repo().all(query)
  end

  @doc """
  Gets all published records for a specific entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.published_records(1)
      [%PhoenixKit.Modules.Entities.EntityData{status: "published"}, ...]
  """
  def published_records(entity_uuid) when is_binary(entity_uuid) do
    list_by_entity_and_status(entity_uuid, "published")
  end

  def published_records(entity_id) when is_integer(entity_id) do
    list_by_entity_and_status(entity_id, "published")
  end

  @doc """
  Counts the total number of records for an entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.count_by_entity(1)
      42
  """
  def count_by_entity(entity_uuid) when is_binary(entity_uuid) do
    from(d in __MODULE__, where: d.entity_uuid == ^entity_uuid, select: count(d.id))
    |> repo().one()
  end

  def count_by_entity(entity_id) when is_integer(entity_id) do
    from(d in __MODULE__, where: d.entity_id == ^entity_id, select: count(d.id))
    |> repo().one()
  end

  @doc """
  Gets records filtered by status across all entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.filter_by_status("draft")
      [%PhoenixKit.Modules.Entities.EntityData{status: "draft"}, ...]
  """
  def filter_by_status(status) when status in @valid_statuses do
    from(d in __MODULE__,
      where: d.status == ^status,
      order_by: [desc: d.date_created],
      preload: [:entity, :creator]
    )
    |> repo().all()
  end

  @doc """
  Alias for list_all/0 for consistency with LiveView naming.
  """
  def list_all_data, do: list_all()

  @doc """
  Alias for list_by_entity/1 for consistency with LiveView naming.
  """
  def list_data_by_entity(entity_id), do: list_by_entity(entity_id)

  @doc """
  Alias for filter_by_status/1 for consistency with LiveView naming.
  """
  def list_data_by_status(status), do: filter_by_status(status)

  @doc """
  Alias for search_by_title/1 for consistency with LiveView naming.
  """
  def search_data(search_term), do: search_by_title(search_term)

  @doc """
  Alias for get!/1 for consistency with LiveView naming.
  """
  def get_data!(id), do: get!(id)

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
  Bulk updates the category of multiple records by UUIDs.

  Uses PostgreSQL jsonb_set to update the category field in the JSONB
  data column in a single query.

  Returns a tuple with the count of updated records and nil.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.bulk_update_category(["uuid1", "uuid2"], "New Category")
      {2, nil}
  """
  def bulk_update_category(uuids, category) when is_list(uuids) do
    now = UtilsDate.utc_now()

    # Handle both flat and multilang data structures.
    # For multilang: update category in every language sub-map.
    # For flat: update category at the top level.
    # We detect multilang by checking for the _primary_language key.
    from(d in __MODULE__,
      where: d.uuid in ^uuids,
      update: [
        set: [
          data:
            fragment(
              """
              CASE WHEN jsonb_exists(COALESCE(?, '{}'::jsonb), '_primary_language')
              THEN (
                SELECT jsonb_object_agg(
                  key,
                  CASE
                    WHEN jsonb_typeof(value) = 'object'
                    THEN jsonb_set(value, '{category}', to_jsonb(?::text))
                    ELSE value
                  END
                )
                FROM jsonb_each(COALESCE(?, '{}'::jsonb))
              )
              ELSE jsonb_set(COALESCE(?, '{}'::jsonb), '{category}', to_jsonb(?::text))
              END
              """,
              d.data,
              ^category,
              d.data,
              d.data,
              ^category
            ),
          date_updated: ^now
        ]
      ]
    )
    |> repo().update_all([])
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
  Extracts unique categories from a list of entity data records.

  Returns a sorted list of unique category values, excluding nil and empty strings.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.extract_unique_categories(records)
      ["Category A", "Category B", "Category C"]
  """
  def extract_unique_categories(entity_data_records) when is_list(entity_data_records) do
    entity_data_records
    |> Enum.map(fn r ->
      data = r.data || %{}

      if Multilang.multilang_data?(data) do
        primary = data["_primary_language"]
        get_in(data, [primary, "category"])
      else
        Map.get(data, "category")
      end
    end)
    |> Enum.reject(&(&1 == nil || &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Gets statistical data about entity data records.

  Returns statistics about total records, published, draft, and archived counts.
  Optionally filters by entity_id if provided.

  ## Examples

      iex> PhoenixKit.Modules.Entities.EntityData.get_data_stats()
      %{
        total_records: 150,
        published_records: 120,
        draft_records: 25,
        archived_records: 5
      }

      iex> PhoenixKit.Modules.Entities.EntityData.get_data_stats(1)
      %{
        total_records: 15,
        published_records: 12,
        draft_records: 2,
        archived_records: 1
      }
  """
  def get_data_stats(entity_id \\ nil) do
    query =
      from(d in __MODULE__,
        select: {
          count(d.id),
          count(fragment("CASE WHEN ? = 'published' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'draft' THEN 1 END", d.status)),
          count(fragment("CASE WHEN ? = 'archived' THEN 1 END", d.status))
        }
      )

    query =
      case entity_id do
        nil ->
          query

        id when is_binary(id) ->
          from(d in query, where: d.entity_uuid == ^id)

        id when is_integer(id) ->
          from(d in query, where: d.entity_id == ^id)
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

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
