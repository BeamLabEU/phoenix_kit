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

  defmodule OpenHandler do
    @moduledoc false
    # A source whose every record every user may read: visibility :yes.
    def visible_resource_uuids(uuids, _opts), do: uuids
  end

  defmodule GateHandler do
    @moduledoc false
    # Every record readable until the test closes the gate.
    def visible_resource_uuids(uuids, _opts) do
      if Application.get_env(:phoenix_kit, :mention_test_gate_closed), do: [], else: uuids
    end
  end

  describe "the comment as the notification's quote" do
    setup do
      previous = Application.get_env(:phoenix_kit, :comment_resource_handlers)

      Application.put_env(:phoenix_kit, :comment_resource_handlers, %{
        "open_thing" => OpenHandler,
        "gated_thing" => GateHandler
      })

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :comment_resource_handlers, previous),
          else: Application.delete_env(:phoenix_kit, :comment_resource_handlers)
      end)
    end

    test "a reader the source lets read it gets the whole comment as the quote" do
      author = user(%{"first_name" => "Grace", "last_name" => "Hopper"})
      ada = user()
      long = String.duplicate("word ", 60)

      mention(author, ada, source_type: "open_thing", preview: "short", quote: "Hi Ada. " <> long)

      {[n], _} = Notifications.list_for_user(ada.uuid, status: :all)
      q = Render.quote(n)
      assert q.text == String.trim("Hi Ada. " <> long)
      assert q.author_uuid == author.uuid
    end

    test "a reader who lost access by delivery time gets the line, not the quote" do
      on_exit(fn -> Application.delete_env(:phoenix_kit, :mention_test_gate_closed) end)
      author = user()
      ada = user()
      mention(author, ada, source_type: "gated_thing", quote: "the secret")

      {[n], _} = Notifications.list_for_user(ada.uuid, status: :all)
      assert Types.still_visible?("mentions", n, ada)

      Application.put_env(:phoenix_kit, :mention_test_gate_closed, true)
      refute Types.still_visible?("mentions", n, ada)
    end

    test "a deleted comment's words leave the mention; the ping stays" do
      author = user()
      ada = user()
      source = Ecto.UUID.generate()
      text = "Hi @[user:#{ada.uuid}|Ada], the client offered 40k"

      {:ok, new} =
        Mentions.sync("comment", source, text, field: "content", actor_uuid: author.uuid)

      Mentions.notify(new,
        source_type: "open_thing",
        source_uuid: Ecto.UUID.generate(),
        preview: text,
        quote: text
      )

      {[n], _} = Notifications.list_for_user(ada.uuid, status: :all)
      assert Render.quote(n).text =~ "40k"

      assert Mentions.forget_source("comment", source) == 1

      {[n], _} = Notifications.list_for_user(ada.uuid, status: :all)
      assert Render.quote(n) == nil
      assert Render.render(n, "en").text =~ "mentioned you"
    end

    test "without a `:quote`, the uncut preview is the quote" do
      author = user()
      ada = user()
      mention(author, ada, source_type: "open_thing")

      {[n], _} = Notifications.list_for_user(ada.uuid, status: :all)
      assert Render.quote(n).text =~ "Hi @Ada"
    end
  end

  test "a source nobody can vouch for carries no quote" do
    author = user()
    ada = user()
    mention(author, ada, quote: "secret comment")

    {[n], _} = Notifications.list_for_user(ada.uuid, status: :all)
    assert Render.quote(n) == nil
  end

  test "with mentions switched off nobody is pinged" do
    PhoenixKit.Settings.update_boolean_setting(Mentions.enabled_setting_key(), false)

    on_exit(fn ->
      PhoenixKit.Settings.update_boolean_setting(Mentions.enabled_setting_key(), true)
    end)

    author = user()
    ada = user()
    mention(author, ada, [])

    assert inbox(ada) == []
  end

  test "a re-save keeps the row a mention already has (a pending claim still lands)" do
    author = user()
    ada = user()
    source = Ecto.UUID.generate()
    text = "Hi @[user:#{ada.uuid}|Ada]"

    {:ok, [first]} =
      Mentions.sync("comment", source, text, field: "content", actor_uuid: author.uuid)

    # A second tab saves the same mention before the first one claims it.
    {:ok, []} =
      Mentions.sync("comment", source, text <> "!", field: "content", actor_uuid: author.uuid)

    assert [%{uuid: uuid}] = Mentions.list_for_source("comment", source, "content")
    assert uuid == first.uuid
    assert [%{uuid: ^uuid}] = Mentions.claim_for_delivery([first])

    # A renamed label is followed; a mention taken out goes.
    {:ok, []} =
      Mentions.sync("comment", source, "Hi @[user:#{ada.uuid}|Ada L.]", field: "content")

    assert [%{uuid: ^uuid, label: "Ada L."}] =
             Mentions.list_for_source("comment", source, "content")

    {:ok, []} = Mentions.sync("comment", source, "nobody", field: "content")
    assert Mentions.list_for_source("comment", source, "content") == []
  end

  test "the link follows the reader's language, not the author's" do
    {:ok, _} = PhoenixKit.Modules.Languages.enable_system()
    {:ok, _} = PhoenixKit.Modules.Languages.add_language("et")
    author = user()
    ada = user()

    # Built in the author's Estonian page, as a caller builds it.
    stored = PhoenixKit.Utils.Routes.path("/admin/posts/1?x=1#pk-comment-2", locale: "et")
    assert stored =~ "/et/"
    mention(author, ada, link: stored)

    {[n], _} = Notifications.list_for_user(ada.uuid, status: :all)
    link = Render.render(n, "en").link
    refute link =~ "/et/"
    assert link =~ "/admin/posts/1?x=1#pk-comment-2"

    assert Render.render(n, "et").link == stored
  end
end
