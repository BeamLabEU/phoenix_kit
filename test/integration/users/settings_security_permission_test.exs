defmodule PhoenixKit.Integration.Users.SettingsSecurityPermissionTest do
  @moduledoc """
  `settings.security`, a sub-permission of the core `settings` section: it gates
  the Authorization and Website access pages and the registration /
  new-user-default settings, is backfilled once to the roles that held
  `settings`, and the new-user default role is never Owner or Admin nor a role
  the person saving it could not hand out.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.DataCase, only: [errors_on: 1]

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate}

  @flag "settings_security_backfilled"

  defp role!(keys) do
    {:ok, role} = Roles.create_role(%{name: "Sec perms #{System.unique_integer([:positive])}"})
    for key <- keys, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    role
  end

  defp held(role), do: MapSet.new(Permissions.get_permissions_for_role(role.uuid))

  defp user_with(role) do
    {:ok, user} =
      Auth.register_user(%{
        email: "sec-perms-#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  # Every key `SettingsForm` requires, at harmless values.
  defp form_params(params) do
    Map.merge(
      %{
        "project_title" => Settings.get_setting("project_title", "PhoenixKit"),
        "new_user_default_role" => "User",
        "new_user_default_status" => "true",
        "week_start_day" => "1",
        "time_zone" => "0",
        "date_format" => "Y-m-d",
        "time_format" => "H:i",
        "track_registration_geolocation" => "false"
      },
      params
    )
  end

  setup do
    {:ok, _} = Settings.update_setting("new_user_default_role", "User")
    {:ok, _} = Settings.update_setting("allow_registration", "true")
    :ok
  end

  describe "registration" do
    test "settings.security belongs to settings" do
      assert Permissions.parent_key("settings.security") == "settings"

      assert "settings.security" in Enum.map(
               Permissions.sub_permissions_for("settings"),
               & &1.key
             )

      assert "settings.security" in Permissions.all_module_keys()
      assert Permissions.feature_enabled?("settings.security")
    end
  end

  describe "backfill_settings_sub_permissions/0" do
    setup do
      {:ok, _} = Settings.update_setting(@flag, "false")
      :ok
    end

    test "grants it once to every role that holds settings, and only those" do
      holder = role!(["settings"])
      other = role!(["users"])

      assert :ok = Permissions.backfill_settings_sub_permissions()
      assert Settings.get_setting(@flag) == "true"
      assert "settings.security" in held(holder)
      refute "settings.messages" in held(holder)
      refute "settings.security" in held(other)

      :ok = Permissions.revoke_permission(holder.uuid, "settings.security")
      later = role!(["settings"])
      assert :ok = Permissions.backfill_settings_sub_permissions()

      refute "settings.security" in held(holder)
      refute "settings.security" in held(later)
    end
  end

  describe "the security pages" do
    setup do
      {:ok, _} = Settings.update_setting(@flag, "true")
      :ok
    end

    test "settings alone does not open them; settings.security does", %{conn: conn} do
      plain = role!(["settings"])
      security = role!(["settings", "settings.security"])

      for path <- ["/admin/settings/authorization", "/admin/settings/website-access"] do
        assert {:error, {:redirect, _}} =
                 live(log_in_user(conn, user_with(plain)), Routes.path(path)),
               path

        assert {:ok, _view, _html} =
                 live(log_in_user(conn, user_with(security)), Routes.path(path)),
               path
      end

      assert {:ok, _view, _html} =
               live(log_in_user(conn, user_with(plain)), Routes.path("/admin/settings"))
    end

    test "a write event is refused to a scope without settings.security, on both pages", %{
      conn: conn
    } do
      security = role!(["settings", "settings.security"])
      plain_scope = Scope.for_user(user_with(role!(["settings"])))
      conn = log_in_user(conn, user_with(security))

      # Mounted with the key; the scope then becomes one without it (as after a
      # revoke). Only the per-event gate stands between the event and a write.
      {:ok, view, _} = live(conn, Routes.path("/admin/settings/website-access"))
      swap_scope(view, plain_scope)

      html =
        render_submit(view, "save_allowed", %{"allowed" => %{"addresses" => "203.0.113.9"}})

      assert html =~ "You do not have permission to change security settings"
      refute "203.0.113.9" in AllowedAddresses.list()

      {:ok, view, _} = live(conn, Routes.path("/admin/settings/authorization"))
      swap_scope(view, plain_scope)

      html =
        render_submit(view, "save_settings", %{
          "settings" => form_params(%{"magic_link_login_enabled" => "false"})
        })

      assert html =~ "You do not have permission to change security settings"
      refute html =~ "Authorization settings updated successfully"
    end

    test "the gate password is never rendered", %{conn: conn} do
      {:ok, _} = Gate.set_password("Secret42-#{System.unique_integer([:positive])}")
      password = Gate.password()
      security = role!(["settings", "settings.security"])

      {:ok, view, html} =
        live(
          log_in_user(conn, user_with(security)),
          Routes.path("/admin/settings/website-access")
        )

      refute html =~ password
      refute html =~ ~s(phx-click="reveal_password")
      assert render(view) =~ "••••••••"
    after
      Settings.update_setting(Gate.password_key(), "")
    end
  end

  describe "update_settings/2 writes only what a form owns" do
    test "an internal flag or an unknown key in a save is ignored", %{conn: conn} do
      {:ok, _} = Settings.update_setting(@flag, "true")
      user = user_with(role!(["settings"]))
      {:ok, view, _} = live(log_in_user(conn, user), Routes.path("/admin/settings"))

      render_submit(view, "save_settings", %{
        "settings" =>
          form_params(%{
            "project_title" => "Flag probe",
            @flag => "false",
            "pk_probe_unknown_key" => "x"
          })
      })

      assert Settings.get_setting("project_title") == "Flag probe"
      assert Settings.get_setting(@flag) == "true"
      assert Settings.get_setting("pk_probe_unknown_key") == nil
    end
  end

  describe "update_settings/2 with scope:" do
    setup do
      {:ok, _} = Settings.update_setting(@flag, "true")
      :ok
    end

    test "without settings.security the security keys are left alone" do
      scope = Scope.for_user(user_with(role!(["settings"])))

      assert {:ok, saved} =
               Settings.update_settings(
                 form_params(%{
                   "project_title" => "Still mine",
                   "allow_registration" => "false",
                   "oauth_google_client_secret" => "stolen",
                   "website_access_password" => "x"
                 }),
                 scope: scope
               )

      assert saved["project_title"] == "Still mine"
      refute Map.has_key?(saved, "allow_registration")
      assert Settings.get_setting("allow_registration") == "true"
      refute Settings.get_setting("oauth_google_client_secret") == "stolen"
      refute Gate.password() == "x"
    end

    test "crawlers_no_index is a security key (Website access writes it)" do
      assert Settings.security_setting_key?("crawlers_no_index")
      {:ok, _} = Crawlers.update_no_index(false)
      scope = Scope.for_user(user_with(role!(["settings"])))

      assert {:ok, _} =
               Settings.update_settings(form_params(%{"crawlers_no_index" => "true"}),
                 scope: scope
               )

      refute Settings.get_setting("crawlers_no_index") == "true"
    end

    test "auth_language_switcher_enabled is a security key (the Authorization page writes it)" do
      assert Settings.security_setting_key?("auth_language_switcher_enabled")
      {:ok, _} = Settings.update_setting("auth_language_switcher_enabled", "true")
      plain = Scope.for_user(user_with(role!(["settings"])))
      secure = Scope.for_user(user_with(role!(["settings", "settings.security"])))
      params = form_params(%{"auth_language_switcher_enabled" => "false"})

      assert {:ok, _} = Settings.update_settings(params, scope: plain)
      assert Settings.get_setting("auth_language_switcher_enabled") == "true"

      assert {:ok, _} = Settings.update_settings(params, scope: secure)
      assert Settings.get_setting("auth_language_switcher_enabled") == "false"
    end

    test "with settings.security they are written" do
      scope = Scope.for_user(user_with(role!(["settings", "settings.security"])))

      assert {:ok, _} =
               Settings.update_settings(
                 form_params(%{"allow_registration" => "false"}),
                 scope: scope
               )

      assert Settings.get_setting("allow_registration") == "false"
    end

    test "the default role must be one the saver may hand out" do
      scope = Scope.for_user(user_with(role!(["settings", "settings.security"])))
      wider = role!(["settings", "sitemap"])
      narrower = role!(["settings"])

      assert {:error, %Ecto.Changeset{} = cs} =
               Settings.update_settings(form_params(%{"new_user_default_role" => wider.name}),
                 scope: scope
               )

      assert %{new_user_default_role: [_ | _]} = errors_on(cs)
      assert Settings.get_setting("new_user_default_role") == "User"

      assert {:ok, _} =
               Settings.update_settings(form_params(%{"new_user_default_role" => narrower.name}),
                 scope: scope
               )

      assert Settings.get_setting("new_user_default_role") == narrower.name
    end

    test "the General page cannot change them through its hidden fields", %{conn: conn} do
      user = user_with(role!(["settings"]))
      {:ok, view, _} = live(log_in_user(conn, user), Routes.path("/admin/settings"))

      render_submit(view, "save_settings", %{
        "settings" => %{
          "project_title" => "General save",
          "allow_registration" => "false",
          "new_user_default_role" => "User",
          "new_user_default_status" => "true",
          "track_registration_geolocation" => "false",
          "week_start_day" => "1",
          "time_zone" => "0",
          "date_format" => "Y-m-d",
          "time_format" => "H:i"
        }
      })

      assert Settings.get_setting("project_title") == "General save"
      assert Settings.get_setting("allow_registration") == "true"
    end

    test "the Users page cannot change them without the key", %{conn: conn} do
      user = user_with(role!(["settings"]))
      {:ok, view, html} = live(log_in_user(conn, user), Routes.path("/admin/settings/users"))
      assert html =~ "registration-security-locked"

      render_submit(view, "save_settings", %{
        "settings" => %{
          "project_title" => Settings.get_setting("project_title", "PhoenixKit"),
          "allow_registration" => "false",
          "new_user_default_role" => role!([]).name,
          "new_user_default_status" => "true",
          "track_registration_geolocation" => "false",
          "week_start_day" => "1",
          "time_zone" => "0",
          "date_format" => "Y-m-d",
          "time_format" => "H:i"
        }
      })

      assert Settings.get_setting("allow_registration") == "true"
      assert Settings.get_setting("new_user_default_role") == "User"
    end
  end

  describe "the new-user default role" do
    test "may not be Admin or Owner" do
      for name <- ["Admin", "Owner"] do
        cs = Settings.validate_settings(%{"new_user_default_role" => name})
        assert %{new_user_default_role: [_ | _]} = errors_on(cs), name
      end

      refute {"Admin", "Admin"} in Settings.get_role_options()
    end

    test "a stored Admin reads as User, so the forms still save" do
      {:ok, _} = Settings.update_setting("new_user_default_role", "Admin")
      shown = Settings.list_public_settings()["new_user_default_role"]
      assert shown == "User"

      for keys <- [["settings"], ["settings", "settings.security"]] do
        scope = Scope.for_user(user_with(role!(keys)))

        assert {:ok, _} =
                 Settings.update_settings(form_params(%{"new_user_default_role" => shown}),
                   scope: scope
                 ),
               inspect(keys)
      end
    end

    test "a stored Admin is never used for a new registration" do
      # Written around the changeset, as a corrupted or hand-edited row would be.
      {:ok, _} = Settings.update_setting("new_user_default_role", "Admin")

      {:ok, user} =
        Auth.register_user(%{
          email: "sec-default-#{System.unique_integer([:positive])}@example.com",
          password: "TestPassword123!"
        })

      refute Roles.user_has_role?(user, "Admin")
      assert Roles.user_has_role?(user, "User")
    end
  end

  # Replaces the scope a mounted LiveView holds, as a mid-session refresh would.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.phoenix_kit_current_scope, scope)
    end)
  end
end
