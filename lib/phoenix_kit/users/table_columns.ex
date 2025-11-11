defmodule PhoenixKit.Users.TableColumns do
  @moduledoc """
  Table column configuration for user management dashboard.

  Provides dynamic column selection including standard user fields and custom fields
  from the V17 custom fields system. Manages column metadata, ordering, and persistence
  through the settings system.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.CustomFields

  @doc """
  Gets all available columns for the user table.

  Returns a map combining standard columns with active custom fields.
  Each column includes metadata like label, field path, and rendering information.

  ## Examples

      iex> PhoenixKit.Users.TableColumns.get_available_columns()
      %{
        "email" => %{label: "Email", field: "email", required: true},
        "username" => %{label: "Username", field: "username", required: false},
        "custom_123" => %{label: "Department", field: "custom_data.department", field_id: 123, field_type: "select", required: false}
      }
  """
  def get_available_columns do
    standard_columns = get_standard_columns()
    custom_columns = get_custom_field_columns()

    # Separate standard and custom columns with different structure
    %{
      standard: standard_columns,
      custom: custom_columns
    }
  end

  @doc """
  Gets the default column configuration.

  Returns the list of columns that should be visible by default
  if no user preference is saved in settings.
  """
  def get_default_columns do
    # Return all standard (non-custom) fields by default
    available = get_available_columns()
    standard_fields = Map.keys(available.standard)

    # Ensure actions is included at the end
    fields_with_actions = Enum.uniq(standard_fields ++ ["actions"])

    # Ensure actions is at the end
    other_fields = Enum.reject(fields_with_actions, &(&1 == "actions"))
    other_fields ++ ["actions"]
  end

  @doc """
  Gets the current user table columns from settings.

  Returns the user's saved column preference, or the default configuration
  if no preference is saved.

  ## Examples

      iex> PhoenixKit.Users.TableColumns.get_user_table_columns()
      ["email", "username", "role", "status", "registered"]
  """
  def get_user_table_columns do
    default_columns = get_default_columns()

    columns =
      case Settings.get_setting("user_table_columns") do
        nil ->
          default_columns

        "" ->
          default_columns

        json_value ->
          case Jason.decode(json_value) do
            {:ok, columns} when is_list(columns) -> columns
            _ -> default_columns
          end
      end

    columns
  end

  @doc """
  Updates the user table columns in settings.

  Saves the user's column preference to the settings table for persistence
  across page reloads and sessions.

  ## Examples

      iex> PhoenixKit.Users.TableColumns.update_user_table_columns(["email", "role", "status"])
      {:ok, %Setting{}}
  """
  def update_user_table_columns(columns) when is_list(columns) do
    # Ensure at least actions column is included
    minimal_columns = ["actions"]
    final_columns = Enum.uniq(minimal_columns ++ columns)

    # Always ensure actions is at the end
    ordered_columns = ensure_actions_at_end(final_columns)

    Settings.update_setting("user_table_columns", Jason.encode!(ordered_columns))
  end

  @doc """
  Reorders columns based on user drag-and-drop interaction.

  Takes the new order from the frontend and ensures it's valid and complete.
  Actions column is always appended at the end.

  ## Examples

      iex> PhoenixKit.Users.TableColumns.reorder_columns(["username", "email"], ["email", "username", "actions"])
      ["username", "email", "actions"]
  """
  def reorder_columns(new_order, current_selected)
      when is_list(new_order) and is_list(current_selected) do
    # Separate actions column from the new order
    {_actions_in_order, other_cols} = Enum.split_with(new_order, &(&1 == "actions"))

    # Filter to only valid columns
    available_columns = get_all_available_column_ids()
    valid_new_order = Enum.filter(other_cols, &(&1 in available_columns))

    # Ensure all currently selected columns are included
    missing_selected = current_selected -- valid_new_order
    complete_order = valid_new_order ++ missing_selected

    # Remove duplicates while preserving order
    unique_order = remove_duplicates_preserving_order(complete_order)

    # Always append actions at the end
    final_order = unique_order ++ ["actions"]

    update_user_table_columns(final_order)
  end

  @doc """
  Gets all available column IDs from both standard and custom fields.
  """
  def get_all_available_column_ids do
    available = get_available_columns()
    Map.keys(available.standard) ++ Map.keys(available.custom)
  end

  @doc """
  Validates a list of column IDs against available columns.

  Returns only the valid column IDs from the input list.

  ## Examples

      iex> PhoenixKit.Users.TableColumns.validate_columns(["email", "invalid_id", "role"])
      ["email", "role"]
  """
  def validate_columns(column_ids) when is_list(column_ids) do
    available = get_available_columns()
    all_available = Map.merge(available.standard, available.custom)

    Enum.filter(column_ids, fn column_id ->
      Map.has_key?(all_available, column_id)
    end)
  end

  @doc """
  Checks if a column is required (cannot be hidden).

  ## Examples

      iex> PhoenixKit.Users.TableColumns.column_required?("email")
      true
      iex> PhoenixKit.Users.TableColumns.column_required?("username")
      false
  """
  def column_required?(column_id) do
    case get_column_metadata(column_id) do
      %{required: required} -> required
      _ -> false
    end
  end

  @doc """
  Gets metadata for a specific column.

  ## Examples

      iex> PhoenixKit.Users.TableColumns.get_column_metadata("email")
      %{label: "Email", field: "email", required: true}
  """
  def get_column_metadata(column_id) do
    available = get_available_columns()

    # Check standard columns first
    case Map.get(available.standard, column_id) do
      nil -> Map.get(available.custom, column_id)
      metadata -> metadata
    end
  end

  # Private functions

  defp get_standard_columns do
    %{
      "email" => %{
        label: "Email",
        field: "email",
        required: false,
        type: :email
      },
      "username" => %{
        label: "Username",
        field: "username",
        required: false,
        type: :string
      },
      "full_name" => %{
        label: "Full Name",
        field: "first_name",
        required: false,
        type: :composite,
        formatter: &format_full_name/1
      },
      "role" => %{
        label: "Role",
        field: "roles",
        required: false,
        type: :roles
      },
      "status" => %{
        label: "Status",
        field: "is_active",
        required: false,
        type: :status
      },
      "registered" => %{
        label: "Registered",
        field: "inserted_at",
        required: false,
        type: :datetime
      },
      "location" => %{
        label: "Location",
        field: "registration_country",
        required: false,
        type: :location
      },
      "last_confirmed" => %{
        label: "Last Confirmed",
        field: "confirmed_at",
        required: false,
        type: :datetime
      }
    }
  end

  defp get_custom_field_columns do
    case Code.ensure_loaded(PhoenixKit.Users.CustomFields) do
      {:module, _} ->
        # Get enabled custom field definitions
        custom_fields =
          try do
            CustomFields.list_enabled_field_definitions()
          rescue
            UndefinedFunctionError -> []
          end

        Enum.into(custom_fields, %{}, fn field ->
          field_key = "custom_#{field["key"]}"

          {
            field_key,
            %{
              label: field["label"],
              field: "custom_data.#{field["key"]}",
              field_key: field["key"],
              field_type: field["type"],
              required: false,
              type: :custom_field
            }
          }
        end)

      {:error, _} ->
        # CustomFields module not available, return empty map
        %{}
    end
  end

  defp format_full_name(user) do
    User.full_name(user)
  end

  # Ensures the "actions" column is always at the end of the list
  defp ensure_actions_at_end(columns) when is_list(columns) do
    # Separate actions and non-actions columns
    {actions_columns, non_actions_columns} =
      Enum.split_with(columns, fn col -> col == "actions" end)

    case actions_columns do
      [] ->
        # actions not found, add it at the end
        non_actions_columns ++ ["actions"]

      [_actions] ->
        # actions found, ensure it's at the end
        non_actions_columns ++ actions_columns

      [_ | _] ->
        # multiple actions found (shouldn't happen), ensure one is at the end
        non_actions_columns ++ ["actions"]
    end
  end

  # Removes duplicates from a list while preserving the original order
  defp remove_duplicates_preserving_order(list) when is_list(list) do
    Enum.reduce(list, [], fn item, acc ->
      if item in acc do
        acc
      else
        acc ++ [item]
      end
    end)
  end
end
