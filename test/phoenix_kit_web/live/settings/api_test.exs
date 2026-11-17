defmodule PhoenixKitWeb.Live.Settings.ApiTest do
  @moduledoc """
  Settings -> API: the switches, the keys table, the create-key form, the
  one-time dialog that shows a new key, and revoking.

  The test module `PhoenixKit.API.KeyTestSupport.FakeModule` declares the scopes
  (`apikeytest.things:read` needs `media`, `apikeytest.things:write` needs
  `media.manage`), because core's own test environment loads no shop module.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.API.OAuthTestSupport, only: [oauth_holder: 1, seed_grant!: 1]

  alias Phoenix.LiveView.Channel
  alias PhoenixKit.Activity
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Settings.Api

  @path Routes.path("/admin/settings/api")

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()

    {admin, _token} = create_admin_user()
    grant_admin!(["api", "media", "media.manage"])

    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp grant_admin!(keys) do
    role = Roles.get_role_by_name("Admin")
    for key <- keys, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    :ok
  end

  # A second Admin who also holds `api`: a person who is not the Owner and did
  # not make the first Admin's keys.
  defp other_admin do
    {user, _token} = create_admin_user()
    user
  end

  defp make_key!(user, attrs \\ %{}) do
    scope = KeyTestSupport.scope_of(user)

    {:ok, key, token} =
      Keys.create_key(user, scope, Map.merge(%{"name" => "Seeded key"}, attrs))

    {key, token}
  end

  defp open_form(view) do
    view |> element("#api-new-key") |> render_click()
    view
  end

  # Fills and submits the create-key form the way a browser would.
  defp submit_key(view, key_params) do
    view
    |> form("#create-api-key-form", %{"key" => key_params})
    |> render_submit()
  end

  defp token_in(html) do
    [_, token] = Regex.run(~r/value="(pk_[^"]+)"/, html)
    token
  end

  defp page_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp key_count, do: Repo.aggregate(Key, :count)

  # The scope a page captures at mount goes stale when a role changes: core tells
  # the page over PubSub, but the message is handled after the next event or is
  # missed. A plain delete sends no message, which is exactly that window, so the
  # tests use it. (`Permissions.revoke_permission/2` also notifies, and core's own
  # refresh would then move the person off the page before the event arrives: that
  # tests core, not this page.)
  defp drop_api_silently! do
    role = Roles.get_role_by_name("Admin")

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    :ok
  end

  # `Phoenix.LiveView.Logger` logs events at :debug and `config/test.exs` sets the
  # primary level to :warning, so the level has to be raised for real or a
  # `refute log =~ secret` passes without having looked at anything.
  defp capture_debug_log(fun) do
    original = Logger.level()
    Logger.configure(level: :debug)

    try do
      with_log([level: :debug], fun)
    after
      Logger.configure(level: original)
    end
  end

  describe "the page" do
    test "shows the switches, the keys card and an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-settings-page")
      assert has_element?(view, "#api-switch-admin-row")
      assert has_element?(view, "#api-switch-public-row")
      assert has_element?(view, "#api-keys-card")
      assert has_element?(view, "#api-keys-empty")
      refute has_element?(view, "#api-keys-table")
    end

    test "both switches start off, as the API is off by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute Config.admin_enabled?()
      refute Config.public_enabled?()
      assert has_element?(view, ~s(#api-switch-admin-row input[phx-click="toggle_switch"]))
      assert has_element?(view, ~s(#api-switch-public-row input[phx-click="toggle_switch"]))
      refute has_element?(view, "#api-switch-admin-row input[checked]")
      refute has_element?(view, "#api-switch-public-row input[checked]")
    end
  end

  describe "the switches" do
    test "the admin switch turns the admin API on and off", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      switch = element(view, ~s(#api-switch-admin-row input[phx-click="toggle_switch"]))

      render_click(switch)
      assert Config.admin_enabled?()
      refute Config.public_enabled?()
      assert has_element?(view, "#api-switch-admin-row input[checked]")

      render_click(switch)
      refute Config.admin_enabled?()
    end

    test "the public switch is independent of the admin switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      view
      |> element(~s(#api-switch-public-row input[phx-click="toggle_switch"]))
      |> render_click()

      assert Config.public_enabled?()
      refute Config.admin_enabled?()
    end

    test "a switch change is recorded in the settings history with this admin as the actor", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, @path)

      view
      |> element(~s(#api-switch-admin-row input[phx-click="toggle_switch"]))
      |> render_click()

      entries = Activity.list(action: "setting.changed", actor_uuid: admin.uuid).entries
      assert Enum.any?(entries, &(&1.metadata["key"] == "api_admin_enabled"))
    end

    test "an unknown switch name is refused and writes no setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html = render_click(view, "toggle_switch", %{"switch" => "evil"})

      assert html =~ "That action is not available."
      assert Settings.get_setting("evil") == nil
      refute Config.admin_enabled?()
    end
  end

  describe "making a key" do
    test "the form offers the scopes the owner could use", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)

      assert has_element?(
               view,
               ~s(#create-api-key-form input[name="key[scopes][]"][value="#{KeyTestSupport.read_scope()}"])
             )
    end

    test "a key is made, shown once, and works", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)

      html =
        submit_key(view, %{"name" => "Stock sync", "scopes" => [KeyTestSupport.read_scope()]})

      token = token_in(html)
      assert String.starts_with?(token, "pk_")
      assert has_element?(view, "#new-api-token-modal")
      assert has_element?(view, "#new-api-token-copy")
      assert has_element?(view, ~s(#new-api-token[readonly]))

      assert {:ok, actor} = Keys.verify(token, nil)
      assert actor.user_uuid == admin.uuid
      assert actor.scopes == [KeyTestSupport.read_scope()]

      assert has_element?(view, "#api-keys-table", "Stock sync")
      refute has_element?(view, "#create-api-key-modal")
    end

    test "the token lives in the :new_token assign and in no flash", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      token = view |> submit_key(%{"name" => "Quiet"}) |> token_in()

      assigns = page_assigns(view)
      assert assigns.new_token.value == token
      refute inspect(assigns.flash) =~ token
    end

    test "termination state inspection never exposes the token", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      token = view |> submit_key(%{"name" => "Crash safe"}) |> token_in()
      state = :sys.get_state(view.pid)
      report = Channel.format_status(:terminate, [[], state])
      inspected = inspect(report, limit: :infinity, printable_limit: :infinity)
      [_pk, _prefix, secret] = String.split(token, "_", parts: 3)

      refute inspected =~ token
      refute inspected =~ secret
      assert render(view) =~ token
    end

    test "dismissing the dialog clears the token for good", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      token = view |> submit_key(%{"name" => "Once"}) |> token_in()

      view |> element("#new-api-token-done") |> render_click()

      refute has_element?(view, "#new-api-token-modal")
      assert page_assigns(view).new_token == nil
      refute render(view) =~ token

      # A new page load shows nothing, and the key row only has its prefix.
      {:ok, _fresh, html} = live(conn, @path)
      refute html =~ token
    end

    test "the modal's close event also clears the token", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      token = view |> submit_key(%{"name" => "Esc"}) |> token_in()

      render_click(view, "dismiss_token", %{})

      assert page_assigns(view).new_token == nil
      refute render(view) =~ token
    end

    test "the dialog cannot be dismissed by accident (no Esc, no click outside)", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      view |> submit_key(%{"name" => "Sticky"})

      assert view |> element("#new-api-token-modal") |> render() =~ ~s(data-closeable="false")
    end

    test "the token never reaches the logs, even at debug level", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      {token, log} =
        capture_debug_log(fn ->
          open_form(view)
          token = view |> submit_key(%{"name" => "Logged"}) |> token_in()
          view |> element("#new-api-token-done") |> render_click()
          token
        end)

      [_pk, _prefix, secret] = String.split(token, "_", parts: 3)

      # Not vacuous: the debug line for the event was captured.
      assert log =~ "create_key"
      refute log =~ token
      refute log =~ secret
    end
  end

  describe "forged input is refused on the server" do
    test "a scope the owner could not use creates no key", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      before = length(Keys.list_keys(KeyTestSupport.scope_of(admin)))

      html =
        render_submit(view, "create_key", %{
          "key" => %{
            "name" => "Greedy",
            "owner" => "self",
            "scopes" => ["catalogue.products:delete"]
          }
        })

      assert html =~ "not available to that owner"
      assert has_element?(view, "#create-api-key-errors")
      assert length(Keys.list_keys(KeyTestSupport.scope_of(admin))) == before
      assert page_assigns(view).new_token == nil
    end

    test "an owner who is another person creates no key", %{conn: conn, admin: admin} do
      other = other_admin()
      {:ok, view, _html} = live(conn, @path)
      open_form(view)

      html =
        render_submit(view, "create_key", %{
          "key" => %{"name" => "Theft", "owner" => other.uuid, "scopes" => []}
        })

      assert html =~ "cannot create keys for that owner"
      assert Keys.list_keys(KeyTestSupport.scope_of(admin)) == []
      assert Keys.list_keys(KeyTestSupport.scope_of(other)) == []
    end

    test "the Owner as the key's owner is refused too", %{conn: conn, admin: admin} do
      owner = KeyTestSupport.owner_user()
      {:ok, view, _html} = live(conn, @path)
      open_form(view)

      html =
        render_submit(view, "create_key", %{
          "key" => %{"name" => "Escalation", "owner" => owner.uuid, "scopes" => []}
        })

      assert html =~ "cannot create keys for that owner"
      assert Keys.list_keys(KeyTestSupport.scope_of(admin)) == []
    end

    test "event params of the wrong shape do not crash the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert render_submit(view, "create_key", %{"key" => "not a map"}) =~
               "That action is not available."

      assert render_click(view, "request_revoke", %{}) =~ "That action is not available."
      assert has_element?(view, "#api-settings-page")
    end
  end

  describe "the form's own checks" do
    test "a key needs a name", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)

      submit_key(view, %{"name" => ""})

      assert has_element?(view, "#create-api-key-errors")
      assert page_assigns(view).new_token == nil
    end

    test "an address list that is not addresses is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)

      submit_key(view, %{"name" => "Bad ips", "allowed_ips" => "not-an-address"})

      assert has_element?(view, "#create-api-key-errors", "allowed_ips")
    end

    test "addresses and an expiry date are stored", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

      submit_key(view, %{
        "name" => "Restricted",
        "allowed_ips" => "203.0.113.0/24, 198.51.100.7",
        "expires_on" => tomorrow
      })

      [key] = Keys.list_keys(KeyTestSupport.scope_of(admin))
      assert key.allowed_ips != []
      assert Date.to_iso8601(DateTime.to_date(key.expires_at)) == tomorrow
    end

    test "an expiry date in the past is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      html = submit_key(view, %{"name" => "Late", "expires_on" => yesterday})

      assert html =~ "must be a date from today on"
    end

    test "changing the form keeps what was typed and drops old errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      submit_key(view, %{"name" => ""})
      assert has_element?(view, "#create-api-key-errors")

      view
      |> form("#create-api-key-form", %{"key" => %{"name" => "Typed"}})
      |> render_change()

      refute has_element?(view, "#create-api-key-errors")
      assert has_element?(view, ~s(#api-key-name[value="Typed"]))
    end
  end

  describe "the keys table" do
    test "a person sees the keys they made, not another person's", %{conn: conn, admin: admin} do
      other = other_admin()
      {mine, _} = make_key!(admin, %{"name" => "Mine"})
      {theirs, _} = make_key!(other, %{"name" => "Theirs"})

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-key-#{mine.uuid}")
      refute has_element?(view, "#api-key-#{theirs.uuid}")
    end

    test "the Owner sees every key", %{conn: conn, admin: admin} do
      other = other_admin()
      {mine, _} = make_key!(admin, %{"name" => "Mine"})
      {theirs, _} = make_key!(other, %{"name" => "Theirs"})

      {:ok, view, _html} = live(log_in_user(conn, KeyTestSupport.owner_user()), @path)

      assert has_element?(view, "#api-key-#{mine.uuid}")
      assert has_element?(view, "#api-key-#{theirs.uuid}")
    end

    test "the hidden key of an OAuth connection is in nobody's table, the Owner's included", %{
      conn: conn,
      admin: admin
    } do
      {_holder, _role, holder_scope} = oauth_holder(["media"])
      hidden = seed_grant!(holder_scope)
      {visible, _} = make_key!(admin, %{"name" => "Visible"})

      for conn <- [conn, log_in_user(Phoenix.ConnTest.build_conn(), KeyTestSupport.owner_user())] do
        {:ok, view, html} = live(conn, @path)

        assert has_element?(view, "#api-key-#{visible.uuid}")
        refute has_element?(view, "#api-key-#{hidden.key.uuid}")
        refute html =~ hidden.key.prefix
      end
    end

    test "a key shows its prefix but never its token or hash", %{conn: conn, admin: admin} do
      {key, token} = make_key!(admin)

      {:ok, view, html} = live(conn, @path)

      assert has_element?(view, "#api-key-#{key.uuid}", "pk_#{key.prefix}_")
      refute html =~ token
    end
  end

  describe "revoking" do
    test "asks first, then revokes and the key stops working", %{conn: conn, admin: admin} do
      {key, token} = make_key!(admin)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element(~s(#api-key-menu-#{key.uuid} button[phx-click="request_revoke"]))
      |> render_click()

      assert has_element?(view, ~s(button[phx-click="confirm_revoke"]))
      assert {:ok, _actor} = Keys.verify(token, nil)

      view |> element(~s(button[phx-click="confirm_revoke"])) |> render_click()

      assert %{revoked_at: %DateTime{}} = Keys.get_key(key.uuid)
      assert {:error, :revoked} = Keys.verify(token, nil)
      refute has_element?(view, ~s(button[phx-click="confirm_revoke"]))
      refute has_element?(view, "#api-key-menu-#{key.uuid}")
    end

    test "cancelling leaves the key alone", %{conn: conn, admin: admin} do
      {key, token} = make_key!(admin)
      {:ok, view, _html} = live(conn, @path)

      render_click(view, "request_revoke", %{"uuid" => key.uuid})
      render_click(view, "cancel_revoke", %{})
      render_click(view, "confirm_revoke", %{})

      assert Keys.get_key(key.uuid).revoked_at == nil
      assert {:ok, _actor} = Keys.verify(token, nil)
    end

    test "a key made by someone else cannot be revoked by a forged event", %{
      conn: conn,
      admin: admin
    } do
      other = other_admin()
      {theirs, token} = make_key!(other)
      _mine = make_key!(admin)
      {:ok, view, _html} = live(conn, @path)

      html = render_click(view, "request_revoke", %{"uuid" => theirs.uuid})
      assert html =~ "That key was not found."

      render_click(view, "confirm_revoke", %{})
      assert Keys.get_key(theirs.uuid).revoked_at == nil
      assert {:ok, _actor} = Keys.verify(token, nil)
    end

    test "the Owner may revoke a key another person made", %{conn: conn, admin: admin} do
      {key, token} = make_key!(admin)
      {:ok, view, _html} = live(log_in_user(conn, KeyTestSupport.owner_user()), @path)

      render_click(view, "request_revoke", %{"uuid" => key.uuid})
      render_click(view, "confirm_revoke", %{})

      assert {:error, :revoked} = Keys.verify(token, nil)
    end
  end

  describe "replayed and stale events" do
    test "a replayed create_key while the token is shown mints no second key", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      token = view |> submit_key(%{"name" => "Once only"}) |> token_in()
      before = key_count()

      # The same event again: a double click, or a forged replay.
      html =
        render_submit(view, "create_key", %{
          "key" => %{"name" => "Once only", "owner" => "self", "scopes" => []}
        })

      assert html =~ "That action is not available."
      assert key_count() == before
      assert page_assigns(view).new_token.value == token
    end

    test "a replayed create_key after the dialog was dismissed mints no second key", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      view |> submit_key(%{"name" => "Once only"})
      view |> element("#new-api-token-done") |> render_click()
      before = key_count()

      # The form is closed and no token is waiting: only the form state refuses.
      html =
        render_submit(view, "create_key", %{
          "key" => %{"name" => "Once only", "owner" => "self", "scopes" => []}
        })

      assert html =~ "That action is not available."
      assert key_count() == before
      assert page_assigns(view).new_token == nil
    end

    test "a forged key_form_changed after the dialog was dismissed does not reopen the form",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      view |> submit_key(%{"name" => "Once only"})
      view |> element("#new-api-token-done") |> render_click()
      before = key_count()

      render_change(view, "key_form_changed", %{
        "key" => %{"name" => "Forged", "owner" => "self", "scopes" => []}
      })

      refute page_assigns(view).show_key_form

      # The reopened form was what let a replayed create_key through.
      render_submit(view, "create_key", %{
        "key" => %{"name" => "Forged", "owner" => "self", "scopes" => []}
      })

      assert key_count() == before
      assert page_assigns(view).new_token == nil
    end

    test "key_form_changed after the person lost api changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      params_before = page_assigns(view).key_params

      drop_api_silently!()
      assert Scope.can?(page_assigns(view).phoenix_kit_current_scope, "api")

      html =
        render_change(view, "key_form_changed", %{
          "key" => %{"name" => "Too late", "owner" => "self", "scopes" => []}
        })

      assert html =~ "You are not allowed to do that."
      assert page_assigns(view).key_params == params_before
    end

    test "a second key cannot replace a token that was not dismissed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      token = view |> submit_key(%{"name" => "First"}) |> token_in()
      before = key_count()

      # The dialog is up. A forged event opens the form behind it and submits it.
      render_click(view, "open_create_key", %{})

      html =
        render_submit(view, "create_key", %{
          "key" => %{"name" => "Second", "owner" => "self", "scopes" => []}
        })

      assert html =~ "That action is not available."
      assert key_count() == before
      assert page_assigns(view).new_token.value == token
    end

    test "create_key after the person lost api creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_form(view)
      before = key_count()

      drop_api_silently!()
      # Not vacuous: the page has not heard of it, its scope still says api.
      assert Scope.can?(page_assigns(view).phoenix_kit_current_scope, "api")

      html = submit_key(view, %{"name" => "Too late"})

      assert html =~ "You are not allowed to do that."
      assert key_count() == before
      assert page_assigns(view).new_token == nil
    end

    test "confirm_revoke after the person lost api revokes nothing", %{conn: conn, admin: admin} do
      {key, _token} = make_key!(admin)
      {:ok, view, _html} = live(conn, @path)
      render_click(view, "request_revoke", %{"uuid" => key.uuid})

      drop_api_silently!()
      assert Scope.can?(page_assigns(view).phoenix_kit_current_scope, "api")

      html = render_click(view, "confirm_revoke", %{})

      assert html =~ "You are not allowed to do that."
      assert Keys.get_key(key.uuid).revoked_at == nil
    end

    test "toggle_switch after the person lost api writes no setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      drop_api_silently!()
      assert Scope.can?(page_assigns(view).phoenix_kit_current_scope, "api")

      html = render_click(view, "toggle_switch", %{"switch" => "admin"})

      assert html =~ "You are not allowed to do that."
      refute Config.admin_enabled?()
    end

    test "a person blocked while the page was open can do nothing", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)

      # A plain update: blocking through the context would also end the session
      # and close the page, which is not the window under test.
      {1, _} =
        Repo.update_all(from(u in User, where: u.uuid == ^admin.uuid), set: [is_active: false])

      html = render_click(view, "toggle_switch", %{"switch" => "admin"})

      assert html =~ "You are not allowed to do that."
      refute Config.admin_enabled?()
    end
  end

  describe "key_status/2" do
    @now ~U[2026-10-11 12:00:00Z]

    defp status(attrs),
      do: Api.key_status(Map.merge(%{revoked_at: nil, expires_at: nil}, attrs), @now)

    test "a key with no end is active" do
      assert status(%{}) == :active
    end

    test "a revoked_at in the past is revoked" do
      assert status(%{revoked_at: ~U[2026-10-11 11:00:00Z]}) == :revoked
    end

    test "a revoked_at in the future is a rotation grace period: ending" do
      assert status(%{revoked_at: ~U[2026-10-11 18:00:00Z]}) == :ending
    end

    test "an expires_at in the past is expired, in the future is ending" do
      assert status(%{expires_at: ~U[2026-10-10 00:00:00Z]}) == :expired
      assert status(%{expires_at: ~U[2026-11-01 00:00:00Z]}) == :ending
    end

    test "revoked wins over expired" do
      assert status(%{revoked_at: ~U[2026-10-01 00:00:00Z], expires_at: ~U[2026-10-02 00:00:00Z]}) ==
               :revoked
    end
  end
end
