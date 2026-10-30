defmodule PhoenixKitWeb.Live.Settings.ApiPersonalKeysTest do
  @moduledoc """
  Settings -> API and personal keys: the badge and the expiry in the keys table, what an
  Owner may do with someone else's personal key (revoke it and remove scopes, never rotate
  or widen), rotation of one's own personal key and the borrowed session, the form of the
  two personal-key settings, and who may open the page at all.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.Users.Auth, as: AuthCtx
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api")
  @right "api_personal_keys"
  @read KeyTestSupport.read_scope()
  @write KeyTestSupport.write_scope()

  setup do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp end_of_day(days),
    do: DateTime.new!(Date.add(Date.utc_today(), days), ~T[23:59:59], "Etc/UTC")

  defp personal!(scope, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Agent #{System.unique_integer([:positive])}",
          scopes: [@read],
          expires_at: end_of_day(30)
        },
        extra
      )

    {:ok, key, token} = Keys.create_personal_key(scope, attrs, impersonated: false)
    {key, token}
  end

  # A person with the new permission and the permissions of the fake scopes.
  defp personal_holder do
    {user, role} = KeyTestSupport.user_without_api([@right, "media", "media.manage"])
    {user, role, KeyTestSupport.scope_of(user)}
  end

  defp owner_conn(conn), do: log_in_user(conn, KeyTestSupport.owner_user())

  defp borrowed(conn) do
    {root, _role} = KeyTestSupport.user_without_api([@right])
    root_token = AuthCtx.generate_user_session_token(root)
    active_token = Plug.Conn.get_session(conn, :user_token)
    Plug.Conn.put_session(conn, :pk_session_accounts, [root_token, active_token])
  end

  defp menu_button(view, key, event),
    do: element(view, ~s(#api-key-menu-#{key.uuid} button[phx-click="#{event}"]))

  defp refused?(result),
    do: match?({:error, {kind, _}} when kind in [:redirect, :live_redirect], result)

  defp drop_api_silently!(role) do
    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    :ok
  end

  defp reloaded(key), do: Repo.get!(Key, key.uuid)

  # ── The keys table ─────────────────────────────────────────────────

  describe "the keys table" do
    test "marks a personal key and shows when it expires; an ordinary key has neither", %{
      conn: conn
    } do
      {_user, _role, scope} = personal_holder()
      {personal, _} = personal!(scope)
      {holder, _role} = KeyTestSupport.user_with(["media"])
      {ordinary, _} = KeyTestSupport.create_key!(holder, KeyTestSupport.scope_of(holder))

      {:ok, view, _html} = live(owner_conn(conn), @path)

      assert has_element?(view, "#api-key-#{personal.uuid} span.badge", "Personal key")
      assert has_element?(view, "#api-key-#{personal.uuid}", "Expires on")

      date = personal.expires_at |> DateTime.to_date() |> Date.to_iso8601()
      assert has_element?(view, "#api-key-#{personal.uuid}", date)
      refute has_element?(view, "#api-key-#{ordinary.uuid} span.badge", "Personal key")
      refute has_element?(view, "#api-key-#{ordinary.uuid}", "Expires on")
    end

    test "the expiry is the UTC day chosen, for a viewer east of UTC too", %{conn: conn} do
      {_user, _role, scope} = personal_holder()
      {key, _} = personal!(scope, %{expires_at: end_of_day(10)})

      viewer =
        KeyTestSupport.owner_user()
        |> Ecto.Changeset.change(user_timezone: "+9")
        |> Repo.update!()

      {:ok, view, _html} = live(log_in_user(conn, viewer), @path)

      day = key.expires_at |> DateTime.to_date() |> Date.to_iso8601()
      assert has_element?(view, "#api-key-#{key.uuid}", "Expires on #{day}")
    end

    test "an expired or revoked personal key does not say when it expires", %{conn: conn} do
      {_user, _role, scope} = personal_holder()
      {expired, _} = personal!(scope)
      {revoked, _} = personal!(scope)

      expired
      |> Ecto.Changeset.change(
        expires_at:
          DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      {:ok, _} = Keys.revoke(revoked, scope.user.uuid)

      {:ok, view, _html} = live(owner_conn(conn), @path)

      assert has_element?(view, "#api-key-#{expired.uuid}", "Expired")
      assert has_element?(view, "#api-key-#{revoked.uuid}", "Revoked")
      refute has_element?(view, "#api-key-#{expired.uuid}", "Expires on")
      refute has_element?(view, "#api-key-#{revoked.uuid}", "Expires on")
    end

    test "'Owner inactive' for a blocked owner, apart from 'No permission'", %{conn: conn} do
      {user, _role, scope} = personal_holder()
      {key, _} = personal!(scope)

      user |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      {:ok, view, _html} = live(owner_conn(conn), @path)

      assert has_element?(view, "#api-key-#{key.uuid}", "Owner inactive")
      refute has_element?(view, "#api-key-#{key.uuid}", "No permission")
    end

    test "'Expires soon' only within seven days", %{conn: conn} do
      {_user, _role, scope} = personal_holder()
      {soon, _} = personal!(scope, %{expires_at: end_of_day(3)})
      {later, _} = personal!(scope, %{expires_at: end_of_day(30)})

      {:ok, view, _html} = live(owner_conn(conn), @path)

      assert has_element?(view, "#api-key-#{soon.uuid}", "Expires soon")
      refute has_element?(view, "#api-key-#{later.uuid}", "Expires soon")
      refute has_element?(view, "#api-key-#{later.uuid}", "Ending")
    end

    test "a key in the grace period of a rotation still says until when", %{conn: conn} do
      {_user, _role, scope} = personal_holder()
      {key, _} = personal!(scope)
      {:ok, _new, _token} = Keys.rotate(key, 2, scope, impersonated: false)

      {:ok, view, _html} = live(owner_conn(conn), @path)

      assert has_element?(view, "#api-key-#{key.uuid}", "until")
    end

    test "'No permission' when its owner lost the right to use it", %{conn: conn} do
      {user, role, scope} = personal_holder()
      {key, _} = personal!(scope)

      {n, _} =
        Repo.delete_all(
          from(rp in RolePermission,
            where: rp.role_uuid == ^role.uuid and rp.module_key == @right
          )
        )

      assert n == 1
      refute Keys.active?(key)
      assert user.uuid == key.user_uuid

      {:ok, view, _html} = live(owner_conn(conn), @path)
      assert has_element?(view, "#api-key-#{key.uuid}", "No permission")
    end
  end

  # ── The Owner and someone else's personal key ──────────────────────

  describe "a switch flipped while the key list changes elsewhere" do
    # Each of the three switch events re-reads the keys, so a personal key made (or ended)
    # behind the page's back must show with its real status and never crash the page.
    @switch_events [
      {"toggle_switch", %{"switch" => "admin"}},
      {"set_module_api", %{"module" => "apikeytest", "state" => "off"}},
      {"set_module_session_write", %{"module" => "apikeytest", "state" => "on"}}
    ]

    for {event, params} <- @switch_events do
      test "#{event} lists a personal key created after the page was mounted", %{conn: conn} do
        {:ok, view, _html} = live(owner_conn(conn), @path)

        {_user, _role, scope} = personal_holder()
        {created, _} = personal!(scope)
        refute has_element?(view, "#api-key-#{created.uuid}")

        html = render_click(view, unquote(event), unquote(Macro.escape(params)))

        assert html =~ created.name
        assert has_element?(view, "#api-key-#{created.uuid} span.badge", "Active")
      end

      test "#{event} shows a personal key revoked after the page was mounted as revoked", %{
        conn: conn
      } do
        {_user, _role, scope} = personal_holder()
        {key, _} = personal!(scope)
        {:ok, view, _html} = live(owner_conn(conn), @path)
        assert has_element?(view, "#api-key-#{key.uuid} span.badge", "Active")

        {:ok, _} = Keys.revoke(key, nil)
        render_click(view, unquote(event), unquote(Macro.escape(params)))

        assert has_element?(view, "#api-key-#{key.uuid} span.badge", "Revoked")
      end
    end
  end

  describe "an Owner and a personal key of another person" do
    setup %{conn: conn} do
      {_user, _role, scope} = personal_holder()
      {key, _} = personal!(scope, %{scopes: [@read, @write]})
      %{conn: owner_conn(conn), key: key}
    end

    test "the menu offers Remove scopes and Revoke, not Rotate or Edit scopes", %{
      conn: conn,
      key: key
    } do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(
               view,
               ~s(#api-key-menu-#{key.uuid} button[phx-click="request_edit_scopes"]),
               "Remove scopes"
             )

      assert has_element?(menu_button(view, key, "request_revoke"))
      refute has_element?(menu_button(view, key, "request_rotate"))
      refute has_element?(view, "#api-key-menu-#{key.uuid}", "Edit scopes")
    end

    test "revokes it", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, @path)

      menu_button(view, key, "request_revoke") |> render_click()
      view |> element(~s(button[phx-click="confirm_revoke"])) |> render_click()

      assert reloaded(key).revoked_at
    end

    test "removes scopes, offering only the ones the key has", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, @path)

      html = menu_button(view, key, "request_edit_scopes") |> render_click()
      assert html =~ "Remove scopes from this key"

      assert has_element?(view, ~s(#edit-key-scopes-form input[value="#{@read}"][checked]))
      assert has_element?(view, ~s(#edit-key-scopes-form input[value="#{@write}"][checked]))

      view
      |> form("#edit-key-scopes-form", %{"key_scopes" => %{"scopes" => [@read]}})
      |> render_submit()

      assert reloaded(key).scopes == [@read]
    end

    test "can remove an inactive scope, which is marked as such", %{conn: conn} do
      {user, role, scope} = personal_holder()
      {key, _} = personal!(scope, %{scopes: [@read, @write]})

      {1, _} =
        Repo.delete_all(
          from(rp in RolePermission,
            where: rp.role_uuid == ^role.uuid and rp.module_key == "media.manage"
          )
        )

      assert user.uuid == key.user_uuid

      {:ok, view, _html} = live(conn, @path)
      html = menu_button(view, key, "request_edit_scopes") |> render_click()

      assert html =~ "inactive"
      assert has_element?(view, ~s(#edit-key-scopes-form input[value="#{@write}"]))

      view
      |> form("#edit-key-scopes-form", %{"key_scopes" => %{"scopes" => [@read]}})
      |> render_submit()

      assert reloaded(key).scopes == [@read]
    end

    test "a forged save that adds a scope is refused and the key stays as it was", %{conn: conn} do
      {_user, _role, scope} = personal_holder()
      {key, _} = personal!(scope, %{scopes: [@read]})

      {:ok, view, _html} = live(conn, @path)
      menu_button(view, key, "request_edit_scopes") |> render_click()

      html =
        render_hook(view, "save_key_scopes", %{
          "key_scopes" => %{"present" => "1", "scopes" => [@read, @write]}
        })

      assert html =~ "Remove scopes from this key"
      assert reloaded(key).scopes == [@read]
    end

    test "a forged save with a malformed scope list changes nothing", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, @path)
      menu_button(view, key, "request_edit_scopes") |> render_click()

      for scopes <- ["x", %{"x" => "y"}, [@read, %{"a" => "b"}]] do
        render_hook(view, "save_key_scopes", %{
          "key_scopes" => %{"present" => "1", "scopes" => scopes}
        })

        assert reloaded(key).scopes == [@read, @write]
      end
    end

    test "when its owner may not use it, every scope is marked inactive", %{conn: conn} do
      {_user, role, scope} = personal_holder()
      {key, _} = personal!(scope, %{scopes: [@read, @write]})

      {1, _} =
        Repo.delete_all(
          from(rp in RolePermission,
            where: rp.role_uuid == ^role.uuid and rp.module_key == @right
          )
        )

      {:ok, view, _html} = live(conn, @path)
      html = menu_button(view, key, "request_edit_scopes") |> render_click()

      assert length(Regex.scan(~r/>\s*inactive\s*</, html)) == 2
    end

    test "a forged request_rotate and confirm_rotate rotate nothing", %{conn: conn, key: key} do
      before = Repo.aggregate(Key, :count)
      {:ok, view, _html} = live(conn, @path)

      assert render_hook(view, "request_rotate", %{"uuid" => key.uuid}) =~
               "That action is not available."

      render_hook(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}})

      assert Repo.aggregate(Key, :count) == before
      assert reloaded(key).revoked_at == nil
      refute has_element?(view, "#new-api-token-done")
    end
  end

  # ── Rotating one's own personal key ────────────────────────────────

  describe "rotating one's own personal key" do
    test "an api holder gets a new personal key, within the ceiling and without approval", %{
      conn: conn
    } do
      {user, _role} = KeyTestSupport.user_with(["media"])
      scope = KeyTestSupport.scope_of(user)
      {key, _} = personal!(scope)

      {:ok, view, _html} = live(log_in_user(conn, user), @path)

      menu_button(view, key, "request_rotate") |> render_click()
      latest_before = PersonalKeysConfig.latest_expiry()

      view
      |> form("#rotate-api-key-form", %{"rotate" => %{"grace_hours" => "1"}})
      |> render_submit()

      assert has_element?(view, "#new-api-token-done")

      new_key =
        Repo.one!(from(k in Key, where: k.uuid != ^key.uuid and k.user_uuid == ^user.uuid))

      assert new_key.personal
      refute new_key.requires_approval
      # Read around the rotation, so a run across UTC midnight still matches.
      assert new_key.expires_at in [latest_before, PersonalKeysConfig.latest_expiry()]
      assert reloaded(key).revoked_at
    end

    test "at the limit the dialog starts at grace 0 and says why; a longer grace is refused", %{
      conn: conn
    } do
      {user, _role} = KeyTestSupport.user_with(["media"])
      scope = KeyTestSupport.scope_of(user)
      KeyTestSupport.put_setting("api_personal_key_max_count", 2)
      {key, _} = personal!(scope)
      {_other, _} = personal!(scope)
      before = Repo.aggregate(Key, :count)

      {:ok, view, _html} = live(log_in_user(conn, user), @path)

      menu_button(view, key, "request_rotate") |> render_click()
      assert has_element?(view, "#rotate-api-key-at-limit")
      assert has_element?(view, ~s(#rotate-grace-hours option[value="0"][selected]))

      html =
        view
        |> form("#rotate-api-key-form", %{"rotate" => %{"grace_hours" => "3"}})
        |> render_submit()

      assert html =~ "the old key cannot keep working next to the new one"
      assert Repo.aggregate(Key, :count) == before
      assert reloaded(key).revoked_at == nil

      menu_button(view, key, "request_rotate") |> render_click()
      view |> form("#rotate-api-key-form") |> render_submit()

      assert has_element?(view, "#new-api-token-done")
      assert Repo.aggregate(Key, :count) == before + 1
      assert reloaded(key).revoked_at
    end

    test "below the limit the dialog starts at one hour, without the notice", %{conn: conn} do
      {user, _role} = KeyTestSupport.user_with(["media"])
      {key, _} = personal!(KeyTestSupport.scope_of(user))

      {:ok, view, _html} = live(log_in_user(conn, user), @path)

      menu_button(view, key, "request_rotate") |> render_click()
      refute has_element?(view, "#rotate-api-key-at-limit")
      assert has_element?(view, ~s(#rotate-grace-hours option[value="1"][selected]))
    end

    test "in a borrowed session it is refused; an ordinary key rotates as before", %{conn: conn} do
      {user, _role} = KeyTestSupport.user_with(["media"])
      scope = KeyTestSupport.scope_of(user)
      {personal, _} = personal!(scope)
      {ordinary, _} = KeyTestSupport.create_key!(user, scope)
      before = Repo.aggregate(Key, :count)

      {:ok, view, _html} = live(borrowed(log_in_user(conn, user)), @path)

      menu_button(view, personal, "request_rotate") |> render_click()

      html =
        view
        |> form("#rotate-api-key-form", %{"rotate" => %{"grace_hours" => "1"}})
        |> render_submit()

      assert html =~ "Personal keys cannot be rotated while you act in another account."
      assert Repo.aggregate(Key, :count) == before
      assert reloaded(personal).revoked_at == nil

      menu_button(view, ordinary, "request_rotate") |> render_click()

      view
      |> form("#rotate-api-key-form", %{"rotate" => %{"grace_hours" => "1"}})
      |> render_submit()

      assert Repo.aggregate(Key, :count) == before + 1
      assert reloaded(ordinary).revoked_at
    end

    test "editing the scopes and revoking one's own personal key work in a borrowed session", %{
      conn: conn
    } do
      {user, _role} = KeyTestSupport.user_with(["media", "media.manage"])
      scope = KeyTestSupport.scope_of(user)
      {key, _} = personal!(scope, %{scopes: [@read, @write]})

      {:ok, view, _html} = live(borrowed(log_in_user(conn, user)), @path)

      menu_button(view, key, "request_edit_scopes") |> render_click()

      view
      |> form("#edit-key-scopes-form", %{"key_scopes" => %{"scopes" => [@read]}})
      |> render_submit()

      assert reloaded(key).scopes == [@read]

      menu_button(view, key, "request_revoke") |> render_click()
      view |> element(~s(button[phx-click="confirm_revoke"])) |> render_click()
      assert reloaded(key).revoked_at
    end
  end

  # ── The two settings ───────────────────────────────────────────────

  describe "the personal keys form" do
    setup %{conn: conn} do
      KeyTestSupport.put_setting("api_personal_key_max_days", "90")
      KeyTestSupport.put_setting("api_personal_key_max_count", "5")
      %{conn: owner_conn(conn)}
    end

    defp changed_settings do
      Activity.list(action: "setting.changed").entries
      |> Enum.map(& &1.metadata["key"])
      |> Enum.filter(&String.starts_with?(&1, "api_personal_key"))
    end

    test "shows the current values and saves new ones", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-personal-keys-card")
      assert has_element?(view, ~s(#api-personal-keys-max-days[value="90"]))
      assert has_element?(view, ~s(#api-personal-keys-max-count[value="5"]))

      view
      |> form("#api-personal-keys-form", %{
        "personal_keys" => %{"max_days" => "30", "max_count" => "8"}
      })
      |> render_submit()

      assert PersonalKeysConfig.max_days() == 30
      assert PersonalKeysConfig.max_count() == 8
    end

    test "refuses every value outside its range and writes nothing", %{conn: conn} do
      before = changed_settings()
      {:ok, view, _html} = live(conn, @path)

      for {days, count} <- [{"0", "5"}, {"366", "5"}, {"30", "51"}, {"30", "0"}, {"abc", "5"}] do
        html =
          render_hook(view, "save_personal_keys", %{
            "personal_keys" => %{"max_days" => days, "max_count" => count}
          })

        assert html =~ "Every value must be a whole number inside its range."
      end

      assert PersonalKeysConfig.current() == %{"max_days" => "90", "max_count" => "5"}
      assert changed_settings() == before
    end

    test "drops fields the form never offers", %{conn: conn} do
      before = changed_settings()
      {:ok, view, _html} = live(conn, @path)

      render_hook(view, "save_personal_keys", %{
        "personal_keys" => %{
          "max_days" => "30",
          "max_count" => "5",
          "api_admin_enabled" => "true",
          "api_personal_key_max_count" => "50"
        }
      })

      assert PersonalKeysConfig.max_days() == 30
      assert PersonalKeysConfig.max_count() == 5
      assert changed_settings() -- before == ["api_personal_key_max_days"]
    end

    test "writes nothing once the person has lost api in the middle of the session", %{conn: conn} do
      {admin, _token} = create_admin_user()
      {role, _} = KeyTestSupport.role_with(["api"])
      {:ok, _} = Roles.assign_role(admin, role.name)

      {:ok, view, _html} = live(log_in_user(conn, admin), @path)
      drop_api_silently!(role)

      html =
        render_hook(view, "save_personal_keys", %{
          "personal_keys" => %{"max_days" => "30", "max_count" => "8"}
        })

      assert html =~ "You are not allowed to do that."
      assert PersonalKeysConfig.current() == %{"max_days" => "90", "max_count" => "5"}
    end
  end

  # ── Who may open the page ──────────────────────────────────────────

  describe "a holder of only api_personal_keys" do
    test "cannot open Settings -> API, the approvals or the guide", %{conn: conn} do
      {user, _role} = KeyTestSupport.user_without_api([@right])
      conn = log_in_user(conn, user)

      for path <- [
            @path,
            Routes.path("/admin/approvals"),
            Routes.path("/admin/settings/api/guide")
          ] do
        assert refused?(live(conn, path)), path
      end
    end
  end
end
