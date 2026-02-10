defmodule PhoenixKit.Modules.Referrals.ReferralCodeUsage do
  @moduledoc """
  ReferralCodeUsage schema for tracking referral code usage in PhoenixKit.

  This schema records when and by whom referral codes are used.
  It provides an audit trail for code usage and helps with analytics.

  ## Fields

  - `code_id`: Foreign key to the referral code that was used
  - `used_by`: User ID of the user who used the code
  - `date_used`: Timestamp when the code was used

  ## Associations

  - `referral_code`: Belongs to the referral code that was used
  - `user`: Belongs to the User who used the code (via used_by field)

  ## Usage Examples

      # Record a code usage
      %ReferralCodeUsage{}
      |> ReferralCodeUsage.changeset(%{
        code_id: referral_code.id,
        used_by: user.id
      })
      |> Repo.insert()

      # Get all usage records for a code
      from(usage in ReferralCodeUsage, where: usage.code_id == ^code_id)
      |> Repo.all()
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias PhoenixKit.Modules.Referrals

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_referral_code_usage" do
    field :uuid, Ecto.UUID, read_after_writes: true
    field :used_by, :integer
    field :date_used, :utc_datetime_usec

    belongs_to :referral_code, Referrals, foreign_key: :code_id
  end

  @doc """
  Creates a changeset for referral code usage records.

  Validates that all required fields are present and automatically
  sets date_used on new records.
  """
  def changeset(usage_record, attrs) do
    usage_record
    |> cast(attrs, [:code_id, :used_by, :date_used])
    |> validate_required([:code_id, :used_by])
    |> foreign_key_constraint(:code_id)
    |> validate_number(:used_by, greater_than: 0)
    |> maybe_set_date_used()
  end

  @doc """
  Gets all usage records for a specific referral code.

  Returns a query that can be executed to get usage records ordered by date_used (most recent first).

  ## Examples

      iex> ReferralCodeUsage.for_code(code_id) |> Repo.all()
      [%ReferralCodeUsage{}, ...]
  """
  def for_code(code_id) do
    from u in __MODULE__,
      where: u.code_id == ^code_id,
      order_by: [desc: u.date_used]
  end

  @doc """
  Gets all usage records for a specific user.

  Returns a query that can be executed to get usage records ordered by date_used (most recent first).

  ## Examples

      iex> ReferralCodeUsage.for_user(user_id) |> Repo.all()
      [%ReferralCodeUsage{}, ...]
  """
  def for_user(user_id) do
    from u in __MODULE__,
      where: u.used_by == ^user_id,
      order_by: [desc: u.date_used]
  end

  @doc """
  Checks if a user has already used a specific referral code.

  Returns true if the user has used the code before, false otherwise.

  ## Examples

      iex> ReferralCodeUsage.user_used_code?(user_id, code_id)
      false
  """
  def user_used_code?(user_id, code_id) do
    query =
      from u in __MODULE__,
        where: u.used_by == ^user_id and u.code_id == ^code_id,
        limit: 1

    PhoenixKit.RepoHelper.repo().exists?(query)
  end

  @doc """
  Gets usage statistics for a referral code.

  Returns a map with usage counts and recent activity information.

  ## Examples

      iex> ReferralCodeUsage.get_usage_stats(code_id)
      %{
        total_uses: 5,
        unique_users: 3,
        last_used: ~U[2024-01-15 10:30:00.000000Z],
        recent_users: [user_id1, user_id2]
      }
  """
  def get_usage_stats(code_id) do
    repo = PhoenixKit.RepoHelper.repo()

    base_query = from u in __MODULE__, where: u.code_id == ^code_id

    total_uses = repo.aggregate(base_query, :count)
    unique_users = repo.aggregate(base_query, :count, :used_by, distinct: true)

    last_used_query =
      from u in base_query,
        order_by: [desc: u.date_used],
        limit: 1,
        select: u.date_used

    last_used = repo.one(last_used_query)

    recent_users_query =
      from u in base_query,
        order_by: [desc: u.date_used],
        limit: 5,
        select: u.used_by

    recent_users = repo.all(recent_users_query)

    %{
      total_uses: total_uses,
      unique_users: unique_users,
      last_used: last_used,
      recent_users: recent_users
    }
  end

  # Private helper to set date_used on new records
  defp maybe_set_date_used(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :date_used, DateTime.utc_now())
      _id -> changeset
    end
  end
end
