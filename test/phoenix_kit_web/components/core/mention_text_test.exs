defmodule PhoenixKitWeb.Components.Core.MentionTextTest do
  @moduledoc """
  The renderer's job is a permission decision, and its input is attacker
  controlled: a token can be TYPED by hand into any textarea, so the label
  is not "whatever the picker produced" — it is whatever anyone can write.
  """
  use PhoenixKit.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.Core.MentionText

  @uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"

  defp render_text(text, opts \\ []) do
    render_component(&MentionText.mention_text/1,
      text: text,
      scope: Keyword.get(opts, :scope),
      allow_request: Keyword.get(opts, :allow_request, true)
    )
  end

  describe "escaping" do
    test "a hand-typed label cannot inject markup" do
      html = render_text("see #[project:#{@uuid}|<script>alert(1)</script>]")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "an event-handler payload cannot break out of an attribute" do
      # A quote-and-attribute breakout, built without sigils so the test
      # source itself stays readable.
      payload = "see #[project:" <> @uuid <> "|" <> ~s(" onmouseover="alert\(1\)) <> "]"
      html = render_text(payload)

      # The payload survives as TEXT — what matters is that its quotes are
      # entity-escaped, so it can never close an attribute and start a new
      # one. Asserting the substring is absent would be wrong: the words
      # are allowed to appear, the syntax is not.
      refute html =~ ~s(onmouseover="alert)
      assert html =~ "&quot;"
    end

    test "ordinary text around a mention is escaped too" do
      html = render_text("<b>hi</b> #[project:#{@uuid}|Q3]")

      refute html =~ "<b>hi</b>"
      assert html =~ "&lt;b&gt;"
    end
  end

  describe "the three states" do
    test "an unresolvable type shows the author's words, unlinked" do
      html = render_text("see #[nonesuch:#{@uuid}|Some Thing]")

      assert html =~ "Some Thing"
      refute html =~ "<a"
    end

    test "text with no mentions renders unchanged" do
      assert render_text("just words") =~ "just words"
    end

    test "nil text is not a crash" do
      assert is_binary(render_text(nil))
    end
  end

  describe "a mention the reader can't open" do
    test "shows what it is called, with a lock and no link" do
      # `post` is registered but declares no visibility check, so it
      # resolves as forbidden for everyone.
      html = render_text("blocked on #[post:#{@uuid}|Q3 Launch]")

      assert html =~ "Q3 Launch", "the sentence has to read as the thing it names"
      assert html =~ "hero-lock-closed"
      refute html =~ "<a", "knowing its name is not the same as being let in"
    end

    test "clicking it asks for access" do
      html = render_text("blocked on #[post:#{@uuid}|Q3 Launch]")

      assert html =~ "pk_request_access"
      assert html =~ @uuid
    end

    test "with requests turned off it is inert but still readable" do
      html = render_text("blocked on #[post:#{@uuid}|Q3 Launch]", allow_request: false)

      assert html =~ "Q3 Launch"
      assert html =~ "hero-lock-closed"
      refute html =~ "pk_request_access"
    end
  end

  describe "a person" do
    test "a readable @ mention is a chip with their face and name" do
      {:ok, user} =
        Auth.register_user(%{
          email: "chip_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, user} =
        Auth.update_user_profile(user, %{
          "first_name" => "Anna",
          "last_name" => "Kask"
        })

      # users are a public mention type: any signed-in reader resolves one
      scope = Scope.for_user(user)

      html = render_text("thanks @[user:#{user.uuid}|Anna]", scope: scope)

      assert html =~ ~s(data-mention-user="#{user.uuid}")
      assert html =~ "Anna Kask"
      # the avatar's letters come from the name shown
      assert html =~ ~r/>\s*AK\s*</
    end

    test "a person who no longer exists stays the plain label" do
      html = render_text("thanks @[user:#{@uuid}|Gone Person]")
      refute html =~ "data-mention-user"
      assert html =~ "Gone Person"
    end
  end
end
