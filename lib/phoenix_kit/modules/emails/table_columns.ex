defmodule PhoenixKit.Modules.Emails.TableColumns do
  @moduledoc """
  Manages table column customization for email logs display.

  Provides functionality to:
  - Define available columns for email logs table
  - Load user's column preferences from Settings
  - Save column preferences to Settings
  - Reorder columns via drag-and-drop

  Column preferences are stored in Settings under the key "emails_table_columns".
  """

  alias PhoenixKit.Settings

  @default_columns ["to", "subject", "status", "details", "actions"]
  @required_columns ["to", "actions"]

  @doc """
  Returns all available columns for email logs table with metadata.

  Column structure:
  - `field`: Database field name
  - `label`: Display label in UI
  - `type`: Data type (:string, :datetime, :badge, :actions, :activity_events, :details_composite)
  - `required`: Cannot be hidden if true

  ## Examples

      iex> PhoenixKit.Emails.TableColumns.get_available_columns()
      [
        %{field: "to", label: "Email", type: :string, required: true},
        %{field: "subject", label: "Subject", type: :string, required: true},
        ...
      ]
  """
  def get_available_columns do
    [
      %{field: "to", label: "Email", type: :string, required: true},
      %{field: "subject", label: "Subject", type: :string, required: false},
      %{field: "status", label: "Status", type: :activity_events, required: false},
      %{field: "details", label: "Details", type: :details_composite, required: false},
      %{field: "actions", label: "Actions", type: :actions, required: true}
    ]
  end

  @doc """
  Loads user's selected columns from Settings or returns defaults.

  Returns list of column field names in user's preferred order.

  ## Examples

      iex> PhoenixKit.Emails.TableColumns.get_user_table_columns()
      ["to", "subject", "status", "sent_at", "actions"]
  """
  def get_user_table_columns do
    case Settings.get_setting("emails_table_columns") do
      nil ->
        @default_columns

      columns_json when is_binary(columns_json) ->
        case Jason.decode(columns_json) do
          {:ok, %{"selected" => selected}} when is_list(selected) ->
            # Validate that all required columns are present
            validated = ensure_required_columns(selected)
            validated

          _ ->
            @default_columns
        end

      _ ->
        @default_columns
    end
  end

  @doc """
  Saves user's column preferences to Settings.

  ## Parameters

    - `selected_columns`: List of column field names in desired order

  ## Examples

      iex> PhoenixKit.Emails.TableColumns.update_user_table_columns(["to", "subject", "status", "actions"])
      {:ok, _setting}
  """
  def update_user_table_columns(selected_columns) when is_list(selected_columns) do
    # Ensure required columns are always included
    validated_columns = ensure_required_columns(selected_columns)

    columns_data = %{
      "selected" => validated_columns,
      "order" => validated_columns
    }

    case Jason.encode(columns_data) do
      {:ok, json} ->
        Settings.update_setting("emails_table_columns", json)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Reorders columns based on drag-and-drop interaction.

  ## Parameters

    - `current_columns`: Current list of selected columns
    - `params`: Map with "from" (source index) and "to" (target index)

  ## Examples

      iex> PhoenixKit.Emails.TableColumns.reorder_columns(["to", "subject", "status"], %{"from" => 0, "to" => 2})
      ["subject", "status", "to"]
  """
  def reorder_columns(current_columns, %{"from" => from_idx, "to" => to_idx})
      when is_list(current_columns) do
    from_index = String.to_integer(from_idx)
    to_index = String.to_integer(to_idx)

    if from_index >= 0 and from_index < length(current_columns) and
         to_index >= 0 and to_index < length(current_columns) do
      element = Enum.at(current_columns, from_index)

      current_columns
      |> List.delete_at(from_index)
      |> List.insert_at(to_index, element)
    else
      current_columns
    end
  end

  def reorder_columns(current_columns, _params), do: current_columns

  @doc """
  Resets columns to default configuration.

  ## Examples

      iex> PhoenixKit.Emails.TableColumns.reset_columns()
      ["to", "subject", "status", "sent_at", "actions"]
  """
  def reset_columns do
    @default_columns
  end

  # Private Functions

  defp ensure_required_columns(columns) do
    # Add any missing required columns at the end
    missing_required = @required_columns -- columns

    (columns ++ missing_required)
    |> Enum.uniq()
  end
end
