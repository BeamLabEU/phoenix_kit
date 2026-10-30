defmodule PhoenixKit.Mentions.Users do
  @moduledoc """
  The `@` side of mentions: finding a person to ping.

  Separate from the `#` fan-out because a ping is always a person, and
  people are core's — there is no module to ask and no permission model to
  federate. What there IS is a decision about who may be pinged at all, and
  the rule shipped here is deliberately narrow:

    * only **active, confirmed** accounts (a pending invite cannot be
      pinged into existence, and a deactivated account is not a colleague);
    * only accounts that can reach the admin area at all, since every
      surface a mention currently appears on lives there — pinging a
      customer about an internal note would be the leak, not the feature.

  Matching is on username, then name, then email — email last and only on a
  prefix, so the typeahead cannot be used to confirm whether an address has
  an account by pasting it in.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.RolePermission

  @default_limit 8

  defp repo, do: RepoHelper.repo()

  @doc """
  People matching `query`, shaped for the typeahead.

  An empty query returns a short list of candidates rather than nothing:
  opening the picker with `@` and seeing who is around beats a blank box.

  The admin-area rule is evaluated in SQL (Owner/Admin role, or any
  `phoenix_kit_role_permissions` grant), not per-row after fetch. The earlier
  over-fetch + `Scope.for_user/1` filter issued two queries per candidate —
  up to ~128 round trips per keystroke on a full page of results.
  """
  @spec search(String.t(), keyword()) :: [map()]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    from(u in User, as: :user)
    |> where([user: u], u.is_active == true and not is_nil(u.confirmed_at))
    |> maybe_match(String.trim(query))
    |> where_pingable()
    |> order_by([user: u], asc: u.username, asc: u.email)
    |> limit(^limit)
    |> repo().all()
    |> Enum.map(&to_result/1)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp maybe_match(queryable, ""), do: queryable

  defp maybe_match(queryable, query) do
    contains = "%#{escape_like(query)}%"
    prefix = "#{escape_like(query)}%"

    where(
      queryable,
      [user: u],
      ilike(u.username, ^contains) or ilike(u.first_name, ^contains) or
        ilike(u.last_name, ^contains) or ilike(u.organization_name, ^contains) or
        fragment(
          "? ILIKE ?",
          fragment(
            "CASE WHEN ? THEN ? ELSE ? END",
            u.managed_by_members,
            u.contact_email,
            u.email
          ),
          ^prefix
        )
    )
  end

  # `%` and `_` in user input are wildcards to LIKE. Without escaping, a
  # single `%` matches every account in the system.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # Mirrors `Scope.can_access_admin_area?/1`: Owner or Admin role, OR any
  # module-permission grant on any of the user's roles. Pushed into the WHERE
  # so the typeahead pays one query per keystroke rather than two per
  # candidate. Floor is V135 (permissions table is V53), so the
  # role_permissions EXISTS is always against a real table on a current host.
  defp where_pingable(queryable) do
    roles = Role.system_roles()
    privileged = [roles.owner, roles.admin]

    where(
      queryable,
      [user: u],
      exists(
        from(ra in RoleAssignment,
          join: r in Role,
          on: r.uuid == ra.role_uuid,
          where: ra.user_uuid == parent_as(:user).uuid and r.name in ^privileged,
          select: 1
        )
      ) or
        exists(
          from(rp in RolePermission,
            join: ra in RoleAssignment,
            on: ra.role_uuid == rp.role_uuid,
            where: ra.user_uuid == parent_as(:user).uuid,
            select: 1
          )
        )
    )
  end

  defp to_result(%User{} = user) do
    %{
      kind: :user,
      type: "user",
      uuid: user.uuid,
      title: display_name(user),
      # NOT the email. The title deliberately degrades to a local part, and
      # printing the full address underneath it gives back exactly what that
      # was protecting — in a menu, next to a name, ready to copy.
      subtitle: nil
    }
  end

  @doc """
  The label a mention of this user carries — what the author saw when they
  picked, and the fallback when the account is later deleted.
  """
  @spec display_name(User.t()) :: String.t()
  def display_name(%User{} = user), do: User.display_name(user)
end
