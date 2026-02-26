defmodule PhoenixKit.Modules.Referrals.ReferralCodeUsage do
  @moduledoc """
  ReferralCodeUsage schema for tracking referral code usage in PhoenixKit.

  This schema records when and by whom referral codes are used.
  It provides an audit trail for code usage and helps with analytics.

  ## Fields

  - `code_uuid`: Foreign key to the referral code that was used
  - `used_by_uuid`: UUID of the user who used the code
  - `date_used`: Timestamp when the code was used

  ## Associations

  - `referral_code`: Belongs to the referral code that was used

  ## Usage Examples

      # Record a code usage
      %ReferralCodeUsage{}
      |> ReferralCodeUsage.changeset(%{
        code_uuid: referral_code.uuid,
        used_by_uuid: user.uuid
      })
      |> Repo.insert()

      # Get all usage records for a code
      from(usage in ReferralCodeUsage, where: usage.code_uuid == ^code_uuid)
      |> Repo.all()
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias PhoenixKit.Utils.Date, as: UtilsDate

  alias PhoenixKit.Modules.Referrals
  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_referral_code_usage" do
    field :used_by_uuid, UUIDv7
    field :date_used, :utc_datetime

    belongs_to :referral_code, Referrals, foreign_key: :code_uuid, references: :uuid, type: UUIDv7
  end

  @doc """
  Creates a changeset for referral code usage records.

  Validates that all required fields are present and automatically
  sets date_used on new records.
  """
  def changeset(usage_record, attrs) do
    usage_record
    |> cast(attrs, [:code_uuid, :used_by_uuid, :date_used])
    |> validate_required([:code_uuid, :used_by_uuid])
    |> foreign_key_constraint(:code_uuid)
    |> maybe_set_date_used()
  end

  @doc """
  Gets all usage records for a specific referral code.

  Returns a query that can be executed to get usage records ordered by date_used (most recent first).

  ## Examples

      iex> ReferralCodeUsage.for_code(code_uuid) |> Repo.all()
      [%ReferralCodeUsage{}, ...]
  """
  def for_code(code_uuid) when is_binary(code_uuid) do
    from u in __MODULE__,
      where: u.code_uuid == ^code_uuid,
      order_by: [desc: u.date_used]
  end

  @doc """
  Gets all usage records for a specific user.

  Returns a query that can be executed to get usage records ordered by date_used (most recent first).

  ## Examples

      iex> ReferralCodeUsage.for_user(user_uuid) |> Repo.all()
      [%ReferralCodeUsage{}, ...]
  """
  def for_user(user_uuid) when is_binary(user_uuid) do
    from u in __MODULE__,
      where: u.used_by_uuid == ^user_uuid,
      order_by: [desc: u.date_used]
  end

  @doc """
  Checks if a user has already used a specific referral code.

  Returns true if the user has used the code before, false otherwise.

  ## Examples

      iex> ReferralCodeUsage.user_used_code?(user_uuid, code_uuid)
      false
  """
  def user_used_code?(user_uuid, code_uuid) when is_binary(user_uuid) and is_binary(code_uuid) do
    query =
      from u in __MODULE__,
        where: u.used_by_uuid == ^user_uuid and u.code_uuid == ^code_uuid,
        limit: 1

    PhoenixKit.RepoHelper.repo().exists?(query)
  end

  @doc """
  Gets usage statistics for a referral code.

  Returns a map with usage counts and recent activity information.

  ## Examples

      iex> ReferralCodeUsage.get_usage_stats(code_uuid)
      %{
        total_uses: 5,
        unique_users: 3,
        last_used: ~U[2024-01-15 10:30:00Z],
        recent_users: [user_uuid1, user_uuid2]
      }
  """
  def get_usage_stats(code_uuid) when is_binary(code_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    base_query = from u in __MODULE__, where: u.code_uuid == ^code_uuid

    total_uses = repo.aggregate(base_query, :count)
    unique_users = repo.aggregate(base_query, :count, :used_by_uuid, distinct: true)

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
        select: u.used_by_uuid

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
    if changeset.data.__meta__.state == :built do
      put_change(changeset, :date_used, UtilsDate.utc_now())
    else
      changeset
    end
  end
end
