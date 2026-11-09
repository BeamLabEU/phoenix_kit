defmodule PhoenixKit.Integration.I18n.ChromeTranslationsTest do
  @moduledoc """
  What a signed-in person sees around every admin page comes out in the page's
  language: the account menu, the notifications bell, the sentences of common
  notifications, validation messages, pagination and dates. And the language
  menus list each language under its own name.

  `async: false`: languages and the module registry are global.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Notifications.{Notification, Render, Types}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.{AdminNav, UserDashboardNav}
  alias PhoenixKitWeb.Components.Core.{Input, Pagination}
  alias PhoenixKitWeb.Live.NotificationsBell

  @moduletag :capture_log

  setup do
    previous = Gettext.get_locale(PhoenixKitWeb.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, previous) end)
    :ok
  end

  defp two_languages! do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")
    :ok
  end

  defp account(email, opts) do
    %{
      email: email,
      role: "User",
      ref: Ecto.UUID.generate(),
      active?: Keyword.get(opts, :active?, false),
      root?: Keyword.get(opts, :root?, false)
    }
  end

  describe "the account menus" do
    setup do
      two_languages!()
      {user, _token} = create_admin_user()
      %{scope: Scope.for_user(user), user: user}
    end

    test "the admin menu is in the page's language", %{scope: scope, user: user} do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "de")

      assigns = %{
        scope: scope,
        accounts: [account(user.email, active?: true, root?: true), account("b@example.com", [])]
      }

      html =
        rendered_to_string(~H"""
        <AdminNav.admin_user_dropdown
          scope={@scope}
          current_path="/admin"
          current_locale="de-DE"
          accounts={@accounts}
          multi_session_allowed?={true}
        />
        """)

      for german <- ["Einstellungen", "Abmelden", "Sprache", "Konten", "Konto hinzufügen"] do
        assert html =~ german
      end

      for english <- [">Settings<", ">Log out<", ">Language<", ">Accounts<", ">Add account<"] do
        refute html =~ english
      end
    end

    test "both menus name each language in that language", %{scope: scope} do
      assigns = %{scope: scope}

      admin =
        rendered_to_string(~H"""
        <AdminNav.admin_user_dropdown scope={@scope} current_path="/admin" current_locale="en-US" />
        """)

      user =
        rendered_to_string(~H"""
        <UserDashboardNav.user_dropdown scope={@scope} current_path="/" current_locale="en-US" />
        """)

      for html <- [admin, user] do
        assert html =~ ~r/<span lang="de"[^>]*>Deutsch<\/span>/
        refute html =~ ">German<"
      end
    end
  end

  describe "the notifications bell" do
    setup do
      {user, _token} = create_admin_user()
      %{user: user}
    end

    test "renders in the language the layout hands it, though its own process has none",
         %{conn: conn, user: user} do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")

      {:ok, _view, html} =
        live_isolated(conn, NotificationsBell,
          session: %{"user_uuid" => user.uuid, "locale" => "de", "dialect" => "de-DE"}
        )

      assert html =~ "Benachrichtigungen"
      refute html =~ ">Notifications<"
    end

    test "has the language in its id, so a language switch mounts a new one",
         %{conn: conn, user: user} do
      two_languages!()
      PhoenixKit.Settings.update_boolean_setting("notifications_enabled", true)

      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/admin", locale: "de"))

      assert html =~ ~s(id="pk-notifications-bell-de")
    end
  end

  describe "notification sentences" do
    defp notification(action, metadata \\ %{}) do
      %Notification{activity: %Entry{action: action, metadata: metadata}}
    end

    test "switching accounts and an account made by an administrator read as sentences" do
      assert Render.render(notification("session.switched")).text ==
               "You switched to this account from another signed-in account."

      assert Render.render(notification("user.created")).text ==
               "An administrator created your account."
    end

    test "updated roles are listed by name, without quotes" do
      %{text: text} =
        Render.render(notification("user.roles_updated", %{"roles_added" => ["User"]}))

      assert text == "Your roles were updated (added: User)."
    end
  end

  describe "notification types of disabled modules" do
    defmodule DisabledModule do
      @moduledoc false
      def enabled?, do: false

      def notification_types,
        do: [%{key: "pk_test_disabled", label: "Disabled thing", actions: ["pk_test.thing"]}]
    end

    setup do
      key = {PhoenixKit, :registered_modules}
      before = :persistent_term.get(key, :none)
      :persistent_term.put(key, [DisabledModule | if(before == :none, do: [], else: before)])

      on_exit(fn ->
        if before == :none,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, before)
      end)
    end

    test "are not shown, but still own their actions and preference keys" do
      refute Enum.any?(Types.shown(), &(&1.key == "pk_test_disabled"))
      assert Enum.any?(Types.list(), &(&1.key == "pk_test_disabled"))
      assert "pk_test_disabled" in Types.all_pref_keys()
    end
  end

  test "custom validation messages are translated" do
    Gettext.put_locale(PhoenixKitWeb.Gettext, "de")

    for message <- [
          "must have the @ sign and no spaces",
          "must contain at least one uppercase character",
          "does not match password"
        ] do
      refute Input.translate_error({message, []}) == message
    end
  end

  test "pagination's Prev and Next are translated in every variant" do
    Gettext.put_locale(PhoenixKitWeb.Gettext, "de")
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Pagination.pagination_controls page={2} total_pages={3} build_url={&"/x?page=#{&1}"} />
      """)

    assert html =~ "Zurück"
    assert html =~ "Weiter"
    refute html =~ "Prev"
  end

  describe "dates" do
    test "a time ago and a date use the page's language" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "de")

      assert UtilsDate.ago(DateTime.utc_now()) == "gerade eben"
      refute UtilsDate.ago(~U[2020-03-04 10:00:00Z]) =~ "Mar"

      Gettext.put_locale(PhoenixKitWeb.Gettext, "zh")
      assert UtilsDate.short_with_year(~D[2026-11-08]) == "2026年11月8日"
    end

    test "Never is translated" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "de")
      refute UtilsDate.format_datetime(nil, "Y-m-d") == "Never"
    end
  end
end
