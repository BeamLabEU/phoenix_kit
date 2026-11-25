defmodule PhoenixKit.Mentions.UserSuggestionsTest do
  @moduledoc """
  The `@` list's people (Max, 2026-11-25): a face, the name and the
  @username for everyone; the email only for a searcher who manages users
  (the person card's rule). The face is a picture stored on this site or
  initials, never a third party's.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Mentions
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  setup do
    # The first account of a fresh database becomes Owner.
    _owner = create_admin_user()

    {anna, _} = create_admin_user("anna-#{System.unique_integer([:positive])}@example.com")

    {:ok, anna} =
      Auth.update_user_profile(anna, %{
        "first_name" => "Anna",
        "last_name" => "Kask",
        "username" => "anna_k#{System.unique_integer([:positive])}"
      })

    %{anna: anna}
  end

  defp row(results, uuid), do: Enum.find(results, &(&1.uuid == uuid))

  # Reaches the admin area through one permission, not `users`.
  defp narrow_scope do
    {:ok, viewer} =
      Auth.register_user(%{
        email: "narrow-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, viewer} = Auth.admin_confirm_user(viewer)
    {:ok, role} = Roles.create_role(%{name: "Narrow #{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "media")
    {:ok, _} = Roles.assign_role(viewer, role.name)
    Scope.for_user(Repo.get!(Auth.User, viewer.uuid))
  end

  test "a user manager sees the face, the name, the @username and the email", %{anna: anna} do
    {admin, _} = create_admin_user()
    scope = Scope.for_user(admin)

    r = row(Mentions.search(:user, "Anna", scope: scope, user_uuid: admin.uuid), anna.uuid)

    assert row(Mentions.search(:user, anna.email, scope: scope), anna.uuid)
    assert r.title == "Anna Kask"
    assert r.subtitle == "@#{anna.username} · #{anna.email}"
    assert r.avatar.initials == "AK"
    assert is_binary(r.avatar.gradient)
    # No stored picture: initials, and no Gravatar URL in its place.
    assert r.avatar.url == nil
  end

  test "anyone else sees the @username but never the email", %{anna: anna} do
    scope = narrow_scope()
    refute row(Mentions.search(:user, anna.email, scope: scope), anna.uuid)
    r = row(Mentions.search(:user, "Anna", scope: scope), anna.uuid)

    assert r.subtitle == "@#{anna.username}"
    refute r.subtitle =~ "@example.com"
  end

  test "no scope at all shows no email either", %{anna: anna} do
    r = row(Mentions.search(:user, "Anna", []), anna.uuid)
    refute (r.subtitle || "") =~ "@example.com"
  end
end
