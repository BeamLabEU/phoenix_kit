defmodule PhoenixKit.Users.CustomFields do
  @moduledoc """
  Context for managing custom user field definitions.

  This module provides functionality to define, manage, and validate custom fields
  that can be added to user profiles. Field definitions are stored as JSON in the
  settings table, and actual field values are stored in the user's `custom_fields`
  JSONB column.

  ## Field Definition Structure

  Each field definition is a map with the following keys:

  - `key` - Unique identifier for the field (string)
  - `label` - Display label for the field (string)
  - `column_label` - Optional short name for the field's column header in the Users
    table (string). Absent means the label is used; blank is stored as absent
  - `filterable` - For a `boolean` field: whether the Users table offers a
    Yes/No filter for it (boolean, default: false)
  - `type` - Field type: text, textarea, number, boolean, date, email, url, uuid, select, radio, checkbox
  - `required` - Whether the field is required (boolean)
  - `position` - Display order (integer)
  - `enabled` - Whether the field is active (boolean)
  - `user_accessible` - Whether users can edit this field from their settings page (boolean, default: true)
  - `validation` - Optional validation rules (map)
  - `default` - Default value (string)
  - `options` - For select/radio/checkbox types (list of strings)

  ## Examples

      # Get all field definitions
      CustomFields.list_field_definitions()

      # Add a new field
      CustomFields.add_field_definition(%{
        "key" => "phone",
        "label" => "Phone Number",
        "type" => "text",
        "required" => false,
        "position" => 1,
        "enabled" => true
      })

      # Get system configuration
      CustomFields.get_config()
  """

  require Logger

  alias PhoenixKit.Settings

  @setting_key "custom_user_fields_definitions"

  @supported_types ~w(text textarea number boolean date email url uuid select radio checkbox)

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  # Keys PhoenixKit writes into `custom_fields` as internal per-user state — a
  # view toggle, the etcher's palette, a notification routing blob. None of
  # them is an admin-managed profile field, and several hold a map or a list,
  # which no field `type` can represent: a definition for one produces an
  # admin form that renders the raw value into a text input, where a map
  # raises `Phoenix.HTML.Safe` and a list is silently flattened into one run
  # and written back on the next save (issue #780).
  #
  # The features that own the crash-causing keys pass `ensure_definitions:
  # false`, but five of these have no such opt-out and register themselves to
  # this day: `avatar_file_uuid` (`auth.ex`, `user_settings.ex`),
  # `pending_invitation_uuid` (`registration.ex`, `confirmation.ex`) and
  # `source` (`user.ex`) go through `update_user_fields/2`, and
  # `oauth_avatar_url` through `set_user_custom_field/3` — all of which reach
  # `update_user_custom_fields/3` with default options. So this list is the
  # single place that decides, whatever the caller did.
  #
  # Migration V182's copy is deliberately NARROWER: it deletes only the keys
  # that were auto-registered by a version with no opt-out at all. Removing a
  # definition an operator can see today — `source` reads as a useful column,
  # `avatar_file_uuid` is shown on the user page — is not something a bug fix
  # should do behind their back, and `down/1` could not restore it. Existing
  # definitions for the five stay; only new registrations stop.
  @internal_keys ~w(
    activity_view_mode
    avatar_crop
    avatar_file_uuid
    etcher_colors
    etcher_line_params
    media_expanded_folders
    media_sidebar_collapsed
    media_view_mode
    media_viewer_info_collapsed
    notification_preferences
    oauth_avatar_url
    pending_invitation_uuid
    preferred_locale
    referral_satisfied_at
    referral_satisfied_via
    source
    timezone_alert_zone
    users_view_mode
    welcome_email_sent_at
  )

  # `notification_channel:<key>` carries one channel's config map. The colon
  # already makes `validate_field_key/1` reject it, so no definition was ever
  # created — matching it here only saves the auto-registration warning.
  @internal_key_prefixes ["notification_channel:"]

  # Field Definition Management

  @doc """
  Returns the list of all custom field definitions.

  ## Examples

      iex> list_field_definitions()
      [
        %{
          "key" => "phone",
          "label" => "Phone Number",
          "type" => "text",
          ...
        }
      ]
  """
  def list_field_definitions do
    case Settings.get_json_setting_cached(@setting_key, nil) do
      nil ->
        []

      # Handle new wrapped format: %{"fields" => [definitions]}
      %{"fields" => definitions} when is_list(definitions) ->
        definitions

      # Handle old format: direct list (for backward compatibility)
      definitions when is_list(definitions) ->
        definitions

      # Fallback: try reading from string field for backward compatibility
      _ ->
        case Settings.get_setting_cached(@setting_key) do
          nil -> []
          json_string when is_binary(json_string) -> parse_definitions(json_string)
          definitions when is_list(definitions) -> definitions
          _ -> []
        end
    end
  end

  @doc """
  Returns only enabled field definitions, sorted by position.

  ## Examples

      iex> list_enabled_field_definitions()
      [%{"key" => "phone", "enabled" => true, ...}]
  """
  def list_enabled_field_definitions do
    list_field_definitions()
    |> Enum.filter(&(&1["enabled"] == true))
    |> Enum.sort_by(&(&1["position"] || 0))
  end

  @doc """
  The enabled `boolean` fields the Users table offers a filter for (`"filterable"`
  on), sorted by position.
  """
  @spec list_filterable_field_definitions() :: [map()]
  def list_filterable_field_definitions do
    Enum.filter(list_enabled_field_definitions(), &filterable?/1)
  end

  @doc "Whether the Users table offers a Yes/No filter for this field."
  @spec filterable?(map()) :: boolean()
  def filterable?(%{"type" => "boolean", "filterable" => true}), do: true
  def filterable?(_definition), do: false

  @doc """
  The field's name in the Users table: its column name when one is set,
  else its label. Everywhere else shows the label.
  """
  @spec column_label(map()) :: String.t()
  def column_label(definition) do
    case definition do
      %{"column_label" => name} when is_binary(name) and name != "" -> name
      _ -> definition["label"] || definition["key"]
    end
  end

  @doc """
  Returns only enabled field definitions that are user-accessible, sorted by position.

  These are fields that users can view and edit from their own settings page.
  Admins can always see and edit all fields regardless of this setting.

  Legacy fields without the `user_accessible` key default to `true` (accessible).

  ## Examples

      iex> list_user_accessible_field_definitions()
      [%{"key" => "phone", "enabled" => true, "user_accessible" => true, ...}]
  """
  def list_user_accessible_field_definitions do
    list_field_definitions()
    |> Enum.filter(fn field ->
      # Field must be enabled
      enabled = field["enabled"] == true

      # user_accessible defaults to true if not set (for legacy fields)
      user_accessible = Map.get(field, "user_accessible", true)

      enabled && user_accessible
    end)
    |> Enum.sort_by(&(&1["position"] || 0))
  end

  @doc """
  Gets a single field definition by key.

  Returns `nil` if not found.

  ## Examples

      iex> get_field_definition("phone")
      %{"key" => "phone", "label" => "Phone Number", ...}

      iex> get_field_definition("nonexistent")
      nil
  """
  def get_field_definition(key) when is_binary(key) do
    list_field_definitions()
    |> Enum.find(&(&1["key"] == key))
  end

  @doc """
  Saves the complete list of field definitions.

  ## Examples

      iex> save_field_definitions([%{"key" => "phone", ...}])
      {:ok, _setting}
  """
  def save_field_definitions(definitions) when is_list(definitions) do
    # Wrap the list in a map to match the database schema expectation
    Settings.update_json_setting(@setting_key, %{"fields" => definitions})
  end

  @doc """
  Adds a new field definition.

  Validates the field structure and ensures the key is unique.

  ## Examples

      iex> add_field_definition(%{"key" => "phone", "label" => "Phone", "type" => "text"})
      {:ok, _setting}

      iex> add_field_definition(%{"key" => "phone"})
      {:error, "Field with key 'phone' already exists"}
  """
  def add_field_definition(field_def) when is_map(field_def) do
    with :ok <- validate_field_definition(field_def),
         :ok <- ensure_unique_key(field_def["key"]) do
      definitions = list_field_definitions()
      new_definitions = definitions ++ [normalize_field_definition(field_def)]
      save_field_definitions(new_definitions)
    end
  end

  @doc """
  Updates an existing field definition.

  ## Examples

      iex> update_field_definition("phone", %{"label" => "Mobile Number"})
      {:ok, _setting}

      iex> update_field_definition("nonexistent", %{})
      {:error, "Field with key 'nonexistent' not found"}
  """
  def update_field_definition(key, updates) when is_binary(key) and is_map(updates) do
    definitions = list_field_definitions()

    case Enum.find_index(definitions, &(&1["key"] == key)) do
      nil ->
        {:error, "Field with key '#{key}' not found"}

      index ->
        existing = Enum.at(definitions, index)
        updated = Map.merge(existing, updates) |> normalize_field_definition()
        new_definitions = List.replace_at(definitions, index, updated)
        save_field_definitions(new_definitions)
    end
  end

  @doc """
  Deletes a field definition by key.

  ## Examples

      iex> delete_field_definition("phone")
      {:ok, _setting}
  """
  def delete_field_definition(key) when is_binary(key) do
    definitions = list_field_definitions()
    new_definitions = Enum.reject(definitions, &(&1["key"] == key))
    save_field_definitions(new_definitions)
  end

  @doc """
  Reorders field definitions by updating their position values.

  Accepts a list of keys in the desired order.

  ## Examples

      iex> reorder_field_definitions(["email", "phone", "department"])
      {:ok, _setting}
  """
  def reorder_field_definitions(ordered_keys) when is_list(ordered_keys) do
    definitions = list_field_definitions()

    # Create a map of key -> position
    position_map =
      ordered_keys
      |> Enum.with_index(1)
      |> Enum.into(%{})

    # Update positions
    updated_definitions =
      Enum.map(definitions, fn def ->
        Map.put(def, "position", position_map[def["key"]] || 999)
      end)
      |> Enum.sort_by(& &1["position"])

    save_field_definitions(updated_definitions)
  end

  # System Information

  @doc """
  Gets the current custom fields system configuration.

  Returns a map with field counts.

  ## Examples

      iex> get_config()
      %{
        field_count: 5,
        enabled_field_count: 3
      }
  """
  def get_config do
    definitions = list_field_definitions()
    enabled_definitions = Enum.filter(definitions, &(&1["enabled"] == true))

    %{
      field_count: length(definitions),
      enabled_field_count: length(enabled_definitions)
    }
  end

  # Option Text Lookup (for select fields that save index)

  @doc """
  Gets the display text for a select field value (which is stored as index).

  For select/radio/checkbox fields, the saved value is the index (0, 1, 2...)
  and this function returns the actual option text.

  ## Examples

      iex> get_option_text("favorite_color", "1")
      "Blue"  # if options are ["Red", "Blue", "Green"]

      iex> get_option_text("nonexistent", "1")
      "1"  # fallback to raw value
  """
  def get_option_text(field_key, index_value) when is_binary(field_key) do
    case get_field_definition(field_key) do
      %{"type" => type, "options" => options}
      when type in ~w(select radio checkbox) and is_list(options) ->
        case parse_option_index(index_value) do
          nil -> index_value
          index -> Enum.at(options, index) || index_value
        end

      _ ->
        # Not a select field or field not found - return raw value
        index_value
    end
  end

  def get_option_text(_field_key, value), do: value

  defp parse_option_index(value) when is_integer(value), do: value

  defp parse_option_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_option_index(_), do: nil

  # Validation

  @doc """
  Validates a field definition structure.

  Checks for required keys, valid types, and proper structure.

  ## Examples

      iex> validate_field_definition(%{"key" => "phone", "type" => "text"})
      :ok

      iex> validate_field_definition(%{"key" => "phone", "type" => "invalid"})
      {:error, "Invalid field type: invalid"}
  """
  def validate_field_definition(field_def) when is_map(field_def) do
    with :ok <- validate_required_keys(field_def),
         :ok <- validate_field_type(field_def["type"]),
         :ok <- validate_field_key(field_def["key"]) do
      validate_options_for_type(field_def)
    end
  end

  @doc """
  Validates a user's custom field value against a field definition.

  ## Examples

      iex> validate_custom_field_value(%{"type" => "email", "required" => true}, "test@example.com")
      :ok

      iex> validate_custom_field_value(%{"type" => "email", "required" => true}, nil)
      {:error, "Field is required"}
  """
  def validate_custom_field_value(field_def, value) do
    with :ok <- validate_required(field_def, value) do
      validate_type(field_def, value)
    end
  end

  @doc """
  Validates all custom fields for a user against field definitions.

  Returns `:ok` if valid, or `{:error, errors}` with a map of field keys to error messages.

  ## Examples

      iex> validate_user_custom_fields(%User{custom_fields: %{"phone" => "555-1234"}})
      :ok

      iex> validate_user_custom_fields(%User{custom_fields: %{"email" => "invalid"}})
      {:error, %{"email" => "Invalid email format"}}
  """
  def validate_user_custom_fields(user) do
    definitions = list_enabled_field_definitions()
    custom_fields = user.custom_fields || %{}

    errors =
      Enum.reduce(definitions, %{}, fn field_def, acc ->
        key = field_def["key"]
        value = Map.get(custom_fields, key)

        # A structured value is not validated at all. No `type` describes one,
        # so there is nothing to check — and several `validate_type/2` clauses
        # (`number`, `uuid`, `date`) call `to_string/1`, which is the exact
        # `Protocol.UndefinedError` this whole area exists to stop, just moved
        # from the render into the save path (issue #780).
        if structured_value?(value) do
          acc
        else
          case validate_custom_field_value(field_def, value) do
            :ok -> acc
            {:error, message} -> Map.put(acc, key, message)
          end
        end
      end)

    if map_size(errors) == 0 do
      :ok
    else
      {:error, errors}
    end
  end

  # A value typed into a profile form. Generous for a textarea, and still a
  # bound: the definitions cap the number of keys, this caps each one.
  @max_user_value_length 10_000

  @doc "The longest value `cast_user_input/2` accepts for one field, in characters."
  @spec max_user_value_length() :: pos_integer()
  def max_user_value_length, do: @max_user_value_length

  @doc """
  Reduces a `custom_fields` map submitted by the account holder to the entries
  they may write.

  `custom_fields` is one JSONB column shared by admin-defined profile fields
  and by state the system keeps per user (the avatar file, the invite-only
  stamp, notification routing). A profile form posts whatever the client
  sends, so this is the rule for anything that arrives from one:

    * only a key with an enabled, user-accessible definition is accepted, and
      never an internal key (`internal_key?/1`), whatever definition it has;
    * a key whose stored value is structured is left alone — no field type
      edits one;
    * a value equal to the stored one is skipped, so stored data that predates
      a definition is never re-validated by an unrelated save;
    * a new value must be a scalar of at most `max_user_value_length/0`
      characters that satisfies the definition (`required`, `type`, and the
      offered options of a `select`).

  Returns `{accepted, errors}`: `accepted` holds only the entries to merge over
  the stored map, `errors` is a list of `{key, {message, opts}}` in the shape
  `Ecto.Changeset.add_error/4` takes. Everything else submitted is dropped.
  """
  @spec cast_user_input(map() | nil, map()) ::
          {%{optional(String.t()) => term()}, [{String.t(), {String.t(), keyword()}}]}
  def cast_user_input(stored, submitted) when is_map(submitted) do
    stored = stored || %{}

    definitions =
      for definition <- list_user_accessible_field_definitions(),
          key = definition["key"],
          is_binary(key) and not internal_key?(key),
          into: %{},
          do: {key, definition}

    {accepted, errors} =
      Enum.reduce(submitted, {%{}, []}, fn {key, value}, {accepted, errors} = acc ->
        key = if is_atom(key), do: Atom.to_string(key), else: key
        definition = is_binary(key) && definitions[key]

        cond do
          !definition -> acc
          structured_value?(stored[key]) -> acc
          same_user_value?(stored[key], value) -> acc
          true -> accept_user_value(definition, key, value, accepted, errors)
        end
      end)

    {accepted, Enum.reverse(errors)}
  end

  defp accept_user_value(definition, key, value, accepted, errors) do
    case validate_user_value(definition, value) do
      :ok -> {Map.put(accepted, key, value), errors}
      {:error, error} -> {accepted, [{key, error} | errors]}
    end
  end

  defp same_user_value?(stored, value) when stored in [nil, ""] and value in [nil, ""], do: true
  defp same_user_value?(nil, _value), do: false
  defp same_user_value?(stored, value) when is_binary(value), do: printable(stored) == value
  defp same_user_value?(stored, value), do: stored == value

  defp validate_user_value(definition, value) do
    cond do
      structured_value?(value) ->
        {:error, {"is invalid", []}}

      is_binary(value) and String.length(value) > @max_user_value_length ->
        {:error,
         {"should be at most %{count} character(s)",
          [count: @max_user_value_length, validation: :length, kind: :max, type: :string]}}

      definition["required"] && value in [nil, ""] ->
        {:error, {"can't be blank", [validation: :required]}}

      true ->
        validate_user_value_type(definition, value)
    end
  end

  # `validate_type/2` matches on strings and booleans; any other scalar is
  # checked as the text a form would have sent for it.
  defp validate_user_value_type(definition, value) do
    text =
      cond do
        is_binary(value) or is_nil(value) -> value
        definition["type"] == "boolean" -> value
        true -> to_string(value)
      end

    with :ok <- validate_type(definition, text),
         :ok <- validate_offered_option(definition, text) do
      :ok
    else
      {:error, _message} -> {:error, {"is invalid", []}}
    end
  end

  # The profile form posts a select's option value and the admin form its
  # index, so a stored value is either; both are accepted here.
  defp validate_offered_option(%{"type" => "select", "options" => options}, value)
       when is_list(options) and is_binary(value) and value != "" do
    offered =
      Enum.map(options, fn
        %{"value" => option} -> printable(option)
        option -> printable(option)
      end)

    indexes =
      options |> Enum.with_index() |> Enum.map(fn {_option, index} -> to_string(index) end)

    if value in offered or value in indexes, do: :ok, else: {:error, "Not an offered option"}
  end

  defp validate_offered_option(_definition, _value), do: :ok

  # Private Helpers

  defp parse_position(nil), do: 0
  defp parse_position(pos) when is_integer(pos), do: pos

  defp parse_position(pos) when is_binary(pos) do
    case Integer.parse(pos) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_position(_), do: 0

  defp parse_definitions(json_string) do
    case JSON.decode(json_string) do
      {:ok, definitions} when is_list(definitions) -> definitions
      _ -> []
    end
  end

  defp normalize_field_definition(field_def) do
    %{
      "key" => field_def["key"],
      "label" => field_def["label"] || field_def["key"],
      "type" => field_def["type"] || "text",
      "required" => normalize_boolean(field_def["required"], false),
      "position" => field_def["position"] || 0,
      "enabled" => normalize_boolean(Map.get(field_def, "enabled"), true),
      "user_accessible" => normalize_boolean(Map.get(field_def, "user_accessible"), true),
      "filterable" => normalize_boolean(Map.get(field_def, "filterable"), false),
      "validation" => field_def["validation"] || %{},
      "default" => field_def["default"] || "",
      "options" => field_def["options"] || []
    }
    |> put_column_label(field_def["column_label"])
  end

  # Blank or spaces only is stored as absent, so the label shows.
  defp put_column_label(definition, name) when is_binary(name) do
    case String.trim(name) do
      "" -> definition
      trimmed -> Map.put(definition, "column_label", trimmed)
    end
  end

  defp put_column_label(definition, _name), do: definition

  # Convert string boolean values to actual booleans
  defp normalize_boolean(value, default) do
    case value do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      nil -> default
      _ -> default
    end
  end

  defp ensure_unique_key(key) do
    if get_field_definition(key) do
      {:error, "Field with key '#{key}' already exists"}
    else
      :ok
    end
  end

  defp validate_required_keys(field_def) do
    required = ["key", "type"]

    missing =
      Enum.filter(required, fn key ->
        is_nil(field_def[key]) or field_def[key] == ""
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_field_type(type) when type in @supported_types, do: :ok

  defp validate_field_type(type),
    do: {:error, "Invalid field type: #{type}. Supported: #{Enum.join(@supported_types, ", ")}"}

  defp validate_field_key(key) when is_binary(key) do
    if String.match?(key, ~r/^[a-z][a-z0-9_]*$/) do
      :ok
    else
      {:error,
       "Field key must start with lowercase letter and contain only lowercase letters, numbers, and underscores"}
    end
  end

  defp validate_field_key(_), do: {:error, "Field key must be a string"}

  defp validate_options_for_type(%{"type" => type, "options" => options})
       when type in ~w(select radio checkbox) do
    if is_list(options) and options != [] do
      :ok
    else
      {:error, "#{String.capitalize(type)} fields require at least one option"}
    end
  end

  defp validate_options_for_type(%{"type" => type})
       when type in ~w(select radio checkbox) do
    {:error, "#{String.capitalize(type)} fields require at least one option"}
  end

  defp validate_options_for_type(_), do: :ok

  defp validate_required(field_def, value) do
    if field_def["required"] && (is_nil(value) || value == "") do
      {:error, "Field is required"}
    else
      :ok
    end
  end

  @doc """
  Ensures field definitions exist for all keys in the given custom fields map.

  For any key that doesn't have a corresponding field definition, auto-creates one
  with a label derived from the key, type inferred from the value, and
  `user_accessible: false` (admin-only by default).

  Two kinds of key are skipped silently, because a definition for either one
  produces an admin form that cannot render it (issue #780):

    * **Structured values** — a map or a list. Every supported `type` describes
      a scalar, so the closest `infer_field_type/1` can offer is `"text"`, and
      the edit form then hands the raw value to an `<input>`: a map raises
      `Phoenix.HTML.Safe`, a list is flattened into one concatenated run that
      the next save writes back over the stored list.
    * **PhoenixKit's own internal keys** (`internal_key?/1`) — per-user state,
      not profile data.

  Returns `:ok`. Logs warnings for any definitions that fail to create.
  """
  def ensure_definitions_exist(custom_fields) when is_map(custom_fields) do
    definitions = list_field_definitions()
    existing_keys = MapSet.new(definitions, & &1["key"])

    new_keys =
      custom_fields
      |> Enum.reject(fn {key, value} ->
        MapSet.member?(existing_keys, key) or internal_key?(key) or structured_value?(value)
      end)
      |> Enum.map(fn {key, _value} -> key end)

    if new_keys != [] do
      next_position =
        definitions
        |> Enum.map(&parse_position(&1["position"]))
        |> Enum.max(fn -> 0 end)
        |> Kernel.+(1)

      new_keys
      |> Enum.with_index(next_position)
      |> Enum.each(fn {key, pos} ->
        label =
          key
          |> String.replace("_", " ")
          |> String.split()
          |> Enum.map_join(" ", &String.capitalize/1)

        case add_field_definition(%{
               "key" => key,
               "label" => label,
               "type" => infer_field_type(Map.get(custom_fields, key)),
               "enabled" => true,
               "user_accessible" => false,
               "position" => pos
             }) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to auto-register field definition '#{key}': #{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  end

  @doc """
  Infers the custom field type from a value.

  Returns one of: `"boolean"`, `"number"`, `"uuid"`, `"url"`, `"email"`, `"text"`.
  """
  def infer_field_type(value) when is_boolean(value), do: "boolean"
  def infer_field_type(value) when is_number(value), do: "number"

  def infer_field_type(value) when is_binary(value) do
    cond do
      Regex.match?(@uuid_regex, value) -> "uuid"
      String.match?(value, ~r/^https?:\/\//) -> "url"
      String.match?(value, ~r/^[^\s]+@[^\s]+\.[^\s]+$/) -> "email"
      true -> "text"
    end
  end

  def infer_field_type(_), do: "text"

  @doc """
  Whether `key` is one of PhoenixKit's internal per-user state keys.

  These live in the same `custom_fields` JSONB column as admin-defined profile
  fields, but they are written by features (the media browser's view mode, the
  etcher's palette, notification routing) rather than by an admin, and several
  of them hold a map or a list. They must never gain a field definition — see
  `ensure_definitions_exist/1`.

  ## Examples

      iex> PhoenixKit.Users.CustomFields.internal_key?("etcher_line_params")
      true

      iex> PhoenixKit.Users.CustomFields.internal_key?("notification_channel:telegram")
      true

      iex> PhoenixKit.Users.CustomFields.internal_key?("phone")
      false
  """
  @spec internal_key?(term()) :: boolean()
  def internal_key?(key) when is_binary(key) do
    key in @internal_keys or Enum.any?(@internal_key_prefixes, &String.starts_with?(key, &1))
  end

  def internal_key?(_key), do: false

  @doc """
  Whether a stored value is structured (a map or a list) rather than a scalar.

  `custom_fields` is free-form JSONB, so a value of either shape can sit under
  a key that has a definition. No field `type` can represent one, so callers
  render them read-only instead of into an editable input.

  ## Examples

      iex> PhoenixKit.Users.CustomFields.structured_value?(%{"width" => 2})
      true

      iex> PhoenixKit.Users.CustomFields.structured_value?("2")
      false
  """
  @spec structured_value?(term()) :: boolean()
  def structured_value?(value), do: is_map(value) or is_list(value)

  @doc """
  Renders a stored `custom_fields` value as a string that is safe to display.

  `to_string/1` raises `Protocol.UndefinedError` on a map, which took the whole
  user page down with a 500 for any user who had ever used a feature that
  stores one, and silently concatenates a list into one unreadable run. Maps
  render as JSON and lists as a comma-separated join instead.

  ## Examples

      iex> PhoenixKit.Users.CustomFields.printable(%{"dash" => "solid"})
      ~s({"dash":"solid"})

      iex> PhoenixKit.Users.CustomFields.printable(["#fca5a5", "#fdba74"])
      "#fca5a5, #fdba74"

      iex> PhoenixKit.Users.CustomFields.printable(42)
      "42"
  """
  @spec printable(term()) :: String.t()
  def printable(value) when is_map(value), do: JSON.encode!(value)
  def printable(value) when is_list(value), do: Enum.map_join(value, ", ", &printable/1)
  def printable(value) when is_binary(value), do: value
  def printable(value), do: to_string(value)

  defp validate_type(_field_def, nil), do: :ok
  defp validate_type(_field_def, ""), do: :ok

  defp validate_type(%{"type" => "email"} = _field_def, value) do
    if String.match?(value, ~r/^[^\s]+@[^\s]+\.[^\s]+$/) do
      :ok
    else
      {:error, "Invalid email format"}
    end
  end

  defp validate_type(%{"type" => "url"} = _field_def, value) do
    if String.match?(value, ~r/^https?:\/\/.+/) do
      :ok
    else
      {:error, "Invalid URL format"}
    end
  end

  defp validate_type(%{"type" => "number"} = _field_def, value) do
    case Float.parse(to_string(value)) do
      {_num, ""} -> :ok
      _ -> {:error, "Must be a valid number"}
    end
  end

  defp validate_type(%{"type" => "boolean"} = _field_def, value) when is_boolean(value), do: :ok

  defp validate_type(%{"type" => "boolean"} = _field_def, value)
       when value in ["true", "false"],
       do: :ok

  defp validate_type(%{"type" => "boolean"}, _value), do: {:error, "Must be true or false"}

  defp validate_type(%{"type" => "uuid"} = _field_def, value) do
    if Regex.match?(@uuid_regex, to_string(value)) do
      :ok
    else
      {:error, "Invalid UUID format"}
    end
  end

  defp validate_type(%{"type" => "date"} = _field_def, value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, _date} -> :ok
      _ -> {:error, "Invalid date format (use YYYY-MM-DD)"}
    end
  end

  defp validate_type(_field_def, _value), do: :ok
end
