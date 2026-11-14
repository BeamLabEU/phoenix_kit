defmodule PhoenixKit.Integration.Users.RegistrationSiteWideCapTest do
  @moduledoc """
  The site-wide sign-up cap (`registration_global_limit`): spent by the public
  doors only, and the Abuse protection tab of Settings → Authorization that
  shows it.
  """

  # Swaps the limiter's application env and reads one shared counter.
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"

  setup do
    previous = Application.get_env(:phoenix_kit, RateLimiter, [])
    on_exit(fn -> Application.put_env(:phoenix_kit, RateLimiter, previous) end)

    # Far above anything else in the run could add within the test, so the
    # assertions are about the difference, never the absolute count.
    Application.put_env(
      :phoenix_kit,
      RateLimiter,
      Keyword.put(previous, :registration_global_limit, 1_000_000)
    )

    :ok
  end

  defp used do
    Enum.find(RateLimiter.overview(), &(&1.action == :registration)).site_wide.used
  end

  defp unique_email, do: "cap_#{System.unique_integer([:positive])}@example.com"
  defp unique_ip, do: "10.77.#{:rand.uniform(250)}.#{:rand.uniform(250)}"

  describe "Auth.register_user/3" do
    test "a programmatic registration does not spend the cap" do
      before = used()

      assert {:ok, %User{}} = Auth.register_user(%{email: unique_email(), password: @password})

      assert {:ok, %User{}} =
               Auth.register_user(%{email: unique_email(), password: @password}, unique_ip())

      assert used() == before
    end

    test "site_wide: true spends one, through the geolocation variant too" do
      before = used()

      assert {:ok, %User{}} =
               Auth.register_user(
                 %{"email" => unique_email(), "password" => @password},
                 unique_ip(),
                 site_wide: true
               )

      assert used() == before + 1

      # No usable IP: the clause that registers without geolocation.
      assert {:ok, %User{}} =
               Auth.register_user_with_geolocation(
                 %{"email" => unique_email(), "password" => @password},
                 nil,
                 site_wide: true
               )

      assert used() == before + 2
    end

    test "a reached cap refuses the public form and nothing else" do
      previous = Application.get_env(:phoenix_kit, RateLimiter, [])

      # Whatever the counter holds this hour, the limit is already below it.
      Auth.register_user(%{email: unique_email(), password: @password}, unique_ip(),
        site_wide: true
      )

      Application.put_env(
        :phoenix_kit,
        RateLimiter,
        Keyword.put(previous, :registration_global_limit, 1)
      )

      email = unique_email()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Auth.register_user(%{email: email, password: @password}, unique_ip(),
                 site_wide: true
               )

      assert {"Too many registration attempts. Please try again later.", _} =
               changeset.errors[:email]

      refute Auth.get_user_by_email(email)

      assert {:ok, %User{}} = Auth.register_user(%{email: unique_email(), password: @password})
    end
  end

  describe "magic-link registration" do
    test "the request spends the cap; the completion spends nothing" do
      before = used()
      email = unique_email()
      ip = unique_ip()

      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(email, ip)
      assert used() == before + 1

      # The address bucket holds three an hour and the request took one. A
      # completion that charged it again refused the third try at the form.
      for _ <- 1..4 do
        assert {:error, %Ecto.Changeset{}} =
                 MagicLinkRegistration.complete_registration(token, %{"password" => "short"}, ip)
      end

      assert {:ok, %User{email: ^email}} =
               MagicLinkRegistration.complete_registration(token, %{"password" => @password}, ip)

      assert used() == before + 1
    end
  end

  describe "Settings → Authorization → Abuse protection" do
    setup %{conn: conn} do
      {user, _token} = create_admin_user()
      %{conn: log_in_user(conn, user)}
    end

    test "lists every endpoint with its limits and the site-wide use", %{conn: conn} do
      Auth.register_user(%{email: unique_email(), password: @password}, unique_ip(),
        site_wide: true
      )

      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization?tab=protection"))

      for action <- ~w(login registration magic_link password_reset confirmation_resend) do
        assert has_element?(view, "#request-limit-#{action}")
      end

      row = view |> element("#request-limit-registration") |> render()
      assert row =~ "3 per 1 h"
      assert row =~ "10 per 1 h"
      assert row =~ "1000000 per 1 h"
      assert row =~ "#{used()} of 1000000"

      # Sign-in sends nothing and has no site-wide cap.
      assert view |> element("#request-limit-login") |> render() =~ "No limit"
    end

    test "Refresh re-reads the counter", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization?tab=protection"))

      Auth.register_user(%{email: unique_email(), password: @password}, unique_ip(),
        site_wide: true
      )

      now = used()
      html = view |> element(~s(button[phx-click="refresh_request_limits"])) |> render_click()

      assert html =~ "#{now} of 1000000"
    end

    test "a reached cap is shown as reached", %{conn: conn} do
      previous = Application.get_env(:phoenix_kit, RateLimiter, [])

      Auth.register_user(%{email: unique_email(), password: @password}, unique_ip(),
        site_wide: true
      )

      Application.put_env(
        :phoenix_kit,
        RateLimiter,
        Keyword.put(previous, :registration_global_limit, 1)
      )

      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization?tab=protection"))

      assert view |> element("#request-limit-registration") |> render() =~ "Limit reached"
    end
  end
end
