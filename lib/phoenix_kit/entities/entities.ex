defmodule PhoenixKit.Entities do
  @moduledoc """
  Dynamic entity system for PhoenixKit - WordPress ACF equivalent.

  This module provides both the Ecto schema definition and business logic for
  managing custom content types (entities) with flexible field schemas.

  ## Schema Fields

  - `name`: Unique identifier for the entity (e.g., "blog_post", "product")
  - `display_name`: Human-readable name shown in UI (e.g., "Blog Post", "Product")
  - `description`: Description of what this entity represents
  - `icon`: Icon identifier for UI display (hero icons)
  - `status`: Boolean indicating if the entity is active
  - `fields_definition`: JSONB array of field definitions
  - `settings`: JSONB map of entity-specific settings
  - `created_by`: User ID of the admin who created the entity
  - `date_created`: When the entity was created
  - `date_updated`: When the entity was last modified

  ## Field Definition Structure

  Each field in `fields_definition` is a map with:
  - `type`: Field type (text, textarea, number, boolean, date, select, etc.)
  - `key`: Unique field identifier (snake_case)
  - `label`: Display label for the field
  - `required`: Whether the field is required
  - `default`: Default value
  - `validation`: Map of validation rules
  - `options`: Array of options (for select, radio, checkbox types)

  ## Core Functions

  ### Entity Management
  - `list_entities/0` - Get all entities
  - `list_active_entities/0` - Get only active entities
  - `get_entity!/1` - Get an entity by ID (raises if not found)
  - `get_entity_by_name/1` - Get an entity by its name
  - `create_entity/1` - Create a new entity
  - `update_entity/2` - Update an existing entity
  - `delete_entity/1` - Delete an entity (and all its data)
  - `change_entity/2` - Get changeset for forms

  ### System Settings
  - `enabled?/0` - Check if entities system is enabled
  - `enabled?/0` - Check if entities system is enabled
  - `enable_system/0` - Enable the entities system
  - `disable_system/0` - Disable the entities system
  - `get_config/0` - Get current system configuration
  - `get_max_per_user/0` - Get max entities per user limit
  - `validate_user_entity_limit/1` - Check if user can create more entities

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKit.Entities.enabled?() do
        # System is active
      end

      # Create a blog post entity
      {:ok, entity} = PhoenixKit.Entities.create_entity(%{
        name: "blog_post",
        display_name: "Blog Post",
        description: "Blog post content type",
        icon: "hero-document-text",
        created_by: admin_user.id,
        fields_definition: [
          %{type: "text", key: "title", label: "Title", required: true},
          %{type: "textarea", key: "excerpt", label: "Excerpt"},
          %{type: "rich_text", key: "content", label: "Content", required: true},
          %{type: "select", key: "category", label: "Category",
            options: ["Tech", "Business", "Lifestyle"]},
          %{type: "date", key: "publish_date", label: "Publish Date"},
          %{type: "boolean", key: "featured", label: "Featured Post"}
        ]
      })

      # Get entity by name
      entity = PhoenixKit.Entities.get_entity_by_name("blog_post")

      # List all active entities
      entities = PhoenixKit.Entities.list_active_entities()
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Entities.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User

  @primary_key {:id, :id, autogenerate: true}
  @valid_statuses ~w(draft published archived)

  schema "phoenix_kit_entities" do
    field :name, :string
    field :display_name, :string
    field :display_name_plural, :string
    field :description, :string
    field :icon, :string
    field :status, :string, default: "published"
    field :fields_definition, {:array, :map}
    field :settings, :map
    field :created_by, :integer
    field :date_created, :utc_datetime_usec
    field :date_updated, :utc_datetime_usec

    belongs_to :creator, User, foreign_key: :created_by, define_field: false
    has_many :entity_data, PhoenixKit.Entities.EntityData, foreign_key: :entity_id
  end

  @doc """
  Creates a changeset for entity creation and updates.

  Validates that name is unique, fields_definition is valid, and all required fields are present.
  Automatically sets date_created on new records.
  """
  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :name,
      :display_name,
      :display_name_plural,
      :description,
      :icon,
      :status,
      :fields_definition,
      :settings,
      :created_by,
      :date_created,
      :date_updated
    ])
    |> validate_required([:name, :display_name, :display_name_plural, :created_by])
    |> validate_length(:name, min: 2, max: 50)
    |> validate_length(:display_name, min: 2, max: 100)
    |> validate_length(:display_name_plural, min: 2, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a letter and contain only lowercase letters, numbers, and underscores"
    )
    |> validate_name_uniqueness()
    |> validate_fields_definition()
    |> unique_constraint(:name)
    |> maybe_set_timestamps()
  end

  defp validate_name_uniqueness(changeset) do
    case get_field(changeset, :name) do
      nil ->
        changeset

      "" ->
        changeset

      name ->
        case get_entity_by_name(name) do
          nil ->
            changeset

          existing_entity ->
            current_id = get_field(changeset, :id)

            if current_id && existing_entity.id == current_id do
              changeset
            else
              add_error(changeset, :name, "has already been taken")
            end
        end
    end
  end

  defp validate_fields_definition(changeset) do
    case get_field(changeset, :fields_definition) do
      nil ->
        put_change(changeset, :fields_definition, [])

      fields when is_list(fields) ->
        validate_each_field_definition(changeset, fields)

      _invalid ->
        add_error(changeset, :fields_definition, "must be a list of field definitions")
    end
  end

  defp validate_each_field_definition(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      validate_single_field_definition(acc, field)
    end)
  end

  defp validate_single_field_definition(changeset, field) when is_map(field) do
    required_keys = ["type", "key", "label"]
    missing_keys = required_keys -- Map.keys(field)

    if Enum.empty?(missing_keys) do
      validate_field_type(changeset, field)
    else
      add_error(
        changeset,
        :fields_definition,
        "field missing required keys: #{Enum.join(missing_keys, ", ")}"
      )
    end
  end

  defp validate_single_field_definition(changeset, _invalid) do
    add_error(changeset, :fields_definition, "each field must be a map")
  end

  defp validate_field_type(changeset, field) do
    valid_types =
      ~w(text textarea number boolean date email url select radio checkbox rich_text image file relation)

    if field["type"] in valid_types do
      changeset
    else
      add_error(
        changeset,
        :fields_definition,
        "invalid field type '#{field["type"]}' for field '#{field["key"]}'"
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

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :created) do
    Events.broadcast_entity_created(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :updated) do
    Events.broadcast_entity_updated(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :deleted) do
    Events.broadcast_entity_deleted(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event(result, _event), do: result

  @doc """
  Returns the list of entities ordered by creation date.

  ## Examples

      iex> PhoenixKit.Entities.list_entities()
      [%PhoenixKit.Entities{}, ...]
  """
  def list_entities do
    __MODULE__
    |> order_by([e], desc: e.date_created)
    |> preload([:creator])
    |> repo().all()
  end

  @doc """
  Returns the list of active entities.

  ## Examples

      iex> PhoenixKit.Entities.list_active_entities()
      [%PhoenixKit.Entities{status: true}, ...]
  """
  def list_active_entities do
    from(e in __MODULE__,
      where: e.status == "published",
      order_by: [desc: e.date_created],
      preload: [:creator]
    )
    |> repo().all()
  end

  @doc """
  Gets a single entity by ID.

  Raises `Ecto.NoResultsError` if the entity does not exist.

  ## Examples

      iex> PhoenixKit.Entities.get_entity!(123)
      %PhoenixKit.Entities{}

      iex> PhoenixKit.Entities.get_entity!(456)
      ** (Ecto.NoResultsError)
  """
  def get_entity!(id), do: repo().get!(__MODULE__, id) |> repo().preload(:creator)

  @doc """
  Gets a single entity by its unique name.

  Returns the entity if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Entities.get_entity_by_name("blog_post")
      %PhoenixKit.Entities{}

      iex> PhoenixKit.Entities.get_entity_by_name("invalid")
      nil
  """
  def get_entity_by_name(name) when is_binary(name) do
    repo().get_by(__MODULE__, name: name)
  end

  @doc """
  Creates an entity.

  ## Examples

      iex> PhoenixKit.Entities.create_entity(%{name: "blog_post", display_name: "Blog Post"})
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKit.Entities.create_entity(%{name: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_entity(attrs \\ %{}) do
    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
    |> notify_entity_event(:created)
  end

  @doc """
  Updates an entity.

  ## Examples

      iex> PhoenixKit.Entities.update_entity(entity, %{display_name: "Updated"})
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKit.Entities.update_entity(entity, %{name: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_entity(%__MODULE__{} = entity, attrs) do
    entity
    |> changeset(attrs)
    |> repo().update()
    |> notify_entity_event(:updated)
  end

  @doc """
  Deletes an entity.

  Note: This will also delete all associated entity_data records due to the on_delete: :delete_all constraint.

  ## Examples

      iex> PhoenixKit.Entities.delete_entity(entity)
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKit.Entities.delete_entity(entity)
      {:error, %Ecto.Changeset{}}
  """
  def delete_entity(%__MODULE__{} = entity) do
    repo().delete(entity)
    |> notify_entity_event(:deleted)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking entity changes.

  ## Examples

      iex> PhoenixKit.Entities.change_entity(entity)
      %Ecto.Changeset{data: %PhoenixKit.Entities{}}
  """
  def change_entity(%__MODULE__{} = entity, attrs \\ %{}) do
    changeset(entity, attrs)
  end

  @doc """
  Gets summary statistics for the entities system.

  Returns counts and metrics useful for admin dashboards.

  ## Examples

      iex> PhoenixKit.Entities.get_system_stats()
      %{total_entities: 5, active_entities: 4, total_data_records: 150}
  """
  def get_system_stats do
    entities_query = from(e in __MODULE__)
    data_query = from(d in PhoenixKit.Entities.EntityData)

    total_entities = repo().aggregate(entities_query, :count)

    active_entities =
      repo().aggregate(from(e in entities_query, where: e.status == "published"), :count)

    total_data_records = repo().aggregate(data_query, :count)

    %{
      total_entities: total_entities,
      active_entities: active_entities,
      total_data_records: total_data_records
    }
  end

  @doc """
  Counts the total number of entities created by a user.

  ## Examples

      iex> PhoenixKit.Entities.count_user_entities(1)
      5
  """
  def count_user_entities(user_id) when is_integer(user_id) do
    from(e in __MODULE__, where: e.created_by == ^user_id, select: count(e.id))
    |> repo().one()
  end

  @doc """
  Counts the total number of entities in the system.

  ## Examples

      iex> PhoenixKit.Entities.count_entities()
      15
  """
  def count_entities do
    from(e in __MODULE__, select: count(e.id))
    |> repo().one()
  end

  @doc """
  Counts the total number of entity data records across all entities.

  ## Examples

      iex> PhoenixKit.Entities.count_all_entity_data()
      243
  """
  def count_all_entity_data do
    from(d in PhoenixKit.Entities.EntityData, select: count(d.id))
    |> repo().one()
  end

  @doc """
  Validates that a user hasn't exceeded their entity creation limit.

  Checks the current number of entities created by the user against the system limit.
  Returns `{:ok, :valid}` if within limits, `{:error, reason}` if limit exceeded.

  ## Examples

      iex> PhoenixKit.Entities.validate_user_entity_limit(1)
      {:ok, :valid}

      iex> PhoenixKit.Entities.validate_user_entity_limit(1)
      {:error, "You have reached the maximum limit of 100 entities"}
  """
  def validate_user_entity_limit(user_id) when is_integer(user_id) do
    max_entities = get_max_per_user()
    current_count = count_user_entities(user_id)

    if current_count < max_entities do
      {:ok, :valid}
    else
      {:error, "You have reached the maximum limit of #{max_entities} entities"}
    end
  end

  @doc """
  Checks if the entities system is enabled.

  Returns true if the "entities_enabled" setting is true.

  ## Examples

      iex> PhoenixKit.Entities.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting("entities_enabled", false)
  end

  @doc """
  Enables the entities system.

  Sets the "entities_enabled" setting to true.

  ## Examples

      iex> PhoenixKit.Entities.enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("entities_enabled", true, "entities")
  end

  @doc """
  Disables the entities system.

  Sets the "entities_enabled" setting to false.

  ## Examples

      iex> PhoenixKit.Entities.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module("entities_enabled", false, "entities")
  end

  @doc """
  Gets the maximum number of entities a single user can create.

  Returns the system-wide limit for entity creation per user.
  Defaults to 100 if not set.

  ## Examples

      iex> PhoenixKit.Entities.get_max_per_user()
      100
  """
  def get_max_per_user do
    Settings.get_integer_setting("entities_max_per_user", 100)
  end

  @doc """
  Gets the current entities system configuration.

  Returns a map with the current settings.

  ## Examples

      iex> PhoenixKit.Entities.get_config()
      %{enabled: false, max_per_user: 100, allow_relations: true, file_upload: false, entity_count: 0, total_data_count: 0}
  """
  def get_config do
    %{
      enabled: enabled?(),
      max_per_user: get_max_per_user(),
      allow_relations: Settings.get_boolean_setting("entities_allow_relations", true),
      file_upload: Settings.get_boolean_setting("entities_file_upload", false),
      entity_count: count_entities(),
      total_data_count: count_all_entity_data()
    }
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
