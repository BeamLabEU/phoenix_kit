defmodule PhoenixKit.Modules.Shop.ImportLog do
  @moduledoc """
  ImportLog schema for tracking CSV import history.

  ## Fields

  - `filename` - Original filename (required)
  - `file_path` - Server path to uploaded file
  - `status` - pending | processing | completed | failed
  - `total_rows` - Total rows in CSV
  - `processed_rows` - Rows processed so far
  - `imported_count` - New products created
  - `updated_count` - Existing products updated
  - `skipped_count` - Products skipped (filtered)
  - `error_count` - Products with errors
  - `options` - Import options (JSONB)
  - `error_details` - List of error objects
  - `started_at` - Processing start time
  - `completed_at` - Processing end time
  - `user_id` - User who initiated import
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @statuses ["pending", "processing", "completed", "failed"]

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_shop_import_logs" do
    field :id, :integer, read_after_writes: true
    field :filename, :string
    field :file_path, :string
    field :status, :string, default: "pending"

    # Statistics
    field :total_rows, :integer, default: 0
    field :processed_rows, :integer, default: 0
    field :imported_count, :integer, default: 0
    field :updated_count, :integer, default: 0
    field :skipped_count, :integer, default: 0
    field :error_count, :integer, default: 0

    # Metadata
    field :options, :map, default: %{}
    field :error_details, {:array, :map}, default: []
    field :product_ids, {:array, :integer}, default: []

    # Timing
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    # Associations
    # legacy
    field :user_id, :integer
    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new import log.
  """
  def create_changeset(import_log \\ %__MODULE__{}, attrs) do
    import_log
    |> cast(attrs, [:filename, :file_path, :options, :user_id, :user_uuid])
    |> validate_required([:filename])
  end

  @doc """
  Changeset for updating import log status and stats.
  """
  def update_changeset(import_log, attrs) do
    import_log
    |> cast(attrs, [
      :status,
      :total_rows,
      :processed_rows,
      :imported_count,
      :updated_count,
      :skipped_count,
      :error_count,
      :error_details,
      :started_at,
      :completed_at
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Mark import as started.
  """
  def start_changeset(import_log, total_rows) do
    import_log
    |> change(%{
      status: "processing",
      total_rows: total_rows,
      started_at: UtilsDate.utc_now()
    })
  end

  @doc """
  Update progress during import.
  """
  def progress_changeset(import_log, attrs) do
    import_log
    |> cast(attrs, [
      :processed_rows,
      :imported_count,
      :updated_count,
      :skipped_count,
      :error_count
    ])
  end

  @doc """
  Mark import as completed.
  """
  def complete_changeset(import_log, stats) do
    import_log
    |> cast(stats, [
      :imported_count,
      :updated_count,
      :skipped_count,
      :error_count,
      :error_details,
      :product_ids
    ])
    |> change(%{
      status: "completed",
      processed_rows: import_log.total_rows,
      completed_at: UtilsDate.utc_now()
    })
  end

  @doc """
  Mark import as failed.
  """
  def fail_changeset(import_log, error) do
    error_details = [%{"error" => inspect(error), "timestamp" => DateTime.utc_now()}]

    import_log
    |> change(%{
      status: "failed",
      error_details: error_details,
      completed_at: UtilsDate.utc_now()
    })
  end

  @doc """
  Returns the percentage of completion.
  """
  def progress_percent(%__MODULE__{total_rows: 0}), do: 0

  def progress_percent(%__MODULE__{processed_rows: processed, total_rows: total}) do
    trunc(processed / total * 100)
  end

  @doc """
  Check if import is in progress.
  """
  def in_progress?(%__MODULE__{status: "processing"}), do: true
  def in_progress?(_), do: false

  @doc """
  Check if import is finished (completed or failed).
  """
  def finished?(%__MODULE__{status: status}) when status in ["completed", "failed"], do: true
  def finished?(_), do: false
end
