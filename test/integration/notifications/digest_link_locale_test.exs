defmodule PhoenixKit.Integration.Notifications.DigestLinkLocaleTest do
  @moduledoc """
  A digest's button opens the inbox in the recipient's language: the worker
  runs in the default locale, and the link was built in it (zai, 2026-11-25).
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Notifications.DigestWorker
  alias PhoenixKit.Users.Auth.User

  test "the envelope's link is the recipient's language's inbox" do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("et")

    et = %User{
      uuid: "00000000-0000-7000-8000-000000000002",
      custom_fields: %{"preferred_locale" => "et"}
    }

    assert DigestWorker.digest_envelope(et, "comments", 1, "daily").url =~
             "/et/admin/notifications"
  end

  test "a recipient on a served sibling dialect gets that dialect's inbox" do
    {:ok, _} = Languages.enable_system()
    # en-US may already be there (the default language).
    _ = Languages.add_language("en-US")
    {:ok, _} = Languages.add_language("en-GB")

    gb = %User{
      uuid: "00000000-0000-7000-8000-000000000003",
      custom_fields: %{"preferred_locale" => "en-GB"}
    }

    assert DigestWorker.digest_envelope(gb, "comments", 1, "daily").url =~
             "/en-gb/admin/notifications"
  end
end
