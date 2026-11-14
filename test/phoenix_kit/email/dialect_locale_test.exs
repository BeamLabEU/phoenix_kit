defmodule PhoenixKit.Email.DialectLocaleTest do
  @moduledoc """
  A reader whose preference is a dialect ("es-ES") gets core's default copy in
  their language.

  Preferences are stored as dialects, but `PhoenixKitWeb.Gettext` keys its
  catalogues on base codes and looks a locale up exactly — installing "es-ES"
  as it was sent every default out in English.
  """

  use PhoenixKit.DataCase, async: false

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier

  defp user(locale) do
    %User{
      uuid: Ecto.UUID.generate(),
      email: "reader@example.test",
      # Confirmed: the alerts go only to a proven address.
      confirmed_at: ~U[2026-01-01 00:00:00Z],
      custom_fields: %{"preferred_locale" => locale}
    }
  end

  defp in_spanish(fun), do: Gettext.with_locale(PhoenixKitWeb.Gettext, "es", fun)

  test "a dialect preference reads the base language's subject and body" do
    subject = in_spanish(fn -> gettext("Confirm your account") end)
    refute subject == "Confirm your account"

    for dialect <- ["es-ES", "es-MX"] do
      assert {:ok, email} =
               UserNotifier.deliver_confirmation_instructions(user(dialect), "https://x.test/c")

      assert email.subject == subject
      refute email.text_body =~ "You can confirm your account"
    end
  end

  test "strings built for the reader are in their language, and links do not change" do
    attrs = %{ip_address: "203.0.113.24", first_seen_at: ~U[2026-09-30 12:00:00Z]}

    assert {:ok, dialect} = UserNotifier.deliver_new_login_alert(user("es-ES"), attrs)
    assert {:ok, base} = UserNotifier.deliver_new_login_alert(user("es"), attrs)

    # `location` is nil here, so the line reads "Unknown" — in Spanish.
    unknown = in_spanish(fn -> gettext("Unknown") end)
    refute unknown == "Unknown"
    assert dialect.text_body =~ unknown

    # Same copy, same security link: the URL locale segment was already the
    # base code, so only the translation changed.
    assert dialect.text_body == base.text_body
    assert dialect.subject == base.subject
  end
end
