defmodule PhoenixKitWeb.Live.Settings.EmailSendingTest do
  @moduledoc """
  Smoke tests for the core Emails Transactional settings page
  (`/admin/settings/email-sending`) — sender identity, the transport
  panel, the default send integration picker, and the test-send action.

  Auth + sandbox plumbing comes from `PhoenixKitWeb.ConnCase`.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.WelcomeEmail
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/email-sending")

  defp setup_admin(%{conn: conn}) do
    {user, _token} = create_admin_user()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  defp seed_smtp(name) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("smtp", name)

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "host" => "smtp.example.com",
        "port" => "587",
        "username" => "user",
        "password" => "pw"
      })

    uuid
  end

  describe "rendering" do
    setup :setup_admin

    test "renders the page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "Emails Transactional"
    end

    test "shows the built-in mailer when no parent app mailer is configured",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "built-in PhoenixKit mailer"
    end

    test "shows the empty state when no email-capable integrations are connected",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "No email-capable integrations connected yet."
    end

    test "lists a connected email-capable integration in the transport panel",
         %{conn: conn} do
      seed_smtp("primary relay")

      {:ok, _view, html} = live(conn, @path)
      assert html =~ "primary relay"
    end

    test "the default integration picker offers connected email-capable integrations",
         %{conn: conn} do
      uuid = seed_smtp("primary relay")

      {:ok, _view, html} = live(conn, @path)
      assert html =~ ~s(value="#{uuid}")
    end

    test "links to the Emails Bulk page", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "/admin/settings/emails-bulk"
    end
  end

  describe "sender identity" do
    setup :setup_admin

    test "shows the built-in default as a placeholder when unset", %{conn: conn} do
      {:ok, _view, html} = live(conn, @path)
      assert html =~ "PhoenixKit"
      assert html =~ "noreply@localhost"
    end

    test "saving sender identity persists to Settings and updates the effective value",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-submit=\"save_sender_identity\"]")
        |> render_submit(%{"from_name" => "Acme Support", "from_email" => "support@acme.com"})

      assert html =~ "Sender identity updated"
      assert html =~ "Acme Support"
      assert html =~ "support@acme.com"

      assert Settings.get_setting("from_name") == "Acme Support"
      assert Settings.get_setting("from_email") == "support@acme.com"
    end

    test "clearing sender identity fields falls back to the built-in default again",
         %{conn: conn} do
      {:ok, _} = Settings.update_setting("from_name", "Acme Support")
      {:ok, _} = Settings.update_setting("from_email", "support@acme.com")

      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-submit=\"save_sender_identity\"]")
        |> render_submit(%{"from_name" => "", "from_email" => ""})

      assert html =~ "Sender identity updated"
      assert Settings.get_setting("from_name") == ""
      assert Settings.get_setting("from_email") == ""
    end
  end

  describe "default send integration" do
    setup :setup_admin

    test "selecting a connected integration persists the setting", %{conn: conn} do
      uuid = seed_smtp("primary relay")

      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-change=\"select_default_integration\"]")
        |> render_change(%{"integration_uuid" => uuid})

      assert html =~ "Default send integration updated"
      assert Settings.get_setting("default_email_integration_uuid") == uuid
    end

    test "clearing the selection back to \"None\" persists an empty setting",
         %{conn: conn} do
      uuid = seed_smtp("primary relay")
      {:ok, _} = Settings.update_setting("default_email_integration_uuid", uuid)

      {:ok, view, _html} = live(conn, @path)

      view
      |> element("form[phx-change=\"select_default_integration\"]")
      |> render_change(%{"integration_uuid" => ""})

      assert Settings.get_setting("default_email_integration_uuid") == ""
    end
  end

  describe "test send" do
    setup :setup_admin

    test "sending to a valid recipient shows a success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-submit=\"send_test_email\"]")
        |> render_submit(%{"recipient" => "ops@example.com"})

      assert html =~ "Test email sent to ops@example.com"
    end

    test "a blank recipient surfaces a validation error instead of attempting to send",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-submit=\"send_test_email\"]")
        |> render_submit(%{"recipient" => "  "})

      assert html =~ "Enter a recipient email address"
    end

    test "a default integration with a since-blanked required field shows a safe, readable flash (security)",
         %{conn: conn} do
      # Same exploit chain as PhoenixKit.MailerTest's
      # deliver_via_integration/3 test: a "connected" status is sticky, so
      # blanking a required field afterward does not un-connect the
      # integration. This proves the resulting flash names only the
      # missing field, never the still-present secret.
      {:ok, %{uuid: uuid}} = Integrations.add_connection("smtp", "flaky relay")
      secret = "very-real-password-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "host" => "smtp.example.com",
          "port" => "587",
          "username" => "user",
          "password" => secret
        })

      :ok = Integrations.record_validation(uuid, :ok)
      {:ok, _} = Settings.update_setting("default_email_integration_uuid", uuid)

      # Blank the host after the fact — status stays "connected".
      {:ok, _} = Integrations.save_setup(uuid, %{"host" => ""})
      assert Integrations.connected?(uuid)

      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-submit=\"send_test_email\"]")
        |> render_submit(%{"recipient" => "ops@example.com"})

      assert html =~ "missing required field(s): host"
      refute html =~ secret
    end
  end

  describe "branding" do
    setup :setup_admin

    test "shows the accent colour form, the swatch and the links", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#email-branding-panel #email-accent-color-form")
      assert has_element?(view, ~s(#email-accent-color-swatch[style*="#18181b"]))
      assert has_element?(view, ~s(#email-logo-settings-link[href$="/admin/settings"]))

      assert has_element?(
               view,
               ~s(#email-preview-link[href$="/admin/settings/email-sending/preview"])
             )

      assert has_element?(view, "#email-logo-none")
    end

    test "saving a colour stores it lower-cased and paints the swatch", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("#email-accent-color-form")
        |> render_submit(%{"accent_color" => " #1D4ED8 "})

      assert html =~ "Email accent colour updated"
      assert Settings.get_setting("email_accent_color") == "#1d4ed8"
      assert Branding.accent_color() == "#1d4ed8"
      assert has_element?(view, ~s(#email-accent-color-swatch[style*="#1d4ed8"]))
      assert has_element?(view, ~s(#email-accent-color-input[value="#1d4ed8"]))
    end

    test "an invalid colour is refused and nothing is saved", %{conn: conn} do
      {:ok, _} = Settings.update_setting("email_accent_color", "#123456")
      {:ok, view, _html} = live(conn, @path)

      for bad <- ["red", "#abc", "#1234567", "#12345g", "#123456;background:url(x)"] do
        html =
          view
          |> element("#email-accent-color-form")
          |> render_submit(%{"accent_color" => bad})

        assert html =~ "Enter the colour as #RRGGBB"
        assert has_element?(view, "#email-accent-color-error")
        assert Settings.get_setting("email_accent_color") == "#123456"
        # the swatch keeps the saved colour, never the bad value
        assert has_element?(view, ~s(#email-accent-color-swatch[style*="#123456"]))
      end
    end

    test "a blank colour resets to the default", %{conn: conn} do
      {:ok, _} = Settings.update_setting("email_accent_color", "#123456")
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("#email-accent-color-form")
        |> render_submit(%{"accent_color" => "  "})

      assert html =~ "reset to the default"
      assert Settings.get_setting("email_accent_color") in [nil, ""]
      assert Branding.accent_color() == "#18181b"
    end

    test "on a site that never saved a colour, saving the blank field works", %{conn: conn} do
      assert Settings.get_setting("email_accent_color") in [nil, ""]
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#email-accent-color-save")

      html =
        view
        |> element("#email-accent-color-form")
        |> render_submit(%{"accent_color" => ""})

      assert html =~ "reset to the default"
      refute html =~ "Could not save the accent colour"
    end

    test "an invalid colour marks the field invalid; a valid one clears it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view |> element("#email-accent-color-form") |> render_submit(%{"accent_color" => "red"})
      assert has_element?(view, ~s(#email-accent-color-input[aria-invalid="true"]))

      view
      |> element("#email-accent-color-form")
      |> render_submit(%{"accent_color" => "#1d4ed8"})

      refute has_element?(view, "#email-accent-color-input[aria-invalid]")
    end

    test "a half-typed colour is not an error yet; one that cannot become one is",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      for partial <- ["#", "#1d4", "1d4ed"] do
        view |> element("#email-accent-color-form") |> render_change(%{"accent_color" => partial})
        refute has_element?(view, "#email-accent-color-error"), partial
      end

      for bad <- ["#zz", "#1d4ed8x", "blue"] do
        view |> element("#email-accent-color-form") |> render_change(%{"accent_color" => bad})
        assert has_element?(view, "#email-accent-color-error"), bad
      end
    end

    test "typing updates the swatch live; the colour picker wins when it changed",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#email-accent-color-form")
      |> render_change(%{"accent_color" => "#ff0000", "accent_color_picker" => "#18181b"})

      assert has_element?(view, ~s(#email-accent-color-swatch[style*="#ff0000"]))
      refute has_element?(view, "#email-accent-color-error")

      view
      |> element("#email-accent-color-form")
      |> render_change(%{
        "_target" => ["accent_color_picker"],
        "accent_color" => "#ff0000",
        "accent_color_picker" => "#00ff00"
      })

      assert has_element?(view, ~s(#email-accent-color-input[value="#00ff00"]))
      assert has_element?(view, ~s(#email-accent-color-swatch[style*="#00ff00"]))

      view
      |> element("#email-accent-color-form")
      |> render_change(%{"accent_color" => "nope"})

      assert has_element?(view, "#email-accent-color-error")
      assert Settings.get_setting("email_accent_color") in [nil, ""]
    end
  end

  describe "welcome email" do
    setup :setup_admin

    test "is off by default, next to branding, with a preview link", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#email-branding-panel #email-welcome-form")
      refute has_element?(view, "#email_welcome_enabled[checked]")

      assert has_element?(
               view,
               ~s(#email-welcome-preview-link[href$="/admin/settings/email-sending/preview?email=welcome"])
             )
    end

    test "the checkbox switches it on and off", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view |> form("#email-welcome-form", %{"enabled" => "true"}) |> render_change()
      assert Settings.get_setting("email_welcome_enabled") == "true"
      assert WelcomeEmail.enabled?()
      assert has_element?(view, "#email_welcome_enabled[checked]")

      view |> form("#email-welcome-form", %{"enabled" => "false"}) |> render_change()
      assert Settings.get_setting("email_welcome_enabled") == "false"
      refute WelcomeEmail.enabled?()
    end
  end
end
