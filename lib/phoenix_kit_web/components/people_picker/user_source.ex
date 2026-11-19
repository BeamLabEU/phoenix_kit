defmodule PhoenixKitWeb.Components.PeoplePicker.UserSource do
  @moduledoc """
  The people picker's default source: the site's active accounts, as one
  group "People", searched by name, username and email. Service users
  (`api_only`) are not offered. A key is `{"user", user_uuid}`.

  Recent picks are the viewer's own, kept on their account
  (`custom_fields["people_picker_recent"]`, one list per `ctx[:recent_key]`,
  default `"users"`), so two pickers can keep separate lists.
  """

  @behaviour PhoenixKitWeb.Components.PeoplePicker.Source

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitWeb.Components.PeoplePicker.Recent

  @impl true
  def groups(_ctx), do: [%{key: "user", label: gettext("People")}]

  @impl true
  def page({:group, "user"}, cursor, limit, _ctx), do: users_page(base_query(), cursor, limit)

  def page({:search, text}, cursor, limit, _ctx) do
    pattern = "%" <> escape_like(text) <> "%"

    base_query()
    |> where(
      [u],
      ilike(u.first_name, ^pattern) or ilike(u.last_name, ^pattern) or
        ilike(u.username, ^pattern) or ilike(u.email, ^pattern) or
        ilike(u.organization_name, ^pattern) or
        ilike(fragment("concat_ws(' ', ?, ?)", u.first_name, u.last_name), ^pattern)
    )
    |> users_page(cursor, limit)
  end

  def page(_view, _cursor, _limit, _ctx), do: {[], nil}

  @impl true
  def describe({"user", uuid}, _ctx) when is_binary(uuid) do
    with {:ok, _} <- Ecto.UUID.cast(uuid),
         %User{} = user <- RepoHelper.repo().get(User, uuid),
         true <- user.is_active and not user.api_only do
      row(user)
    else
      _ -> nil
    end
  end

  def describe(_key, _ctx), do: nil

  @impl true
  def me(%{viewer_uuid: uuid}) when is_binary(uuid), do: {"user", uuid}
  def me(_ctx), do: nil

  @impl true
  def recent(limit, ctx) do
    ctx
    |> Recent.keys(recent_key(ctx))
    |> Enum.take(limit)
    |> Enum.flat_map(fn key -> List.wrap(describe(key, ctx)) end)
  end

  @impl true
  def remember(key, ctx), do: Recent.put(ctx, recent_key(ctx), key)

  @doc "The row of a loaded user (for callers building rows of their own)."
  @spec row(User.t()) :: PhoenixKitWeb.Components.PeoplePicker.Source.row()
  def row(%User{} = user) do
    name = User.display_name(user)

    %{
      kind: "user",
      uuid: user.uuid,
      label: name,
      sublabel: User.delivery_email(user),
      user: user,
      name: name
    }
  end

  defp recent_key(ctx), do: Map.get(ctx, :recent_key) || "users"

  defp base_query do
    from(u in User,
      where: u.is_active == true and u.api_only == false,
      order_by: [
        asc:
          fragment(
            "lower(coalesce(nullif(trim(concat_ws(' ', ?, ?)), ''), ?, ?))",
            u.first_name,
            u.last_name,
            u.username,
            u.email
          ),
        asc: u.uuid
      ]
    )
  end

  # Offset pages: a picker's list is short-lived, a person seldom pages far.
  defp users_page(query, cursor, limit) do
    offset = if is_integer(cursor) and cursor > 0, do: cursor, else: 0

    users =
      query
      |> offset(^offset)
      |> limit(^(limit + 1))
      |> RepoHelper.repo().all()

    {page, rest} = Enum.split(users, limit)
    {Enum.map(page, &row/1), if(rest == [], do: nil, else: offset + limit)}
  rescue
    _ -> {[], nil}
  end

  defp escape_like(text), do: String.replace(text, ~r/([\\%_])/, "\\\\\\1")
end
