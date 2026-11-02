defmodule PhoenixKit.Modules.Storage.Libraries.MembershipHistory do
  @moduledoc """
  Durable membership events in Activity, scoped to a library's current owner
  and managers. Records contain account UUIDs and roles, never name or email
  snapshots. Membership writers insert them in their own transaction.
  """
  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage.{Libraries, Library, LibraryMember}
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @actions ~w(storage.library.member_added storage.library.member_role_changed storage.library.member_removed storage.library.member_left)
  @page_size 20

  @doc "Whether this scope currently manages membership of this live user library."
  def can_read?(scope, library_uuid) do
    with uuid when is_binary(uuid) <- active_user_uuid(scope),
         %Library{kind: "user"} = library <- Libraries.get_library(library_uuid) do
      Libraries.role(library, uuid) in [:owner, :manager]
    else
      _ -> false
    end
  end

  @doc "A bounded, newest-first page; authorization is checked afresh on every call."
  def list(scope, library_uuid, page \\ 1) do
    if can_read?(scope, library_uuid) do
      query =
        from(e in Entry,
          where:
            e.module == "storage" and e.resource_type == "library" and
              e.resource_uuid == ^library_uuid and e.action in ^@actions
        )

      total = repo().aggregate(query, :count)
      pages = max(1, ceil(total / @page_size))
      page = if is_integer(page), do: page |> max(1) |> min(pages), else: 1

      entries =
        query
        |> order_by([e], desc: e.inserted_at, desc: e.uuid)
        |> limit(^@page_size)
        |> offset(^((page - 1) * @page_size))
        |> repo().all()
        |> repo().preload([:actor, :target])

      people =
        entries
        |> Enum.map(& &1.metadata["acting_user_uuid"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Auth.get_users_by_uuids()
        |> Map.new(&{&1.uuid, &1})

      {:ok, %{entries: entries, people: people, total: total, page: page, pages: pages}}
    else
      {:error, :not_allowed}
    end
  end

  @doc "Filters membership records out of a non-administrator's general activity query when access is lost."
  def visible_query(query, scope) do
    case active_user_uuid(scope) do
      nil ->
        from(e in query, where: e.action not in ^@actions)

      uuid ->
        libraries =
          from(l in Library,
            left_join: m in LibraryMember,
            on: m.library_uuid == l.uuid and m.user_uuid == ^uuid,
            where:
              l.kind == "user" and is_nil(l.trashed_at) and
                (l.owner_uuid == ^uuid or m.role == "manager"),
            select: l.uuid
          )

        from(e in query,
          where: e.action not in ^@actions or e.resource_uuid in subquery(libraries)
        )
    end
  end

  @doc "The corresponding gate for a single general-activity entry."
  def visible_entry?(scope, %Entry{action: action, resource_uuid: uuid}) when action in @actions,
    do: can_read?(scope, uuid)

  def visible_entry?(_scope, _entry), do: true

  defp active_user_uuid(scope) do
    case Scope.user_uuid(scope) do
      uuid when is_binary(uuid) ->
        case Auth.get_user(uuid) do
          %{is_active: true} -> uuid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
