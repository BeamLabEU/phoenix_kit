defmodule PhoenixKit.Users.ManagedOrganizations.Locks do
  @moduledoc false

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  # Grant additions/removals and person lifecycle changes take this BEFORE
  # organization locks. It stabilizes the set of organizations a person manages
  # while a deactivate/delete discovers and locks that set in uuid order.
  def person!(uuid) do
    unless UUIDUtils.valid?(uuid), do: RepoHelper.repo().rollback(:invalid_reference)
    {:ok, canonical} = Ecto.UUID.cast(uuid)

    RepoHelper.repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "phoenix_kit:organization_manager:#{canonical}"
    ])
  end

  def managed_organization_ids(person_uuid) do
    RepoHelper.repo().all(
      from(m in OrganizationManager,
        where: m.user_uuid == ^person_uuid,
        select: m.organization_uuid
      )
    )
  end

  def users!(ids, lock \\ "FOR NO KEY UPDATE") do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
    unless Enum.all?(ids, &UUIDUtils.valid?/1), do: RepoHelper.repo().rollback(:invalid_reference)

    query = from(u in User, where: u.uuid in ^ids, order_by: u.uuid)

    query =
      case lock do
        "FOR NO KEY UPDATE" -> lock(query, "FOR NO KEY UPDATE")
        "FOR UPDATE" -> lock(query, "FOR UPDATE")
        "FOR KEY SHARE" -> lock(query, "FOR KEY SHARE")
      end

    RepoHelper.repo().all(query)
  end

  def organization!(uuid) do
    case users!([uuid]) do
      [%User{account_type: "organization"} = org] -> org
      _ -> RepoHelper.repo().rollback(:organization_not_found)
    end
  end

  def value!(:ok), do: :ok
  def value!({:ok, result}), do: result
  def value!({:error, reason}), do: RepoHelper.repo().rollback(reason)
end
