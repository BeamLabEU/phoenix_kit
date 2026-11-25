defmodule PhoenixKit.Users.Auth.UsernameFromEmailTest do
  # Pure — `generate_username_from_email/1` only transforms the string. The
  # uniqueness pass that follows it in `registration_changeset/3` is what needs
  # a database, and that is covered by `user_org_changeset_test.exs`.
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.User

  describe "generate_username_from_email/1" do
    test "keeps a plain ASCII local part, with dots as underscores" do
      assert User.generate_username_from_email("john.smith@example.com") == "john_smith"
    end

    test "folds accents instead of deleting the letters under them" do
      # `clean_username/1` strips anything outside [a-zA-Z0-9_], so without the
      # transliteration pass this returned "lo_kask" — the first letter of the
      # name silently gone.
      assert User.generate_username_from_email("Ülo.Kask@example.com") == "ulo_kask"
      assert User.generate_username_from_email("josé@example.com") == "jose"
    end

    test "transliterates a Cyrillic local part rather than collapsing it" do
      assert User.generate_username_from_email("Иван@example.com") == "ivan"
    end

    test "still prefixes a local part that does not start with a letter" do
      assert User.generate_username_from_email("123abc@example.com") == "user_123abc"
    end

    test "adds the domain's name to a local part shorter than the minimum length" do
      assert User.generate_username_from_email("jo@example.com") == "jo_example"
      assert User.generate_username_from_email("jo@mail.acme.co.uk") == "jo_acme"
      # No domain to borrow from: still a valid name.
      assert User.generate_username_from_email("jo") == "user_jo"
    end

    test "adds the domain's name to a shared mailbox" do
      assert User.generate_username_from_email("info@acme.com") == "info_acme"
      assert User.generate_username_from_email("sales@wood-matrix.co.uk") == "sales_wood_matrix"
    end

    test "drops a plus tag" do
      assert User.generate_username_from_email("john.doe+shop@example.com") == "john_doe"
    end

    test "turns punctuation into single underscores, none at the ends" do
      assert User.generate_username_from_email("first-last@example.com") == "first_last"
      assert User.generate_username_from_email("a__b..c@example.com") == "a_b_c"
      assert User.generate_username_from_email("_maria_@example.com") == "maria"
    end

    test "falls back to the domain, then to a plain name, when nothing can be romanized" do
      assert User.generate_username_from_email("日本@acme.jp") == "acme"
      assert User.generate_username_from_email("日本") == "user"
    end

    test "cuts a long local part at a word boundary" do
      assert User.generate_username_from_email("firstname.middlename.lastname.extra@example.com") ==
               "firstname_middlename_lastname"

      long = String.duplicate("a", 40)

      assert User.generate_username_from_email(long <> "@example.com") ==
               String.duplicate("a", 30)
    end

    test "every result is a name the form accepts" do
      for email <- ["f", "", "@", "1@2.3", "info@", "+tag@example.com", "a.@example.com"] do
        name = User.generate_username_from_email(email)
        assert name =~ ~r/^[a-z][a-z0-9_]{2,29}$/, "#{inspect(email)} gave #{inspect(name)}"
      end
    end

    test "pad: false gives the name as far as the typed text gives it" do
      assert User.generate_username_from_email("f", pad: false) == "f"
      assert User.generate_username_from_email("fo", pad: false) == "fo"
      assert User.generate_username_from_email("fotkin", pad: false) == "fotkin"
      assert User.generate_username_from_email("", pad: false) == ""
    end

    test "returns nil for a non-binary" do
      assert User.generate_username_from_email(nil) == nil
    end
  end
end
