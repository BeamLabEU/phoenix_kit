defmodule PhoenixKitWeb.Components.UserAvatarInitialsTest do
  @moduledoc """
  An avatar without a picture shows two letters from the name the page
  shows beside it, never the email's first letter (the boss, 2026-11-18:
  "it wasn't taking the letter from the visible name but from their email").
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitWeb.Components.Core.UserInfo

  doctest UserInfo, only: [initials: 1]

  # An avatar whose sources all miss: no upload, no OAuth picture, and
  # Gravatar answers with a picture URL, so look at the fallback span.
  defp letters(attrs) do
    html = render_component(&UserInfo.user_avatar/1, attrs)

    case Regex.run(~r/data-fallback="true"[^>]*>\s*([^<]*?)\s*</, html) ||
           Regex.run(~r/<span>\s*([^<]*?)\s*<\/span>/, html) do
      [_, text] -> text
      _ -> flunk("no letters in #{html}")
    end
  end

  test "two letters from first and last name, not the email" do
    user = %User{
      email: "zed@example.com",
      first_name: "Anna",
      last_name: "Kask",
      custom_fields: %{}
    }

    assert letters(user: user) == "AK"
  end

  test "the shown name wins over the account's own" do
    user = %User{
      email: "zed@example.com",
      first_name: "Anna",
      last_name: "Kask",
      custom_fields: %{}
    }

    assert letters(user: user, name: "Bob Builder") == "BB"
  end

  test "an account with no name falls back to the email's local part" do
    assert letters(user: %User{email: "anna.kask@example.com", custom_fields: %{}}) == "AK"
    assert letters(user: %User{email: "max@example.com", custom_fields: %{}}) == "M"
  end

  test "initials of unusual names" do
    assert UserInfo.initials("Anna-Liisa Kask") == "AK"
    assert UserInfo.initials("  ") == ""
    assert UserInfo.initials(nil) == ""
    assert UserInfo.initials("ömer çelik") == "ÖÇ"
    assert UserInfo.initials("(Max) Don") == "MD"
  end
end
