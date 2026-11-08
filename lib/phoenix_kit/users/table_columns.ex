defmodule PhoenixKit.Users.TableColumns do
  @moduledoc """
  The Users table's columns: the standard user fields plus the enabled
  custom fields, with their metadata.

  Each admin picks their own through `PhoenixKitWeb.TableColumns`
  (`columns_spec/0`, view key `"users"`). The `user_table_columns` setting
  this module also reads and writes is the site's default — what an admin
  who has not chosen sees — not anyone's current choice. The Actions
  column is always last and is not one of the columns an admin picks.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

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
        "email" => %{label: "Account", field: "email", required: false},
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

  # The standard columns in the order the column picker offers them.
  @standard_order ~w(avatar email username full_name role status registered location last_confirmed)

  @doc """
  The spec `PhoenixKitWeb.TableColumns` needs for the Users table: every
  standard and custom column (Actions is not one — it is always last), the
  built-in defaults, and the site's default from `user_table_columns`.
  """
  @spec columns_spec() :: map()
  def columns_spec do
    available = get_available_columns()

    standard =
      for id <- @standard_order, meta = available.standard[id] do
        %{id: id, label: meta.label, group: gettext("Standard fields")}
      end

    custom =
      for {id, meta} <- Enum.sort_by(available.custom, fn {id, _} -> id end) do
        %{id: id, label: meta.label, group: gettext("Custom fields")}
      end

    %{
      key: "users",
      columns: standard ++ custom,
      defaults: List.delete(get_default_columns(), "actions"),
      site_default: &site_columns/0
    }
  end

  @doc """
  The site's default columns (without Actions), or `nil` when the site has
  not set one.
  """
  @spec site_columns() :: [String.t()] | nil
  def site_columns do
    with json when is_binary(json) and json != "" <- Settings.get_setting("user_table_columns"),
         {:ok, columns} when is_list(columns) <- JSON.decode(json) do
      List.delete(columns, "actions")
    else
      _ -> nil
    end
  end

  @doc """
  Gets the default column configuration.

  Returns the list of columns that should be visible by default
  if no user preference is saved in settings.
  """
  def get_default_columns do
    # Every standard column, in the order they have always shown, with the
    # avatar first: it was drawn inside the first column before it became a
    # column of its own. "username" is left out — the first column already
    # shows it (@username under the email) — but the picker still offers it.
    standard_fields =
      get_standard_columns()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reject(&(&1 in ["avatar", "username"]))

    ["avatar" | standard_fields] ++ ["actions"]
  end

  @doc """
  The site's default columns, Actions included, falling back to the
  built-in default when the site has none. An admin's own choice is read
  through `PhoenixKitWeb.TableColumns` (`columns_spec/0`).

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
          case JSON.decode(json_value) do
            {:ok, columns} when is_list(columns) -> columns
            _ -> default_columns
          end
      end

    columns
  end

  @doc """
  Sets the site's default columns — what an admin who has not chosen their
  own sees. Actions is kept, last.

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

    Settings.update_setting("user_table_columns", JSON.encode!(ordered_columns))
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
      %{label: "Account", field: "email", required: false, type: :email}
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
      # Its own column so an admin can hide it. The header is read by screen
      # readers and the column picker only.
      "avatar" => %{
        label: gettext("Avatar"),
        field: nil,
        required: false,
        type: :avatar
      },
      # Still "email" as an id, so saved column choices keep working. It holds
      # a person's email, or a company's name over its email, so it is headed
      # "Account".
      "email" => %{
        label: gettext("Account"),
        field: "email",
        required: false,
        type: :email
      },
      "username" => %{
        label: gettext("Username"),
        field: "username",
        required: false,
        type: :string
      },
      "full_name" => %{
        label: gettext("Full Name"),
        field: "first_name",
        required: false,
        type: :composite,
        formatter: &format_full_name/1
      },
      "role" => %{
        label: gettext("Roles"),
        field: "roles",
        required: false,
        type: :roles
      },
      "status" => %{
        label: gettext("Status"),
        field: "is_active",
        required: false,
        type: :status
      },
      "registered" => %{
        label: gettext("Registered"),
        field: "inserted_at",
        required: false,
        type: :datetime
      },
      "location" => %{
        label: gettext("Location"),
        field: "registration_country",
        required: false,
        type: :location
      },
      "last_confirmed" => %{
        label: gettext("Last Confirmed"),
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
              # The Users table's header when set; `label` stays the full
              # label, which the picker, the cards and the forms show.
              column_label: field["column_label"],
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
