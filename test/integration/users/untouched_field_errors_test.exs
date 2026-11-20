defmodule PhoenixKitWeb.Integration.Users.UntouchedFieldErrorsTest do
  @moduledoc """
  A form shows a field's errors once the person has touched it, never while they
  type in another one, and all of them on submit.

  LiveView's `phx-change` (and its form recovery after a reconnect) sends
  `_unused_<field>` next to every input the person has not typed in yet; a submit
  sends none. These pages each hold that rule in their own way: an allowlist of
  params, a form-level banner, or error helpers of their own.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @password "hello world password!"

  defp unique_email, do: "untouched_#{System.unique_integer([:positive])}@example.com"

  # "can't be blank", as rendered.
  @blank "can&#39;t be blank"

  describe "sign-up (/users/register)" do
    test "typing the email leaves the untouched password quiet", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/users/register"))

      html =
        render_change(view, "validate", %{
          "_target" => ["user", "email"],
          "user" => %{"email" => "a", "password" => "", "_unused_password" => ""}
        })

      assert html =~ "must have the @ sign"
      refute html =~ @blank
    end

    test "a save shows the errors, even if it carries a marker", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/users/register"))

      html =
        render_submit(view, "save", %{
          "user" => %{"email" => unique_email(), "password" => "", "_unused_password" => ""}
        })

      assert html =~ @blank
    end

    test "email and password are checked when the person leaves them", %{conn: conn} do
      {:ok, _view, html} = live(conn, Routes.path("/users/register"))

      assert debounce(html, "user[email]") == ["blur"]
      assert debounce(html, "user[password]") == ["blur"]
    end
  end

  describe "magic-link sign-up (/users/register/complete/:token)" do
    test "typing a username leaves the untouched password quiet", %{conn: conn} do
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(unique_email())
      {:ok, view, _html} = live(conn, Routes.path("/users/register/complete/#{token}"))

      html =
        render_change(view, "validate", %{
          "user" => %{"username" => "someone", "password" => "", "_unused_password" => ""}
        })

      refute html =~ @blank

      html = render_change(view, "validate", %{"user" => %{"username" => "x", "password" => ""}})
      assert html =~ @blank
    end

    test "a save shows the errors, even if it carries a marker", %{conn: conn} do
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(unique_email())
      {:ok, view, html} = live(conn, Routes.path("/users/register/complete/#{token}"))
      assert debounce(html, "user[password]") == ["blur"]

      html =
        render_submit(view, "save", %{"user" => %{"password" => "", "_unused_password" => ""}})

      assert html =~ @blank
    end
  end

  describe "reset password (/users/reset-password/:token)" do
    setup do
      {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})

      test_pid = self()

      {:ok, _} =
        Auth.deliver_user_reset_password_instructions(user, fn token ->
          send(test_pid, {:token, token})
          "http://localhost/#{token}"
        end)

      assert_receive {:token, token}
      %{token: token}
    end

    test "the form-level banner waits for a submit", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, Routes.path("/users/reset-password/#{token}"))

      html =
        render_change(view, "validate", %{
          "user" => %{
            "password" => "short",
            "password_confirmation" => "",
            "_unused_password_confirmation" => ""
          }
        })

      refute html =~ "Oops, something went wrong"
      assert html =~ "should be at least"

      html =
        render_submit(view, "reset_password", %{
          "user" => %{"password" => "short", "password_confirmation" => "other"}
        })

      assert html =~ "Oops, something went wrong"
    end

    test "the passwords are checked when the person leaves them", %{conn: conn, token: token} do
      {:ok, _view, html} = live(conn, Routes.path("/users/reset-password/#{token}"))

      assert debounce(html, "user[password]") == ["blur"]
      assert debounce(html, "user[password_confirmation]") == ["blur"]
    end
  end

  describe "profile custom fields (/profile/settings)" do
    test "the refusal of an untouched field waits; a touched one shows", %{conn: conn} do
      mail = "untouched_mail_#{System.unique_integer([:positive])}"

      {:ok, _} =
        CustomFields.add_field_definition(%{
          "key" => mail,
          "label" => "Label #{mail}",
          "type" => "email",
          "enabled" => true,
          "user_accessible" => true,
          "position" => 1
        })

      {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
      {:ok, user} = Auth.admin_confirm_user(user)
      {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/profile/settings"))

      typed = fn fields ->
        view
        |> element("#profile-user-settings-account-custom-fields-form")
        |> render_change(%{"profile_form" => %{"user" => %{"custom_fields" => fields}}})
      end

      refute typed.(%{mail => "nope", "_unused_#{mail}" => ""}) =~ "Label #{mail}:"
      assert typed.(%{mail => "nope"}) =~ "Label #{mail}:"
    end
  end

  describe "storage forms (own error helpers)" do
    setup %{conn: conn} do
      original = Application.get_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-untouched-errors")

      on_exit(fn ->
        if original,
          do: Application.put_env(:phoenix_kit, :secret_key_base, original),
          else: Application.delete_env(:phoenix_kit, :secret_key_base)
      end)

      {user, _token} = create_admin_user()
      admin_role = Roles.get_role_by_name("Admin")
      {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")
      %{conn: log_in_user(conn, user)}
    end

    test "a new bucket's untouched name is not marked while another field is typed in",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media/buckets/new"))

      html =
        render_change(view, "validate", %{
          "bucket" => %{"provider" => "local", "name" => "", "_unused_name" => ""}
        })

      refute name_marked?(html, "bucket[name]")

      html =
        render_change(view, "validate", %{"bucket" => %{"provider" => "local", "name" => ""}})

      assert name_marked?(html, "bucket[name]")
    end

    test "a new rendition's untouched name shows no error while another field is typed in",
         %{conn: conn} do
      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/media/renditions/new/image"))

      html =
        render_change(view, "validate", %{
          "dimension" => %{"width" => "300", "name" => "", "_unused_name" => ""}
        })

      refute name_marked?(html, "dimension[name]")
      refute html =~ @blank

      html = render_change(view, "validate", %{"dimension" => %{"width" => "300", "name" => ""}})
      assert name_marked?(html, "dimension[name]")
    end
  end

  # The `phx-debounce` of the input called `name`.
  defp debounce(html, name) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(input[name="#{name}"]))
    |> LazyHTML.attribute("phx-debounce")
  end

  # Whether the input of `name` carries the error style.
  defp name_marked?(html, name) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(input[name="#{name}"]))
    |> LazyHTML.attribute("class")
    |> Enum.any?(&String.contains?(&1, "input-error"))
  end
end
