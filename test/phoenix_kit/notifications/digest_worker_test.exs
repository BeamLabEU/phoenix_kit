defmodule PhoenixKit.Notifications.DigestWorkerTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Notifications.DigestWorker
  alias PhoenixKit.Users.Auth.User

  defp user(locale) do
    %User{
      uuid: "00000000-0000-7000-8000-000000000001",
      custom_fields: if(locale, do: %{"preferred_locale" => locale}, else: %{})
    }
  end

  describe "digest_envelope/4" do
    test "renders the digest sentence in the recipient's locale" do
      # An Oban worker process starts on the default locale, so the catalogue
      # translations these strings carry only reach the recipient if the text
      # is built inside their locale — the envelope resolves it either way.
      envelope = DigestWorker.digest_envelope(user("ru"), "comments", 3, "daily")

      assert envelope.locale == "ru"
      assert envelope.text =~ "У вас"
      refute envelope.text =~ "You have"
    end

    test "a full dialect narrows to the base locale gettext knows" do
      envelope = DigestWorker.digest_envelope(user("ru-RU"), "comments", 1, "hourly")

      assert envelope.locale == "ru"
      assert envelope.content_locale == "ru-RU"
      refute envelope.text =~ "You have"
    end

    test "no preference falls back to the default locale, not a crash" do
      envelope = DigestWorker.digest_envelope(user(nil), "comments", 2, "weekly")

      assert envelope.locale == nil
      assert envelope.content_locale == "en"
      assert envelope.text =~ "You have"
    end

    test "the type's label is in the recipient's locale too" do
      envelope = DigestWorker.digest_envelope(user("et"), "security", 2, "daily")

      assert envelope.text =~ "turvalisus"
      refute envelope.text =~ "security"
    end

    test "the locale switch does not leak into the calling process" do
      before = Gettext.get_locale(PhoenixKitWeb.Gettext)
      DigestWorker.digest_envelope(user("ru"), "comments", 1, "daily")

      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == before
    end
  end
end
