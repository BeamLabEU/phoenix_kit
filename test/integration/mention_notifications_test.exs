defmodule PhoenixKit.Integration.MentionNotificationsTest do
  @moduledoc """
  An @ ping, as the person mentioned sees it: who mentioned them, in their
  language, with a link that takes them to the mention — and a type of its
  own, so it can be muted or sent on by email like any other notification.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Mentions
  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.{ChannelConfig, Render, Routing, Types}
  alias PhoenixKit.Users.Auth

  defp user(attrs \\ %{}) do
    {:ok, user} =
      Auth.register_user(%{
        email: "mention_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    if attrs == %{} do
      user
    else
      {:ok, user} = Auth.update_user_profile(user, attrs)
      user
    end
  end

  # What a module does on save: index the text, then ping what is new.
  defp mention(author, target, opts) do
    source = Ecto.UUID.generate()
    label = Keyword.get(opts, :label, "Ada")
    text = "Hi @[user:#{target.uuid}|#{label}]"

    {:ok, new} = Mentions.sync("comment", source, text, field: "content", actor_uuid: author.uuid)

    Mentions.notify(
      new,
      Keyword.merge([source_type: "comment", source_uuid: source, preview: text], opts)
    )
  end

  defp inbox(user) do
    {entries, _total} = Notifications.list_for_user(user.uuid, status: :all)
    Enum.map(entries, &Render.render(&1, "en"))
  end

  test "the person mentioned is told who mentioned them, and where" do
    author = user(%{"first_name" => "Grace", "last_name" => "Hopper"})
    ada = user()

    mention(author, ada, link: "/admin/posts/1#pk-comment-2")

    assert [%{text: "Grace Hopper mentioned you.", icon: "hero-at-symbol", link: link}] =
             inbox(ada)

    assert link == "/admin/posts/1#pk-comment-2"
  end

  test "a link that is not a path on this site is dropped" do
    author = user(%{"first_name" => "Grace"})
    ada = user()

    for bad <- ["https://evil.example/x", "//evil.example/x", "/\\evil.example", "javascript:x"] do
      mention(author, ada, link: bad)
    end

    assert Enum.all?(inbox(ada), &is_nil(&1.link))
  end

  test "an author with no name is shown by their username, never their address" do
    author = user()
    ada = user()

    mention(author, ada, [])

    assert [%{text: text, link: nil}] = inbox(ada)
    assert text == "#{author.username} mentioned you."
    refute text =~ "@"
  end

  test "a mention with no author name, or from before names were stored, still reads" do
    entry = fn metadata ->
      %PhoenixKit.Notifications.Notification{
        activity: %PhoenixKit.Activity.Entry{action: "mention.created", metadata: metadata}
      }
    end

    assert %{text: "You were mentioned.", icon: "hero-at-symbol"} =
             Render.render(entry.(%{}), "en")

    # In the reader's language, not the writer's.
    assert %{text: "Вас упомянули."} = Render.render(entry.(%{}), "ru")

    assert %{text: "Ada hat Sie erwähnt."} =
             Render.render(entry.(%{"actor_name" => "Ada"}), "de")

    # Rows written before the name was stored carry their own text.
    assert %{text: "You were mentioned"} =
             Render.render(entry.(%{"notification_text" => "You were mentioned"}), "en")
  end

  test "mentioning yourself tells nobody" do
    author = user(%{"first_name" => "Grace"})
    mention(author, author, [])
    assert inbox(author) == []
  end

  test "mentions are a notification type of their own" do
    assert Types.key_for_action("mention.created") == "mentions"
    assert "mentions" in Types.base_keys()
  end

  test "routed to email once the person turns email on for mentions" do
    ada = user()
    assert Routing.targets_for_action(ada, "mention.created") == []

    {:ok, _} = ChannelConfig.put(ada, "email", %{"types" => %{"mentions" => true}})
    ada = Auth.get_user(ada.uuid)

    assert "email" in Enum.map(Routing.targets_for_action(ada, "mention.created"), fn {channel, _} ->
             channel.key()
           end)
  end
end
