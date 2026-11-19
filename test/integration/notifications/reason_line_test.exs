defmodule PhoenixKit.Integration.Notifications.ReasonLineTest do
  @moduledoc """
  Every notification names the setting line that sent it and links to it
  (the boss, 2026-11-18: he could not tell which line tells people a task
  can be started). They are sent to the matrix
  row on My Settings when they reach the admin area; anyone else to their
  profile's Notifications section.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Notifications.Render
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles

  defp notification(action),
    do: %Notification{activity: %Entry{action: action, metadata: %{}}, metadata: %{}}

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        email: "reason_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    if role, do: {:ok, _} = Roles.assign_role(user, role)
    Auth.get_user(user.uuid)
  end

  test "a line's label joins a sub-type to its type" do
    assert Types.line_label("account") == "Account"
    assert Types.line_label("posts.comments") == "Posts › Comments"
    assert Types.line_label("nope") == nil
    assert Types.line_label(nil) == nil
  end

  test "an admin's reason links to the matrix row" do
    why = Render.reason(notification("user.password_changed"), user!("Admin"))

    assert why.key == "account"
    assert why.text == "You get this because “Account” is on."
    assert why.link =~ "/admin/notifications/settings#notif-account"
  end

  test "a sub-type's row anchor keeps its dot" do
    why = Render.reason(notification("post.commented"), user!("Admin"))

    assert why.key == "posts.comments"
    assert why.link =~ "#notif-posts.comments"
  end

  test "someone outside the admin area is sent to their profile settings" do
    why = Render.reason(notification("user.password_changed"), user!(nil))
    assert why.link =~ "/profile/settings#notification-settings"
  end

  test "an action no line owns has no reason" do
    assert Render.reason(notification("something.unknown"), user!(nil)) == nil
    assert Render.reason(%Notification{activity: nil, metadata: %{}}, nil) == nil
  end

  test "a standalone notification with a type key has its reason" do
    why =
      Render.reason(%Notification{activity: nil, metadata: %{"type" => "security"}}, user!(nil))

    assert why.key == "security"
  end

  describe "a quote" do
    defp quoted(meta),
      do: %Notification{
        activity: %Entry{action: "user.password_changed", metadata: meta},
        metadata: %{}
      }

    test "is read from the activity, mention tokens shown as their labels" do
      q =
        Render.quote(
          quoted(%{
            "quote" => %{
              "text" => "  Thanks @[user:019a0000-0000-7000-8000-000000000001|Anna], done.  ",
              "author_uuid" => "019a0000-0000-7000-8000-000000000002",
              "author_name" => "Max"
            }
          })
        )

      assert q.text == "Thanks @Anna, done."
      assert q.author_uuid == "019a0000-0000-7000-8000-000000000002"
      assert q.author_name == "Max"
      refute q.truncated?
    end

    test "an empty text, or none, is no quote" do
      assert Render.quote(quoted(%{"quote" => %{"text" => "   "}})) == nil
      assert Render.quote(quoted(%{"quote" => "not a map"})) == nil
      assert Render.quote(quoted(%{})) == nil
    end

    test "a long text is cut for display" do
      q = Render.quote(quoted(%{"quote" => %{"text" => String.duplicate("a", 2500)}}))
      assert q.truncated?
      assert String.length(q.text) == 2001
    end

    test "a standalone notification's quote is read too" do
      q = Render.quote(%Notification{activity: nil, metadata: %{"quote" => %{"text" => "Hi"}}})
      assert q.text == "Hi"
    end

    test "as plain text, with the writer's name when there is one" do
      assert Render.quote_text(%{text: "Done"}, "Anna Kask") == "Anna Kask: “Done”"
      assert Render.quote_text(%{text: "Done"}, nil) == "“Done”"
      assert Render.quote_text(nil, "Anna") == nil
    end
  end
end
