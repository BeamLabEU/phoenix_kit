defmodule PhoenixKit.Modules.Entities do
  @moduledoc """
  Dynamic entity system for PhoenixKit.

  This module provides both the Ecto schema definition and business logic for
  managing custom content types (entities) with flexible field schemas.

  ## Schema Fields

  - `name`: Unique identifier for the entity (e.g., "brand", "product")
  - `display_name`: Human-readable singular name shown in UI (e.g., "Brand")
  - `display_name_plural`: Human-readable plural name (e.g., "Brands")
  - `description`: Description of what this entity represents
  - `icon`: Icon identifier for UI display (hero icons)
  - `status`: Workflow status string - one of "draft", "published", or "archived"
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
  - `enable_system/0` - Enable the entities system
  - `disable_system/0` - Disable the entities system
  - `get_config/0` - Get current system configuration
  - `get_max_per_user/0` - Get max entities per user limit
  - `validate_user_entity_limit/1` - Check if user can create more entities

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKit.Modules.Entities.enabled?() do
        # System is active
      end

      # Create a brand entity
      # Note: fields_definition requires string keys, not atom keys
      {:ok, entity} = PhoenixKit.Modules.Entities.create_entity(%{
        name: "brand",
        display_name: "Brand",
        display_name_plural: "Brands",
        description: "Brand content type for company profiles",
        icon: "hero-building-office",
        created_by_uuid: admin_user.uuid,
        fields_definition: [
          %{"type" => "text", "key" => "name", "label" => "Name", "required" => true},
          %{"type" => "textarea", "key" => "tagline", "label" => "Tagline"},
          %{"type" => "rich_text", "key" => "description", "label" => "Description", "required" => true},
          %{"type" => "select", "key" => "industry", "label" => "Industry",
            "options" => ["Technology", "Manufacturing", "Retail"]},
          %{"type" => "date", "key" => "founded_date", "label" => "Founded Date"},
          %{"type" => "boolean", "key" => "featured", "label" => "Featured Brand"}
        ]
      })

      # Get entity by name
      entity = PhoenixKit.Modules.Entities.get_entity_by_name("brand")

      # List all active entities
      entities = PhoenixKit.Modules.Entities.list_active_entities()
  """

  use Ecto.Schema
  use PhoenixKit.Module

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Entities.EntityData
  alias PhoenixKit.Modules.Entities.Events
  alias PhoenixKit.Modules.Entities.Mirror.Exporter
  alias PhoenixKit.Modules.Entities.Mirror.Storage
  alias PhoenixKit.Modules.Entities.Multilang
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_statuses ~w(draft published archived)

  @derive {Jason.Encoder,
           only: [
             :uuid,
             :name,
             :display_name,
             :display_name_plural,
             :description,
             :icon,
             :status,
             :fields_definition,
             :settings,
             :date_created,
             :date_updated
           ]}

  schema "phoenix_kit_entities" do
    field :name, :string
    field :display_name, :string
    field :display_name_plural, :string
    field :description, :string
    field :icon, :string
    field :status, :string, default: "published"
    field :fields_definition, {:array, :map}
    field :settings, :map
    # legacy
    field :created_by, :integer
    field :created_by_uuid, UUIDv7
    field :date_created, :utc_datetime
    field :date_updated, :utc_datetime

    belongs_to :creator, User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      define_field: false,
      type: UUIDv7

    has_many :entity_data, PhoenixKit.Modules.Entities.EntityData,
      foreign_key: :entity_uuid,
      references: :uuid
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
      :created_by_uuid,
      :date_created,
      :date_updated
    ])
    |> validate_required([:name, :display_name, :display_name_plural])
    |> validate_creator_reference()
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

  defp validate_creator_reference(changeset) do
    created_by = get_field(changeset, :created_by)
    created_by_uuid = get_field(changeset, :created_by_uuid)

    if is_nil(created_by) and is_nil(created_by_uuid) do
      add_error(
        changeset,
        :created_by_uuid,
        "either created_by or created_by_uuid must be present"
      )
    else
      changeset
    end
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
            current_uuid = get_field(changeset, :uuid)

            if current_uuid && existing_entity.uuid == current_uuid do
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

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :created) do
    Events.broadcast_entity_created(entity.uuid)
    maybe_mirror_entity(entity)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :updated) do
    Events.broadcast_entity_updated(entity.uuid)
    maybe_mirror_entity(entity)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %__MODULE__{} = entity}, :deleted) do
    Events.broadcast_entity_deleted(entity.uuid)
    maybe_delete_mirrored_entity(entity)
    {:ok, entity}
  end

  defp notify_entity_event(result, _event), do: result

  # Mirror export helpers for auto-sync (per-entity settings)
  defp maybe_mirror_entity(entity) do
    if mirror_definitions_enabled?(entity) do
      Task.start(fn -> Exporter.export_entity(entity) end)
    end
  end

  defp maybe_delete_mirrored_entity(entity) do
    # Delete the file if it exists (regardless of current setting)
    # This ensures cleanup when entity is deleted
    if Storage.entity_exists?(entity.name) do
      Task.start(fn ->
        Storage.delete_entity(entity.name)
      end)
    end
  end

  @doc """
  Returns the list of entities ordered by creation date.

  ## Examples

      iex> PhoenixKit.Modules.Entities.list_entities()
      [%PhoenixKit.Entities{}, ...]
  """
  def list_entities do
    __MODULE__
    |> order_by([e], desc: e.date_created)
    |> preload([:creator])
    |> repo().all()
  end

  @doc """
  Returns the list of active (published) entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.list_active_entities()
      [%PhoenixKit.Entities{status: "published"}, ...]
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
  Returns a lightweight list of published entity summaries for sidebar display.

  Selects only sidebar-relevant fields without preloading associations.
  """
  @spec list_entity_summaries() :: [map()]
  def list_entity_summaries do
    from(e in __MODULE__,
      where: e.status == "published",
      order_by: [desc: e.date_created],
      select: %{
        name: e.name,
        display_name: e.display_name,
        display_name_plural: e.display_name_plural,
        icon: e.icon
      }
    )
    |> repo().all()
  end

  @doc """
  Gets a single entity by integer ID or UUID.

  Returns the entity if found, nil otherwise.

  Accepts:
  - Integer ID (e.g., 123)
  - UUID string (e.g., "550e8400-e29b-41d4-a716-446655440000")
  - Integer string (e.g., "123")

  ## Examples

      iex> PhoenixKit.Modules.Entities.get_entity(123)
      %PhoenixKit.Entities{}

      iex> PhoenixKit.Modules.Entities.get_entity("550e8400-e29b-41d4-a716-446655440000")
      %PhoenixKit.Entities{}

      iex> PhoenixKit.Modules.Entities.get_entity(456)
      nil
  """
  def get_entity(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      case repo().get_by(__MODULE__, uuid: uuid) do
        nil -> nil
        entity -> repo().preload(entity, :creator)
      end
    else
      nil
    end
  end

  def get_entity(_), do: nil

  @doc """
  Gets a single entity by integer ID or UUID.

  Raises `Ecto.NoResultsError` if the entity does not exist.

  ## Examples

      iex> PhoenixKit.Modules.Entities.get_entity!(123)
      %PhoenixKit.Entities{}

      iex> PhoenixKit.Modules.Entities.get_entity!(456)
      ** (Ecto.NoResultsError)
  """
  def get_entity!(id) do
    case get_entity(id) do
      nil -> raise Ecto.NoResultsError, queryable: __MODULE__
      entity -> entity
    end
  end

  @doc """
  Gets a single entity by its unique name.

  Returns the entity if found, nil otherwise.

  ## Examples

      iex> PhoenixKit.Modules.Entities.get_entity_by_name("brand")
      %PhoenixKit.Entities{}

      iex> PhoenixKit.Modules.Entities.get_entity_by_name("invalid")
      nil
  """
  def get_entity_by_name(name) when is_binary(name) do
    repo().get_by(__MODULE__, name: name)
  end

  @doc """
  Creates an entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.create_entity(%{name: "brand", display_name: "Brand"})
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKit.Modules.Entities.create_entity(%{name: ""})
      {:error, %Ecto.Changeset{}}

  Note: `created_by` is auto-filled with the first admin or user ID if not provided,
  but only if at least one user exists in the system. If no users exist, the changeset
  will fail with a validation error on `created_by`.
  """
  def create_entity(attrs \\ %{}) do
    attrs = maybe_add_created_by(attrs)

    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
    |> notify_entity_event(:created)
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
        uuid = resolve_user_uuid(created_by_val)

        if is_map(attrs) and Map.has_key?(attrs, :created_by) do
          Map.put(attrs, :created_by_uuid, uuid)
        else
          Map.put(attrs, "created_by_uuid", uuid)
        end
      end
    else
      case Auth.get_first_admin_id() do
        nil ->
          # Fall back to first user if no admin exists
          case Auth.get_first_user_id() do
            nil ->
              attrs

            user_id ->
              attrs
              |> Map.put(:created_by, user_id)
              |> Map.put(:created_by_uuid, resolve_user_uuid(user_id))
          end

        admin_id ->
          attrs
          |> Map.put(:created_by, admin_id)
          |> Map.put(:created_by_uuid, resolve_user_uuid(admin_id))
      end
    end
  end

  # Resolves user UUID - already a UUID string, pass through
  defp resolve_user_uuid(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid), do: uuid, else: nil
  end

  defp resolve_user_uuid(_), do: nil

  @doc """
  Updates an entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.update_entity(entity, %{display_name: "Updated"})
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKit.Modules.Entities.update_entity(entity, %{name: ""})
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

  Note: This will also delete all associated entity_data records due to the
  ON DELETE CASCADE constraint defined in the database migration (V17).

  ## Examples

      iex> PhoenixKit.Modules.Entities.delete_entity(entity)
      {:ok, %PhoenixKit.Entities{}}

      iex> PhoenixKit.Modules.Entities.delete_entity(entity)
      {:error, %Ecto.Changeset{}}
  """
  def delete_entity(%__MODULE__{} = entity) do
    repo().delete(entity)
    |> notify_entity_event(:deleted)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking entity changes.

  ## Examples

      iex> PhoenixKit.Modules.Entities.change_entity(entity)
      %Ecto.Changeset{data: %PhoenixKit.Entities{}}
  """
  def change_entity(%__MODULE__{} = entity, attrs \\ %{}) do
    changeset(entity, attrs)
  end

  @doc """
  Gets summary statistics for the entities system.

  Returns counts and metrics useful for admin dashboards.

  ## Examples

      iex> PhoenixKit.Modules.Entities.get_system_stats()
      %{total_entities: 5, active_entities: 4, total_data_records: 150}
  """
  def get_system_stats do
    entities_query = from(e in __MODULE__)
    data_query = from(d in PhoenixKit.Modules.Entities.EntityData)

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

      iex> PhoenixKit.Modules.Entities.count_user_entities(1)
      5
  """
  def count_user_entities(user_uuid) when is_binary(user_uuid) do
    from(e in __MODULE__, where: e.created_by_uuid == ^user_uuid, select: count(e.uuid))
    |> repo().one()
  end

  def count_user_entities(user_id) when is_integer(user_id) do
    from(e in __MODULE__, where: e.created_by == ^user_id, select: count(e.uuid))
    |> repo().one()
  end

  @doc """
  Counts the total number of entities in the system.

  ## Examples

      iex> PhoenixKit.Modules.Entities.count_entities()
      15
  """
  def count_entities do
    from(e in __MODULE__, select: count(e.uuid))
    |> repo().one()
  end

  @doc """
  Counts the total number of entity data records across all entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.count_all_entity_data()
      243
  """
  def count_all_entity_data do
    from(d in PhoenixKit.Modules.Entities.EntityData, select: count(d.uuid))
    |> repo().one()
  end

  @doc """
  Validates that a user hasn't exceeded their entity creation limit.

  Checks the current number of entities created by the user against the system limit.
  Returns `{:ok, :valid}` if within limits, `{:error, reason}` if limit exceeded.

  ## Examples

      iex> PhoenixKit.Modules.Entities.validate_user_entity_limit(1)
      {:ok, :valid}

      iex> PhoenixKit.Modules.Entities.validate_user_entity_limit(1)
      {:error, "You have reached the maximum limit of 100 entities"}
  """
  def validate_user_entity_limit(user_uuid) when is_binary(user_uuid) do
    max_entities = get_max_per_user()
    current_count = count_user_entities(user_uuid)

    if current_count < max_entities do
      {:ok, :valid}
    else
      {:error, "You have reached the maximum limit of #{max_entities} entities"}
    end
  end

  # Legacy integer overload — delegates to integer count_user_entities
  def validate_user_entity_limit(user_id) when is_integer(user_id) do
    max_entities = get_max_per_user()
    current_count = count_user_entities(user_id)

    if current_count < max_entities do
      {:ok, :valid}
    else
      {:error, "You have reached the maximum limit of #{max_entities} entities"}
    end
  end

  @impl PhoenixKit.Module
  @doc """
  Checks if the entities system is enabled.

  Returns true if the "entities_enabled" setting is true.

  ## Examples

      iex> PhoenixKit.Modules.Entities.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting("entities_enabled", false)
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the entities system.

  Sets the "entities_enabled" setting to true.

  ## Examples

      iex> PhoenixKit.Modules.Entities.enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("entities_enabled", true, "entities")
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the entities system.

  Sets the "entities_enabled" setting to false.

  ## Examples

      iex> PhoenixKit.Modules.Entities.disable_system()
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

      iex> PhoenixKit.Modules.Entities.get_max_per_user()
      100
  """
  def get_max_per_user do
    Settings.get_integer_setting("entities_max_per_user", 100)
  end

  @impl PhoenixKit.Module
  @doc """
  Gets the current entities system configuration.

  Returns a map with the current settings.

  ## Examples

      iex> PhoenixKit.Modules.Entities.get_config()
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

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "entities"

  @impl PhoenixKit.Module
  def module_name, do: "Entities"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "entities",
      label: "Entities",
      icon: "hero-cube-transparent",
      description: "Dynamic content types and custom data structures"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_entities,
        label: "Entities",
        icon: "hero-cube",
        path: "/admin/entities",
        priority: 540,
        level: :admin,
        permission: "entities",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        dynamic_children: &__MODULE__.entities_children/1
      )
    ]
  end

  # ETS cache TTL for entity summaries (30 seconds)
  @entities_cache_ttl_ms 30_000
  @entities_cache_key :entities_children_cache

  @doc """
  Invalidates the cached entity summaries in the Dashboard Registry's ETS table.
  Called when entity lifecycle PubSub events are received.
  """
  @spec invalidate_entities_cache() :: :ok
  def invalidate_entities_cache do
    alias PhoenixKit.Dashboard.Registry, as: DashboardRegistry

    if DashboardRegistry.initialized?() do
      :ets.delete(DashboardRegistry.ets_table(), @entities_cache_key)
    end

    :ok
  end

  @doc "Dynamic children function for Entities sidebar tabs."
  def entities_children(_scope) do
    cached_entity_summaries()
    |> Enum.with_index()
    |> Enum.map(fn {entity, idx} ->
      %Tab{
        id:
          String.to_atom(
            "admin_entity_#{entity.name}_#{:erlang.phash2(entity.name) |> Integer.to_string(16) |> String.downcase()}"
          ),
        label: entity.display_name_plural || entity.display_name,
        icon: entity.icon || "hero-cube",
        path: "/admin/entities/#{entity.name}/data",
        priority: 541 + idx,
        level: :admin,
        permission: "entities",
        match: :prefix,
        parent: :admin_entities
      }
    end)
  rescue
    _ -> []
  end

  defp cached_entity_summaries do
    alias PhoenixKit.Dashboard.Registry, as: DashboardRegistry

    if DashboardRegistry.initialized?() do
      case :ets.lookup(DashboardRegistry.ets_table(), @entities_cache_key) do
        [{@entities_cache_key, entities, timestamp}]
        when is_integer(timestamp) ->
          if System.monotonic_time(:millisecond) - timestamp < @entities_cache_ttl_ms do
            entities
          else
            fetch_and_cache_entities()
          end

        _ ->
          fetch_and_cache_entities()
      end
    else
      list_entity_summaries()
    end
  end

  defp fetch_and_cache_entities do
    alias PhoenixKit.Dashboard.Registry, as: DashboardRegistry
    entities = list_entity_summaries()

    if DashboardRegistry.initialized?() do
      :ets.insert(
        DashboardRegistry.ets_table(),
        {@entities_cache_key, entities, System.monotonic_time(:millisecond)}
      )
    end

    entities
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_entities,
        label: "Entities",
        icon: "hero-cube",
        path: "/admin/settings/entities",
        priority: 935,
        level: :admin,
        parent: :admin_settings,
        permission: "entities",
        match: :prefix
      )
    ]
  end

  @impl PhoenixKit.Module
  def children, do: [PhoenixKit.Modules.Entities.Presence]

  # ============================================================================
  # Per-Entity Mirror Settings
  # ============================================================================

  @doc """
  Gets the mirror settings for an entity.

  Returns a map with mirror_definitions and mirror_data booleans.
  Defaults to false if not explicitly set.

  ## Examples

      iex> PhoenixKit.Modules.Entities.get_mirror_settings(entity)
      %{mirror_definitions: true, mirror_data: false}
  """
  def get_mirror_settings(%__MODULE__{settings: settings}) do
    settings = settings || %{}

    %{
      mirror_definitions: Map.get(settings, "mirror_definitions", false),
      mirror_data: Map.get(settings, "mirror_data", false)
    }
  end

  @doc """
  Checks if definition mirroring is enabled for this entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.mirror_definitions_enabled?(entity)
      true
  """
  def mirror_definitions_enabled?(%__MODULE__{settings: settings}) do
    settings = settings || %{}
    Map.get(settings, "mirror_definitions", false) == true
  end

  @doc """
  Checks if data mirroring is enabled for this entity.

  ## Examples

      iex> PhoenixKit.Modules.Entities.mirror_data_enabled?(entity)
      false
  """
  def mirror_data_enabled?(%__MODULE__{settings: settings}) do
    settings = settings || %{}
    Map.get(settings, "mirror_data", false) == true
  end

  @doc """
  Updates the mirror settings for an entity.

  ## Parameters
    - `entity` - The entity to update
    - `mirror_settings` - Map with keys "mirror_definitions" and/or "mirror_data"

  ## Examples

      iex> PhoenixKit.Modules.Entities.update_mirror_settings(entity, %{"mirror_definitions" => true})
      {:ok, %PhoenixKit.Entities{}}
  """
  def update_mirror_settings(%__MODULE__{} = entity, mirror_settings)
      when is_map(mirror_settings) do
    current_settings = entity.settings || %{}
    new_settings = Map.merge(current_settings, mirror_settings)
    update_entity(entity, %{settings: new_settings})
  end

  # ============================================================================
  @doc """
  Lists all entities with their mirror status and data counts.

  Returns a list of maps suitable for the settings UI.

  ## Examples

      iex> PhoenixKit.Modules.Entities.list_entities_with_mirror_status()
      [%{id: 1, name: "test", display_name: "Test", data_count: 8, mirror_definitions: true, mirror_data: false}, ...]
  """
  def list_entities_with_mirror_status do
    entities = list_entities()

    Enum.map(entities, fn entity ->
      mirror_settings = get_mirror_settings(entity)
      data_count = EntityData.count_by_entity(entity.uuid)
      file_exists = Storage.entity_exists?(entity.name)

      %{
        uuid: entity.uuid,
        name: entity.name,
        display_name: entity.display_name,
        data_count: data_count,
        mirror_definitions: mirror_settings.mirror_definitions,
        mirror_data: mirror_settings.mirror_data,
        file_exists: file_exists
      }
    end)
  end

  @doc """
  Enables definition mirroring for all entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.enable_all_definitions_mirror()
      {:ok, count}
  """
  def enable_all_definitions_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_definitions" => true})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  @doc """
  Disables definition mirroring for all entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.disable_all_definitions_mirror()
      {:ok, count}
  """
  def disable_all_definitions_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_definitions" => false})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  @doc """
  Enables data mirroring for all entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.enable_all_data_mirror()
      {:ok, count}
  """
  def enable_all_data_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_data" => true})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  @doc """
  Disables data mirroring for all entities.

  ## Examples

      iex> PhoenixKit.Modules.Entities.disable_all_data_mirror()
      {:ok, count}
  """
  def disable_all_data_mirror do
    entities = list_entities()

    results =
      Enum.map(entities, fn entity ->
        update_mirror_settings(entity, %{"mirror_data" => false})
      end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, success_count}
  end

  # ============================================================================
  # Translation convenience API
  # ============================================================================

  @doc """
  Gets all translations for an entity definition.

  Returns a map of language codes to translated fields.
  Only includes languages that have at least one translated field.

  ## Examples

      iex> get_entity_translations(entity)
      %{
        "es-ES" => %{"display_name" => "Productos", "display_name_plural" => "Productos"},
        "fr-FR" => %{"display_name" => "Produits"}
      }

      iex> get_entity_translations(entity_without_translations)
      %{}
  """
  def get_entity_translations(%__MODULE__{settings: settings}) do
    (settings || %{})
    |> Map.get("translations", %{})
  end

  @doc """
  Gets the translation for a specific language on an entity definition.

  Returns the translated fields merged with the primary language values
  as defaults. Returns primary language values if no translation exists.

  ## Examples

      iex> get_entity_translation(entity, "es-ES")
      %{"display_name" => "Productos", "display_name_plural" => "Productos", "description" => "..."}
  """
  def get_entity_translation(%__MODULE__{} = entity, lang_code) when is_binary(lang_code) do
    primary = %{
      "display_name" => entity.display_name,
      "display_name_plural" => entity.display_name_plural,
      "description" => entity.description
    }

    translations = get_entity_translations(entity)
    lang_overrides = Map.get(translations, lang_code, %{})

    Map.merge(primary, lang_overrides)
  end

  @doc """
  Sets the translation for a specific language on an entity definition.

  Merges the provided fields into the existing translation for that language.
  Empty string values are treated as "remove override" (field falls back to primary).

  ## Examples

      iex> set_entity_translation(entity, "es-ES", %{
      ...>   "display_name" => "Productos",
      ...>   "display_name_plural" => "Productos"
      ...> })
      {:ok, %PhoenixKit.Modules.Entities{}}
  """
  def set_entity_translation(%__MODULE__{} = entity, lang_code, attrs)
      when is_binary(lang_code) and is_map(attrs) do
    current_settings = entity.settings || %{}
    translations = Map.get(current_settings, "translations", %{})

    existing = Map.get(translations, lang_code, %{})
    merged = Map.merge(existing, attrs)

    # Remove empty values (fall back to primary)
    cleaned =
      merged
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    updated_translations =
      if map_size(cleaned) == 0 do
        Map.delete(translations, lang_code)
      else
        Map.put(translations, lang_code, cleaned)
      end

    new_settings =
      if map_size(updated_translations) == 0 do
        Map.delete(current_settings, "translations")
      else
        Map.put(current_settings, "translations", updated_translations)
      end

    update_entity(entity, %{settings: new_settings})
  end

  @doc """
  Removes all translations for a specific language from an entity definition.

  ## Examples

      iex> remove_entity_translation(entity, "es-ES")
      {:ok, %PhoenixKit.Modules.Entities{}}
  """
  def remove_entity_translation(%__MODULE__{} = entity, lang_code)
      when is_binary(lang_code) do
    current_settings = entity.settings || %{}
    translations = Map.get(current_settings, "translations", %{})
    updated = Map.delete(translations, lang_code)

    new_settings =
      if map_size(updated) == 0 do
        Map.delete(current_settings, "translations")
      else
        Map.put(current_settings, "translations", updated)
      end

    update_entity(entity, %{settings: new_settings})
  end

  @doc """
  Checks if multilang is globally enabled (Languages module has 2+ languages).

  Convenience wrapper around `Multilang.enabled?/0`.

  ## Examples

      iex> PhoenixKit.Modules.Entities.multilang_enabled?()
      true
  """
  def multilang_enabled?, do: Multilang.enabled?()

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
