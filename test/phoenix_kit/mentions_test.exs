defmodule PhoenixKit.MentionsTest do
  @moduledoc """
  The token grammar and the index/notify lifecycle.

  The grammar tests are the load-bearing ones: the format is what every
  other half depends on, and getting it wrong silently turns prose into
  links or links into prose.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Users.Auth

  @uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"
  @other "018e3c4a-9f6b-7890-abcd-ef1234567891"

  describe "Token.parse/1" do
    test "finds both kinds and keeps their labels" do
      text = "Hi @[user:#{@uuid}|Alice Smith], see #[project:#{@other}|Q3 Launch]"

      assert [user, project] = Token.parse(text)
      assert user.kind == :user
      assert user.type == "user"
      assert user.label == "Alice Smith"
      assert project.kind == :resource
      assert project.type == "project"
      assert project.label == "Q3 Launch"
    end

    test "bare @name and #tag are prose, not mentions" do
      # Publishing's hashtags share the trigger character; only the closed
      # form is a mention, which is what keeps the two from colliding.
      assert Token.parse("ping @alice about #launch and email a@b.com") == []
    end

    test "a backslash escapes a complete token" do
      assert Token.parse("literally \\@[user:#{@uuid}|Alice]") == []
    end

    test "an incomplete token stays text" do
      # Mid-typing, or a truncated paste. Neither should become a link.
      assert Token.parse("@[user:#{@uuid}|Alice") == []
      assert Token.parse("@[user:not-a-uuid|Alice]") == []
      assert Token.parse("@[user:#{@uuid}|]") == []
    end

    test "nil and non-binaries yield nothing rather than raising" do
      assert Token.parse(nil) == []
      assert Token.parse(123) == []
    end
  end

  describe "Token.to_string/4" do
    test "builds the canonical form" do
      assert {:ok, token} = Token.to_string(:resource, "project", @uuid, "Q3 Launch")
      assert token == "#[project:#{@uuid}|Q3 Launch]"
      assert [parsed] = Token.parse(token)
      assert parsed.uuid == @uuid
    end

    test "refuses a label that would break the grammar" do
      # The picker is the only thing that builds tokens, so it can simply
      # not produce these rather than the format carrying escape rules.
      assert Token.to_string(:user, "user", @uuid, "bad|label") == :error
      assert Token.to_string(:user, "user", @uuid, "bad]label") == :error
      assert Token.to_string(:user, "user", @uuid, "   ") == :error
    end

    test "refuses a bad uuid or type" do
      assert Token.to_string(:user, "user", "nope", "Alice") == :error
      assert Token.to_string(:user, "Bad Type", @uuid, "Alice") == :error
    end
  end

  describe "a label of multi-byte letters" do
    # The parser counted bytes while the builder cut characters: a picked
    # name of 61 two-byte letters was built and then not recognised.
    test "is built and parsed alike up to the limit, and cut there" do
      for n <- [60, 61, 120, 150] do
        label = String.duplicate("Õ", n)
        assert {:ok, token} = Token.to_string(:user, "user", @uuid, label)
        assert [%Token{label: parsed}] = Token.parse(token)
        assert String.length(parsed) == min(n, Token.max_label_length())
        assert [%Token{}] = Enum.filter(Token.split("x " <> token), &is_struct/1)
      end
    end

    test "text that is not valid UTF-8 is still read, never raises" do
      text = <<255>> <> " @[user:#{@uuid}|Ada]"
      assert [%Token{label: "Ada"}] = Token.parse(text)
    end
  end

  describe "Token.split/1" do
    test "keeps the surrounding text in order" do
      text = "a @[user:#{@uuid}|Alice] b"
      assert [before, %Token{} = token, rest] = Token.split(text)
      assert before == "a "
      assert token.label == "Alice"
      assert rest == " b"
    end

    test "an escaped token comes back as text with the backslash gone" do
      assert ["@[user:#{@uuid}|Alice]"] == Token.split("\\@[user:#{@uuid}|Alice]")
    end
  end

  describe "Token.to_plain_text/1" do
    test "reduces mentions to readable words" do
      text = "Hi @[user:#{@uuid}|Alice], see #[project:#{@other}|Q3 Launch]"
      assert Token.to_plain_text(text) == "Hi @Alice, see Q3 Launch"
    end
  end

  describe "sync/4" do
    setup do
      {:ok, source: Ecto.UUID.generate()}
    end

    test "indexes what the text mentions", %{source: source} do
      text = "see #[project:#{@uuid}|Q3] and #[project:#{@other}|Q4]"

      assert {:ok, new} = Mentions.sync("comment", source, text)
      assert length(new) == 2
      assert length(Mentions.list_for_source("comment", source)) == 2
    end

    test "re-saving the same text reports nothing new", %{source: source} do
      text = "see #[project:#{@uuid}|Q3]"

      assert {:ok, [_]} = Mentions.sync("comment", source, text)
      assert {:ok, []} = Mentions.sync("comment", source, text)
    end

    test "removing a mention removes its row", %{source: source} do
      assert {:ok, [_]} = Mentions.sync("comment", source, "#[project:#{@uuid}|Q3]")
      assert {:ok, []} = Mentions.sync("comment", source, "nothing here now")
      assert Mentions.list_for_source("comment", source) == []
    end

    test "the same target twice in one field is one mention", %{source: source} do
      text = "#[project:#{@uuid}|Q3] and again #[project:#{@uuid}|Q3]"

      assert {:ok, [_only_one]} = Mentions.sync("comment", source, text)
    end

    test "fields are independent", %{source: source} do
      # A record with a description AND a summary must not have one field's
      # save wipe the other's mentions.
      assert {:ok, [_]} =
               Mentions.sync("task", source, "#[project:#{@uuid}|Q3]", field: "description")

      assert {:ok, [_]} =
               Mentions.sync("task", source, "#[project:#{@other}|Q4]", field: "summary")

      assert length(Mentions.list_for_source("task", source, "description")) == 1
      assert length(Mentions.list_for_source("task", source, "summary")) == 1
    end

    test "backlinks find the source", %{source: source} do
      assert {:ok, _} = Mentions.sync("comment", source, "#[project:#{@uuid}|Q3]")

      assert [backlink] = Mentions.list_backlinks("project", @uuid)
      assert backlink.source_uuid == source
      assert backlink.label == "Q3"
    end

    test "empty text is not an error", %{source: source} do
      assert {:ok, []} = Mentions.sync("comment", source, nil)
      assert {:ok, []} = Mentions.sync("comment", source, "")
    end
  end

  describe "context/2" do
    test "an unresolvable type is missing, not forbidden" do
      # No handler for "nonesuch": nothing can resolve it, but nothing is
      # hiding it either — the reader should get the author's words.
      text = "see #[nonesuch:#{@uuid}|Some Thing]"

      assert %{{"nonesuch", @uuid} => %{state: :missing}} = Mentions.context(text)
    end

    test "text without mentions costs nothing" do
      assert Mentions.context("just words") == %{}
      assert Mentions.context(nil) == %{}
    end
  end

  describe "visible/3 fails closed" do
    # A token can be typed by hand into any textarea, so a type whose
    # module declares no visibility check must not render live. Most
    # registered types (posts, files, CRM contacts, integrations) declare
    # none, and treating that silence as consent showed their titles and
    # working links to any reader handed a uuid.

    test "a registered type with no visibility check is not openable" do
      # `post` is registered by core and implements no check.
      assert Mentions.visible("post", [@uuid], []) == []

      assert %{{"post", @uuid} => %{state: :forbidden}} =
               Mentions.context("see #[post:#{@uuid}|Some Post]")
    end

    test "a forbidden mention still carries a title to render" do
      # The reader learns what it is called and that it isn't theirs — the
      # sentence has to read as the thing it names. What they don't get is
      # a link.
      ctx = Mentions.context("see #[post:#{@uuid}|Some Post]")
      info = Map.fetch!(ctx, {"post", @uuid})

      assert info.state == :forbidden
      assert info.title == "Some Post"
      refute Map.has_key?(info, :path)
    end

    test "people stay visible — a name is not a secret here" do
      # The @ typeahead already lists every pingable account to anyone in
      # the admin area, so gating mentions of them protects nothing and
      # would break every ping.
      assert Mentions.visible("user", [@uuid], []) == [@uuid]
    end

    test "a type nobody registered renders as the author's words" do
      # Nothing can resolve it, so there is no title to leak; the reader
      # should get the sentence, not a lock icon.
      assert Mentions.visible("nonesuch", [@uuid], []) == [@uuid]

      assert %{{"nonesuch", @uuid} => %{state: :missing}} =
               Mentions.context("see #[nonesuch:#{@uuid}|Some Thing]")
    end
  end

  describe "a crafted record title cannot forge a second mention" do
    test "a title carrying token syntax is neutralised, not concatenated" do
      # The attack: name a record `x] @[user:<ceo>|see this`. If the client
      # concatenated that into grammar, picking it from the typeahead would
      # insert TWO valid tokens and ping the CEO as the victim, with the
      # tail invisible once rendered. The token is built server-side and
      # the grammar refuses those characters in a label.
      ceo = "018e3c4a-9f6b-7890-abcd-ef1234567899"
      hostile = "x] @[user:#{ceo}|see this"

      assert Token.to_string(:resource, "project", @uuid, hostile) == :error

      # And the sanitising fallback the picker uses keeps it to one token.
      cleaned = String.replace(hostile, ["|", "]"], " ")
      assert {:ok, token} = Token.to_string(:resource, "project", @uuid, cleaned)

      assert [only_one] = Token.parse(token)
      assert only_one.type == "project"
      assert only_one.uuid == @uuid
      refute Enum.any?(Token.parse(token), &(&1.uuid == ceo))
    end

    test "a crafted record NAME cannot become a link of its own in markdown" do
      # The other half of the same attack, on the value the grammar does not
      # cover. `to_markdown/2` splices the LIVE resolved title into
      # `[text](url)`, and that title is the record's current name — read
      # from the module that owns it, not from the token. The label can't
      # carry `]`; a name can. One rename then turns every markdown-rendered
      # mention of that record, for every reader, into a link to wherever
      # the name says.
      #
      # A user is the record here because "user" is the one type core both
      # registers and treats as visible to everyone, so this reaches the
      # `:ok` branch — the only one that emits a link — without standing up
      # a fake handler.
      {:ok, user} =
        Auth.register_user(%{
          email: "md_escape_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, user} =
        Auth.update_user_profile(user, %{"first_name" => "Evil](https://evil.example)"})

      markdown = Mentions.to_markdown("hi @[user:#{user.uuid}|Evil]")

      # The `]` that would close the link text early has to arrive escaped.
      refute Regex.match?(~r/(?<!\\)\]\(https:\/\/evil\.example\)/, markdown)
      assert markdown =~ "\\](https://evil.example)"

      # And the real destination is still the real destination.
      assert markdown =~ "/admin/users/view/#{user.uuid}"
    end
  end
end
