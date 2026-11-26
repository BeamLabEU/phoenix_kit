defmodule PhoenixKit.Users.CommentResourcesTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CommentResources

  test "resolves a user to its display title + admin detail path" do
    {:ok, user} =
      Auth.register_user(%{email: "moderate-me@example.com", password: "ValidPassword123!"})

    result = CommentResources.resolve_comment_resources([user.uuid])

    # This module is the registered handler for the "user" type, so it names
    # every `@` mention there is — public issue boards included. It used to
    # answer with the full address, and this test pinned that. The title is
    # now the auto-generated username; what matters is that the address
    # itself never comes back.
    assert %{title: title, path: path} = result[user.uuid]
    refute title == user.email
    refute title =~ "@"
    # Raw path — comments applies Routes.path/1 when rendering the chip.
    assert path == "/admin/users/view/#{user.uuid}"
    # No uploaded picture: the face by the rule of every face (Max,
    # 2026-11-26), here Gravatar, uncropped. Only the comments admin list
    # reads the thumbnail; mentions use the title.
    assert result[user.uuid].thumb_url =~ "gravatar.com/avatar/"
    refute Map.has_key?(result[user.uuid], :thumb_style)
  end

  test "unknown or empty uuid lists resolve to an empty map" do
    assert CommentResources.resolve_comment_resources([Ecto.UUID.generate()]) == %{}
    assert CommentResources.resolve_comment_resources([]) == %{}
  end
end
