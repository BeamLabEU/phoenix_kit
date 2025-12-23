defmodule PhoenixKit.Entities.EntityData do
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
      {:ok, data} = PhoenixKit.Entities.EntityData.create(%{
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
      records = PhoenixKit.Entities.EntityData.list_by_entity(brand_entity.id)

      # Search by title
      results = PhoenixKit.Entities.EntityData.search_by_title("Acme", brand_entity.id)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.Events
  alias PhoenixKit.Entities.HtmlSanitizer
  alias PhoenixKit.Entities.Mirror.Exporter
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  @primary_key {:id, :id, autogenerate: true}

  @derive {Jason.Encoder,
           only: [
             :title,
             :slug,
             :status,
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
    field :created_by, :integer
    field :date_created, :utc_datetime_usec
    field :date_updated, :utc_datetime_usec

    belongs_to :entity, Entities, foreign_key: :entity_id, define_field: true
    belongs_to :creator, User, foreign_key: :created_by, define_field: false
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
      :title,
      :slug,
      :status,
      :data,
      :metadata,
      :created_by,
      :date_created,
      :date_updated
    ])
    |> validate_required([:entity_id, :title, :created_by])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:slug, max: 255)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_slug_format()
    |> sanitize_rich_text_data()
    |> validate_data_against_entity()
    |> foreign_key_constraint(:entity_id)
    |> maybe_set_timestamps()
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
            "must contain only lowercase letters, numbers, and hyphens"
          )
        end
    end
  end

  defp sanitize_rich_text_data(changeset) do
    entity_id = get_field(changeset, :entity_id)
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
          sanitized_data = HtmlSanitizer.sanitize_rich_text_fields(fields_definition, data)
          put_change(changeset, :data, sanitized_data)
        rescue
          Ecto.NoResultsError -> changeset
        end
    end
  end

  defp validate_data_against_entity(changeset) do
    entity_id = get_field(changeset, :entity_id)
    data = get_field(changeset, :data)

    case entity_id do
      nil ->
        changeset

      id ->
        case Entities.get_entity!(id) do
          nil ->
            add_error(changeset, :entity_id, "does not exist")

          entity ->
            validate_data_fields(changeset, entity, data || %{})
        end
    end
  rescue
    Ecto.NoResultsError ->
      add_error(changeset, :entity_id, "does not exist")
  end

  defp validate_data_fields(changeset, entity, data) do
    fields_definition = entity.fields_definition || []

    Enum.reduce(fields_definition, changeset, fn field_def, acc ->
      validate_single_data_field(acc, field_def, data)
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
          "field '#{field_def["label"]}' is required"
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
      add_error(changeset, :data, "field '#{field_def["label"]}' must be a number")
    end
  end

  defp validate_boolean_field(changeset, field_def, value) do
    if is_boolean(value) do
      changeset
    else
      add_error(changeset, :data, "field '#{field_def["label"]}' must be true or false")
    end
  end

  defp validate_email_field(changeset, field_def, value) do
    if is_binary(value) && Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value) do
      changeset
    else
      add_error(changeset, :data, "field '#{field_def["label"]}' must be a valid email")
    end
  end

  defp validate_url_field(changeset, field_def, value) do
    if is_binary(value) && String.starts_with?(value, ["http://", "https://"]) do
      changeset
    else
      add_error(changeset, :data, "field '#{field_def["label"]}' must be a valid URL")
    end
  end

  defp validate_date_field(changeset, field_def, value) do
    if is_binary(value) && Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) do
      changeset
    else
      add_error(
        changeset,
        :data,
        "field '#{field_def["label"]}' must be a valid date (YYYY-MM-DD)"
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
        "field '#{field_def["label"]}' must be one of: #{Enum.join(options, ", ")}"
      )
    end
  end

  defp maybe_set_timestamps(changeset) do
    case get_field(changeset, :id) do
      nil ->
        now = DateTime.utc_now()

        changeset
        |> put_change(:date_created, now)
        |> put_change(:date_updated, now)

      _id ->
        put_change(changeset, :date_updated, DateTime.utc_now())
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

      iex> PhoenixKit.Entities.EntityData.list_all()
      [%PhoenixKit.Entities.EntityData{}, ...]
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

      iex> PhoenixKit.Entities.EntityData.list_by_entity(1)
      [%PhoenixKit.Entities.EntityData{entity_id: 1}, ...]
  """
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

      iex> PhoenixKit.Entities.EntityData.list_by_entity_and_status(1, "published")
      [%PhoenixKit.Entities.EntityData{entity_id: 1, status: "published"}, ...]
  """
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
  Gets a single entity data record by ID.

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.get(123)
      %PhoenixKit.Entities.EntityData{}

      iex> PhoenixKit.Entities.EntityData.get(456)
      nil
  """
  def get(id) do
    case repo().get(__MODULE__, id) do
      nil -> nil
      record -> repo().preload(record, [:entity, :creator])
    end
  end

  @doc """
  Gets a single entity data record by ID.

  Raises `Ecto.NoResultsError` if the record does not exist.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.get!(123)
      %PhoenixKit.Entities.EntityData{}

      iex> PhoenixKit.Entities.EntityData.get!(456)
      ** (Ecto.NoResultsError)
  """
  def get!(id) do
    repo().get!(__MODULE__, id) |> repo().preload([:entity, :creator])
  end

  @doc """
  Gets a single entity data record by entity and slug.

  Returns the record if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.get_by_slug(1, "acme-corporation")
      %PhoenixKit.Entities.EntityData{}

      iex> PhoenixKit.Entities.EntityData.get_by_slug(1, "invalid")
      nil
  """
  def get_by_slug(entity_id, slug) when is_integer(entity_id) and is_binary(slug) do
    repo().get_by(__MODULE__, entity_id: entity_id, slug: slug)
    |> repo().preload([:entity, :creator])
  end

  @doc """
  Creates an entity data record.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.create(%{entity_id: 1, title: "Test"})
      {:ok, %PhoenixKit.Entities.EntityData{}}

      iex> PhoenixKit.Entities.EntityData.create(%{title: ""})
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
      attrs
    else
      case Auth.get_first_admin_id() do
        nil ->
          # Fall back to first user if no admin exists
          case Auth.get_first_user_id() do
            nil -> attrs
            user_id -> Map.put(attrs, :created_by, user_id)
          end

        admin_id ->
          Map.put(attrs, :created_by, admin_id)
      end
    end
  end

  @doc """
  Updates an entity data record.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.update(record, %{title: "Updated"})
      {:ok, %PhoenixKit.Entities.EntityData{}}

      iex> PhoenixKit.Entities.EntityData.update(record, %{title: ""})
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

      iex> PhoenixKit.Entities.EntityData.delete(record)
      {:ok, %PhoenixKit.Entities.EntityData{}}

      iex> PhoenixKit.Entities.EntityData.delete(record)
      {:error, %Ecto.Changeset{}}
  """
  def delete(%__MODULE__{} = entity_data) do
    repo().delete(entity_data)
    |> notify_data_event(:deleted)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking entity data changes.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.change(record)
      %Ecto.Changeset{data: %PhoenixKit.Entities.EntityData{}}
  """
  def change(%__MODULE__{} = entity_data, attrs \\ %{}) do
    changeset(entity_data, attrs)
  end

  @doc """
  Searches entity data records by title.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.search_by_title("Acme", 1)
      [%PhoenixKit.Entities.EntityData{}, ...]
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
      if entity_id do
        from(d in query, where: d.entity_id == ^entity_id)
      else
        query
      end

    repo().all(query)
  end

  @doc """
  Gets all published records for a specific entity.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.published_records(1)
      [%PhoenixKit.Entities.EntityData{status: "published"}, ...]
  """
  def published_records(entity_id) when is_integer(entity_id) do
    list_by_entity_and_status(entity_id, "published")
  end

  @doc """
  Counts the total number of records for an entity.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.count_by_entity(1)
      42
  """
  def count_by_entity(entity_id) when is_integer(entity_id) do
    from(d in __MODULE__, where: d.entity_id == ^entity_id, select: count(d.id))
    |> repo().one()
  end

  @doc """
  Gets records filtered by status across all entities.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.filter_by_status("draft")
      [%PhoenixKit.Entities.EntityData{status: "draft"}, ...]
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
  Gets statistical data about entity data records.

  Returns statistics about total records, published, draft, and archived counts.
  Optionally filters by entity_id if provided.

  ## Examples

      iex> PhoenixKit.Entities.EntityData.get_data_stats()
      %{
        total_records: 150,
        published_records: 120,
        draft_records: 25,
        archived_records: 5
      }

      iex> PhoenixKit.Entities.EntityData.get_data_stats(1)
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
      if entity_id do
        from(d in query, where: d.entity_id == ^entity_id)
      else
        query
      end

    {total, published, draft, archived} = repo().one(query)

    %{
      total_records: total,
      published_records: published,
      draft_records: draft,
      archived_records: archived
    }
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
