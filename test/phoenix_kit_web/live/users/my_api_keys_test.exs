defmodule PhoenixKitWeb.Live.Users.MyApiKeysTest do
  @moduledoc """
  "My API keys" (`/profile/settings/api-keys`): who may open it, the tab, creating, rotating,
  editing and revoking a personal key, the token that is shown once, forged input for every
  event, a right lost in the middle of the session, a borrowed session, and the API switched
  off. The rules live in the shared component, so this also covers what the `UserSettings`
  section relies on.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.PersonalKeyDisplay

  @path Routes.path("/profile/settings/api-keys")
  @component "#personal-api-keys"
  @right "api_personal_keys"
  @read KeyTestSupport.read_scope()
  @write KeyTestSupport.write_scope()
  @run KeyTestSupport.run_scope()

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    KeyTestSupport.put_setting("api_admin_enabled", "true")

    {user, role} = KeyTestSupport.user_without_api([@right, "media"])

    %{conn: log_in_user(conn, user), user: user, role: role, scope: KeyTestSupport.scope_of(user)}
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

  # Another person who holds the new permission, with one personal key.
  defp stranger_key do
    {stranger, _role} = KeyTestSupport.user_without_api([@right, "media"])
    {key, _token} = personal!(KeyTestSupport.scope_of(stranger))
    key
  end

  # An event sent to the component, the way its own element would send it.
  defp fire(view, event, params \\ %{}),
    do: view |> with_target(@component) |> render_hook(event, params)

  defp open_create(view),
    do: view |> element("#personal-api-keys-new-key") |> render_click()

  defp create_params(extra \\ %{}) do
    Map.merge(
      %{
        "name" => "Stock sync",
        "scopes" => [@read],
        "allowed_ips" => "",
        "expires_on" => Date.to_iso8601(Date.add(Date.utc_today(), 30))
      },
      extra
    )
  end

  defp submit_create(view, extra \\ %{}),
    do: fire(view, "create_key", %{"key" => create_params(extra)})

  defp new_token_in(html) do
    case Regex.run(~r/value="(pk_[^"]+)"/, html) do
      [_, token] -> token
      nil -> nil
    end
  end

  defp keys_of(user), do: Repo.all(from(k in Key, where: k.user_uuid == ^user.uuid))

  # The page's scope is captured at mount; a plain delete sends no PubSub message, so the
  # page does not hear of it: the window the server-side re-check is for.
  defp drop_right_silently!(role) do
    {n, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == @right)
      )

    assert n == 1
  end

  defp capture_debug_log(fun) do
    original = Logger.level()
    Logger.configure(level: :debug)

    try do
      with_log([level: :debug], fun)
    after
      Logger.configure(level: original)
    end
  end

  defp borrowed(conn) do
    {root, _token} = KeyTestSupport.user_without_api([@right])
    root_token = AuthCtx.generate_user_session_token(root)
    active_token = Plug.Conn.get_session(conn, :user_token)
    Plug.Conn.put_session(conn, :pk_session_accounts, [root_token, active_token])
  end

  # ── Access and the tab ─────────────────────────────────────────────

  describe "access" do
    test "a person with neither permission is sent back to the profile settings" do
      {user, _role} = KeyTestSupport.user_without_api(["media"])
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

      assert {:error, {:redirect, %{to: to}}} = live(conn, @path)
      assert to == Routes.path("/profile/settings")
    end

    test "a holder of api_personal_keys opens the page", %{conn: conn} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "My API keys"
      assert has_element?(view, "#personal-api-keys-new-key")
      refute has_element?(view, "#personal-api-keys-other-keys")
    end

    test "a holder of api opens it too, and is pointed to Settings -> API" do
      {user, _role} = KeyTestSupport.user_with(["media"])
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#personal-api-keys-other-keys a[href*='/admin/settings/api']")
    end

    test "the tab shows on the settings page for a holder, and opens the page", %{conn: conn} do
      {:ok, view, html} = live(conn, Routes.path("/profile/settings"))
      assert html =~ "API keys"

      assert {:ok, _view, page} =
               view
               |> element(~s(a[href="#{@path}"]))
               |> render_click()
               |> follow_redirect(conn, @path)

      assert page =~ "My API keys"
      refute page =~ "Email Address"
    end

    test "the tab is not offered to a person with neither permission" do
      {user, _role} = KeyTestSupport.user_without_api(["media"])
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

      {:ok, view, _html} = live(conn, Routes.path("/profile/settings"))

      refute has_element?(view, ~s(a[href="#{@path}"]))
    end
  end

  # ── Creating a key ─────────────────────────────────────────────────

  describe "creating a key" do
    test "shows the token once and makes a personal key", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, @path)
      assert html =~ "Keys: 0 of 5"

      html = open_create(view)
      assert html =~ "Create the key"

      refute has_element?(
               view,
               ~s(#personal-api-keys-create-form [name="key[requires_approval]"])
             )

      html = submit_create(view)
      token = new_token_in(html)

      assert token =~ ~r/\Apk_[0-9a-f]{8}_/
      assert has_element?(view, "#personal-api-keys-token-modal")

      assert [key] = keys_of(user)
      assert key.personal
      assert key.name == "Stock sync"
      assert key.scopes == [@read]
      refute key.requires_approval
      assert has_element?(view, "#personal-api-keys-key-#{key.uuid}", "Stock sync")

      assert {:ok, actor} = Keys.verify(token, nil)
      assert actor.user_uuid == user.uuid
    end

    test "the token is held in one assign and gone after it is dismissed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)
      token = view |> then(&submit_create/1) |> new_token_in()

      assert render(view) =~ token
      view |> element("#personal-api-keys-token-done") |> render_click()

      refute has_element?(view, "#personal-api-keys-token-modal")
      refute render(view) =~ token
    end

    test "a replayed create_key while the token waits makes no second key", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)
      token = view |> then(&submit_create/1) |> new_token_in()

      html = submit_create(view, %{"name" => "Second"})

      assert html =~ "That action is not available."
      assert length(keys_of(user)) == 1
      assert render(view) =~ token
    end

    test "the token never reaches the logs", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      {token, log} =
        capture_debug_log(fn ->
          open_create(view)
          token = view |> then(&submit_create/1) |> new_token_in()
          view |> element("#personal-api-keys-token-done") |> render_click()
          token
        end)

      [_pk, _prefix, secret] = String.split(token, "_", parts: 3)

      assert log =~ "create_key"
      refute log =~ token
      refute log =~ secret
    end

    test "a forged requires_approval does not reach the key", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)

      submit_create(view, %{"requires_approval" => "true"})

      assert [key] = keys_of(user)
      refute key.requires_approval
    end

    test "an expiry beyond the ceiling is refused and makes no key", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)
      too_far = Date.add(Date.utc_today(), PersonalKeysConfig.max_days() + 5)

      html = submit_create(view, %{"expires_on" => Date.to_iso8601(too_far)})

      # Named in the person's own date format, not as a raw changeset error.
      latest = PersonalKeyDisplay.expiry_date(PersonalKeysConfig.latest_expiry(), user)

      assert html =~ "The expiry date can be #{latest} at the latest."
      assert keys_of(user) == []
      assert has_element?(view, "#personal-api-keys-create-errors")
    end

    test "an empty or past expiry is refused", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)

      assert submit_create(view, %{"expires_on" => ""}) =~ "The expiry date is required."

      past = Date.to_iso8601(Date.add(Date.utc_today(), -3))

      assert submit_create(view, %{"expires_on" => past}) =~
               "The expiry date must be a date from today on."

      assert keys_of(user) == []
    end

    test "a scope the person cannot use is refused", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)

      html = submit_create(view, %{"scopes" => [@read, @run]})

      assert html =~ "Some of the chosen scopes are not available to you."
      assert keys_of(user) == []
    end

    test "create_key without an open form makes nothing", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)

      assert submit_create(view) =~ "That action is not available."
      assert keys_of(user) == []
    end

    test "the cap on live keys is told to the person", %{conn: conn, scope: scope, user: user} do
      KeyTestSupport.put_setting("api_personal_key_max_count", "1")
      personal!(scope)

      {:ok, view, html} = live(conn, @path)
      assert html =~ "Keys: 1 of 1"
      open_create(view)

      assert submit_create(view) =~ "largest number of keys"
      assert length(keys_of(user)) == 1
    end

    test "the form offers only the scopes the person can use", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)

      assert has_element?(view, ~s(#personal-api-keys-create-form input[value="#{@read}"]))
      refute has_element?(view, ~s(#personal-api-keys-create-form input[value="#{@run}"]))
      refute has_element?(view, ~s(#personal-api-keys-create-form input[value="#{@write}"]))
    end

    test "with no scope available the create button is disabled" do
      {user, _} = KeyTestSupport.user_without_api([@right])
      conn = log_in_user(Phoenix.ConnTest.build_conn(), user)

      {:ok, view, _html} = live(conn, @path)
      html = open_create(view)

      assert html =~ "No scopes are available to you"
      assert has_element?(view, "#personal-api-keys-create-submit[disabled]")
    end
  end

  # ── Revoke, rotate, edit scopes ────────────────────────────────────

  describe "managing a key" do
    setup %{scope: scope} do
      {key, token} = personal!(scope, %{scopes: [@read]})
      %{key: key, token: token}
    end

    defp menu_click(view, key, event) do
      view
      |> element(~s(#personal-api-keys-menu-#{key.uuid} button[phx-click="#{event}"]))
      |> render_click()
    end

    test "revoking asks first, then stops the key", %{conn: conn, key: key, token: token} do
      {:ok, view, _html} = live(conn, @path)
      menu_click(view, key, "request_revoke")
      assert has_element?(view, "#personal-api-keys-revoke-modal")
      assert Keys.get_key(key.uuid).revoked_at == nil

      view |> element("#personal-api-keys-revoke-confirm") |> render_click()

      assert Keys.get_key(key.uuid).revoked_at
      assert {:error, :revoked} = Keys.verify(token, nil)
      assert has_element?(view, "#personal-api-keys-key-#{key.uuid}", "Revoked")
    end

    test "cancelling a revoke leaves the key", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, @path)
      menu_click(view, key, "request_revoke")

      view
      |> element(~s(#personal-api-keys-revoke-modal button[phx-click="cancel_revoke"]))
      |> render_click()

      fire(view, "confirm_revoke")

      assert Keys.get_key(key.uuid).revoked_at == nil
    end

    test "rotating shows the new token once and keeps the old key for the grace period", %{
      conn: conn,
      key: key,
      token: old_token,
      user: user
    } do
      {:ok, view, _html} = live(conn, @path)
      menu_click(view, key, "request_rotate")

      html =
        view
        |> form("#personal-api-keys-rotate-form", %{"rotate" => %{"grace_hours" => "2"}})
        |> render_submit()

      new_token = new_token_in(html)
      assert new_token != old_token
      assert has_element?(view, "#personal-api-keys-token-modal")

      assert {:ok, _} = Keys.verify(old_token, nil)
      assert {:ok, _} = Keys.verify(new_token, nil)
      assert [_, _] = keys_of(user)
      assert Enum.all?(keys_of(user), & &1.personal)
      assert has_element?(view, "#personal-api-keys-key-#{key.uuid}", "Being replaced")
    end

    test "a replayed confirm_rotate rotates once", %{conn: conn, key: key, user: user} do
      {:ok, view, _html} = live(conn, @path)
      menu_click(view, key, "request_rotate")

      view
      |> form("#personal-api-keys-rotate-form", %{"rotate" => %{"grace_hours" => "1"}})
      |> render_submit()

      html = fire(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}})

      assert html =~ "That action is not available."
      assert length(keys_of(user)) == 2
    end

    test "a grace period outside 0..24 is refused", %{conn: conn, key: key, user: user} do
      {:ok, view, _html} = live(conn, @path)
      menu_click(view, key, "request_rotate")

      html = fire(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "99"}})

      assert html =~ "Give a whole number of hours from 0 to 24."
      assert length(keys_of(user)) == 1
    end

    test "at the limit the dialog starts at grace 0 and says why; a longer grace is refused", %{
      conn: conn,
      key: key,
      user: user
    } do
      KeyTestSupport.put_setting("api_personal_key_max_count", 1)
      {:ok, view, _html} = live(conn, @path)

      menu_click(view, key, "request_rotate")
      assert has_element?(view, "#personal-api-keys-rotate-at-limit")
      assert has_element?(view, ~s(#personal-api-keys-grace-hours option[value="0"][selected]))

      html = fire(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "2"}})

      assert html =~ "the old key cannot keep working next to the new one"
      assert [_only] = keys_of(user)
      assert Keys.get_key(key.uuid).revoked_at == nil

      menu_click(view, key, "request_rotate")
      view |> form("#personal-api-keys-rotate-form") |> render_submit()

      assert has_element?(view, "#personal-api-keys-token-modal")
      assert length(keys_of(user)) == 2
      assert Keys.get_key(key.uuid).revoked_at
    end

    test "below the limit the dialog starts at one hour, without the notice", %{
      conn: conn,
      key: key
    } do
      {:ok, view, _html} = live(conn, @path)

      menu_click(view, key, "request_rotate")
      refute has_element?(view, "#personal-api-keys-rotate-at-limit")
      assert has_element?(view, ~s(#personal-api-keys-grace-hours option[value="1"][selected]))
    end

    test "editing the scopes saves them", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, @path)
      menu_click(view, key, "request_edit_scopes")

      assert has_element?(
               view,
               ~s(#personal-api-keys-scopes-form input[value="#{@read}"][checked])
             )

      view
      |> element("#personal-api-keys-scopes-form")
      |> render_submit(%{"key_scopes" => %{"present" => "1", "scopes" => []}})

      assert Keys.get_key(key.uuid).scopes == []
    end

    test "a scope the person cannot use is refused when saving", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, @path)
      menu_click(view, key, "request_edit_scopes")

      html =
        fire(view, "save_key_scopes", %{"key_scopes" => %{"present" => "1", "scopes" => [@run]}})

      assert html =~ "Some of the chosen scopes are not available to you."
      assert Keys.get_key(key.uuid).scopes == [@read]
    end
  end

  # ── Forged input ───────────────────────────────────────────────────

  describe "forged input" do
    setup %{scope: scope} do
      {mine, _} = personal!(scope)
      stranger = stranger_key()
      owner = KeyTestSupport.owner_user()
      {owners, _} = personal!(KeyTestSupport.scope_of(owner))
      %{mine: mine, stranger: stranger, owners: owners}
    end

    for event <- ["request_revoke", "request_rotate", "request_edit_scopes"] do
      test "#{event} names a key of another person or of an Owner: no dialog", %{
        conn: conn,
        stranger: stranger,
        owners: owners
      } do
        {:ok, view, _html} = live(conn, @path)

        for key <- [stranger, owners] do
          html = fire(view, unquote(event), %{"uuid" => key.uuid})
          assert html =~ "That key was not found."
        end

        refute has_element?(view, "#personal-api-keys-revoke-modal")
        refute has_element?(view, "#personal-api-keys-rotate-modal")
        refute has_element?(view, "#personal-api-keys-scopes-modal")
      end
    end

    test "the confirming events take the key of the open dialog, not the params", %{
      conn: conn,
      mine: mine,
      stranger: stranger,
      owners: owners
    } do
      {:ok, view, _html} = live(conn, @path)
      menu_click_for(view, mine, "request_revoke")

      fire(view, "confirm_revoke", %{"uuid" => stranger.uuid})

      assert Keys.get_key(mine.uuid).revoked_at
      assert Keys.get_key(stranger.uuid).revoked_at == nil
      assert Keys.get_key(owners.uuid).revoked_at == nil
    end

    test "confirm events without an open dialog change nothing", %{
      conn: conn,
      mine: mine,
      stranger: stranger
    } do
      {:ok, view, _html} = live(conn, @path)

      fire(view, "confirm_revoke", %{"uuid" => mine.uuid})
      fire(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}, "uuid" => mine.uuid})

      fire(view, "save_key_scopes", %{
        "key_scopes" => %{"present" => "1", "scopes" => []},
        "uuid" => stranger.uuid
      })

      assert Keys.get_key(mine.uuid).revoked_at == nil
      assert Keys.get_key(mine.uuid).scopes == [@read]
      assert Keys.get_key(stranger.uuid).scopes == [@read]
      assert Repo.aggregate(from(k in Key, where: k.personal == true), :count) == 3
    end

    test "an unknown event is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      assert fire(view, "make_me_admin", %{}) =~ "That action is not available."
    end

    defp menu_click_for(view, key, event) do
      view
      |> element(~s(#personal-api-keys-menu-#{key.uuid} button[phx-click="#{event}"]))
      |> render_click()
    end
  end

  # ── A right lost in the middle of the session ──────────────────────

  describe "a right lost silently" do
    setup %{scope: scope} do
      {key, token} = personal!(scope)
      %{key: key, token: token}
    end

    defp assert_denied(html), do: assert(html =~ "You are not allowed to do that.")

    test "open_create and create_key", %{conn: conn, role: role, user: user} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)
      drop_right_silently!(role)

      assert_denied(submit_create(view, %{"name" => "Late"}))
      assert length(keys_of(user)) == 1
    end

    test "open_create alone", %{conn: conn, role: role} do
      {:ok, view, _html} = live(conn, @path)
      drop_right_silently!(role)

      assert_denied(fire(view, "open_create"))
      refute has_element?(view, "#personal-api-keys-create-form")
    end

    test "request_revoke and confirm_revoke", %{conn: conn, role: role, key: key} do
      {:ok, view, _html} = live(conn, @path)
      menu_click_for(view, key, "request_revoke")
      drop_right_silently!(role)

      assert_denied(fire(view, "confirm_revoke"))
      assert Keys.get_key(key.uuid).revoked_at == nil
    end

    test "request_revoke", %{conn: conn, role: role, key: key} do
      {:ok, view, _html} = live(conn, @path)
      drop_right_silently!(role)

      assert_denied(fire(view, "request_revoke", %{"uuid" => key.uuid}))
      refute has_element?(view, "#personal-api-keys-revoke-modal")
    end

    test "request_rotate and confirm_rotate", %{conn: conn, role: role, key: key, user: user} do
      {:ok, view, _html} = live(conn, @path)
      menu_click_for(view, key, "request_rotate")
      drop_right_silently!(role)

      assert_denied(fire(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}}))
      assert length(keys_of(user)) == 1
      assert Keys.get_key(key.uuid).revoked_at == nil
    end

    test "request_rotate", %{conn: conn, role: role, key: key} do
      {:ok, view, _html} = live(conn, @path)
      drop_right_silently!(role)

      assert_denied(fire(view, "request_rotate", %{"uuid" => key.uuid}))
      refute has_element?(view, "#personal-api-keys-rotate-modal")
    end

    test "request_edit_scopes and save_key_scopes", %{conn: conn, role: role, key: key} do
      {:ok, view, _html} = live(conn, @path)
      menu_click_for(view, key, "request_edit_scopes")
      drop_right_silently!(role)

      assert_denied(
        fire(view, "save_key_scopes", %{"key_scopes" => %{"present" => "1", "scopes" => []}})
      )

      assert Keys.get_key(key.uuid).scopes == [@read]
    end

    test "request_edit_scopes", %{conn: conn, role: role, key: key} do
      {:ok, view, _html} = live(conn, @path)
      drop_right_silently!(role)

      assert_denied(fire(view, "request_edit_scopes", %{"uuid" => key.uuid}))
      refute has_element?(view, "#personal-api-keys-scopes-modal")
    end
  end

  # ── A borrowed session ─────────────────────────────────────────────

  describe "a borrowed session" do
    setup %{conn: conn, scope: scope} do
      {key, _token} = personal!(scope)
      %{conn: borrowed(conn), key: key}
    end

    test "lists the keys, explains, and offers no action", %{conn: conn, key: key} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "You are acting in another account"
      assert has_element?(view, "#personal-api-keys-key-#{key.uuid}")
      refute has_element?(view, "#personal-api-keys-new-key")
      refute has_element?(view, "#personal-api-keys-menu-#{key.uuid}")
    end

    test "every changing event is refused on the server", %{conn: conn, key: key, user: user} do
      {:ok, view, _html} = live(conn, @path)

      events = [
        {"open_create", %{}},
        {"create_key", %{"key" => create_params()}},
        {"request_revoke", %{"uuid" => key.uuid}},
        {"confirm_revoke", %{}},
        {"request_rotate", %{"uuid" => key.uuid}},
        {"confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}}},
        {"request_edit_scopes", %{"uuid" => key.uuid}},
        {"save_key_scopes", %{"key_scopes" => %{"present" => "1", "scopes" => []}}}
      ]

      for {event, params} <- events do
        html = fire(view, event, params)
        assert html =~ "cannot be changed while you act in another account", event
      end

      assert [only] = keys_of(user)
      assert only.uuid == key.uuid
      assert only.revoked_at == nil
      assert only.scopes == [@read]
    end
  end

  # ── The API switched off ───────────────────────────────────────────

  describe "the API switched off" do
    setup %{scope: scope} do
      {key, _token} = personal!(scope)
      KeyTestSupport.put_setting("api_admin_enabled", "false")
      %{key: key}
    end

    test "the list stays, with an explanation and no create button", %{conn: conn, key: key} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "The API is switched off by an administrator."
      assert has_element?(view, "#personal-api-keys-key-#{key.uuid}")
      refute has_element?(view, "#personal-api-keys-new-key")

      refute has_element?(
               view,
               ~s(#personal-api-keys-menu-#{key.uuid} button[phx-click="request_rotate"])
             )
    end

    test "creating and rotating are refused on the server", %{conn: conn, key: key, user: user} do
      {:ok, view, _html} = live(conn, @path)

      assert fire(view, "open_create") =~ "switched off"
      assert submit_create(view) =~ "That action is not available."

      assert fire(view, "request_rotate", %{"uuid" => key.uuid}) =~
               "That action is not available."

      fire(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}})

      assert length(keys_of(user)) == 1
    end

    test "revoking and editing the scopes still work", %{conn: conn, key: key} do
      {:ok, view, _html} = live(conn, @path)

      menu_click_for(view, key, "request_edit_scopes")

      view
      |> element("#personal-api-keys-scopes-form")
      |> render_submit(%{"key_scopes" => %{"present" => "1", "scopes" => []}})

      assert Keys.get_key(key.uuid).scopes == []

      menu_click_for(view, key, "request_revoke")
      view |> element("#personal-api-keys-revoke-confirm") |> render_click()

      assert Keys.get_key(key.uuid).revoked_at
    end
  end

  # ── What the list shows ────────────────────────────────────────────

  describe "the list" do
    test "tells the status of each key", %{conn: conn, scope: scope} do
      {soon, _} = personal!(scope, %{name: "Soon", expires_at: end_of_day(3)})
      {later, _} = personal!(scope, %{name: "Later", expires_at: end_of_day(30)})

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#personal-api-keys-key-#{soon.uuid}", "Expires soon")
      assert has_element?(view, "#personal-api-keys-key-#{later.uuid}", "Active")
      refute has_element?(view, "#personal-api-keys-key-#{later.uuid}", "Expires soon")
    end

    test "shows how to connect, with a placeholder and never a real key", %{conn: conn} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "Authorization: Bearer &lt;your key&gt;"
      assert has_element?(view, "#personal-api-keys-rest-url", "/api/admin/v1")
      assert has_element?(view, "#personal-api-keys-mcp-url", "/mcp/admin")
      assert html =~ "The key acts only with your rights; do not give it to other people."
    end
  end

  # ── Review fixes (stage 2a) ────────────────────────────────────────

  describe "dates and statuses" do
    test "Created and Expires on: the expiry is the day the form named, east of UTC too", %{
      conn: conn,
      scope: scope,
      user: user
    } do
      {1, _} =
        Repo.update_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid),
          set: [user_timezone: "+10"]
        )

      {key, _} = personal!(scope, %{expires_at: end_of_day(30)})
      {:ok, view, _html} = live(conn, @path)

      expires_on = Date.to_iso8601(Date.add(Date.utc_today(), 30))
      next_day = Date.to_iso8601(Date.add(Date.utc_today(), 31))
      created = DateTime.utc_now() |> DateTime.add(10 * 3600) |> DateTime.to_date()

      row = "#personal-api-keys-key-#{key.uuid}"
      assert has_element?(view, row, expires_on)
      refute has_element?(view, row, next_day)
      assert has_element?(view, row, Date.to_iso8601(created))
    end

    test "a key being replaced offers no Rotate and says so when asked", %{
      conn: conn,
      scope: scope
    } do
      {key, _} = personal!(scope)
      {:ok, _new, _token} = Keys.rotate(key, 2, scope, impersonated: false)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#personal-api-keys-menu-#{key.uuid}")

      refute has_element?(
               view,
               ~s(#personal-api-keys-menu-#{key.uuid} button[phx-click="request_rotate"])
             )

      html = fire(view, "request_rotate", %{"uuid" => key.uuid})
      assert html =~ "This key is already being replaced."
      refute html =~ "That key was not found."
      refute has_element?(view, "#personal-api-keys-rotate-modal")
    end

    test "the counter has no number in the phrase's grammar", %{conn: conn, scope: scope} do
      personal!(scope)
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#personal-api-keys-counter", "Keys: 1 of")
    end
  end

  describe "the create form" do
    test "text fields are debounced, and the date has a floor and a ceiling", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)

      for field <- ["name", "allowed-ips"] do
        assert has_element?(view, ~s(#personal-api-keys-key-#{field}[phx-debounce="300"]))
      end

      html = render(view)
      assert html =~ ~s(min="#{Date.to_iso8601(Date.utc_today())}")

      assert html =~
               ~s(max="#{Date.to_iso8601(Date.add(Date.utc_today(), PersonalKeysConfig.max_days()))}")
    end

    test "typing keeps the form open and its values", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)

      html = fire(view, "create_form_changed", %{"key" => create_params(%{"name" => "Typed"})})

      assert html =~ ~s(value="Typed")
      assert has_element?(view, "#personal-api-keys-create-form")
    end

    test "a forged create_form_changed does not open a closed form", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      fire(view, "create_form_changed", %{"key" => create_params()})

      refute has_element?(view, "#personal-api-keys-create-form")
    end

    test "a changeset error names the field with its label", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)

      html = submit_create(view, %{"name" => String.duplicate("x", 5000)})

      assert has_element?(view, "#personal-api-keys-create-errors")
      assert html =~ "Name: "
      refute html =~ "name: "
      assert keys_of(user) == []
    end
  end

  describe "refusals and messages" do
    test "a refusal closes the open dialog so the message is seen", %{
      conn: conn,
      role: role
    } do
      {:ok, view, _html} = live(conn, @path)
      open_create(view)
      assert has_element?(view, "#personal-api-keys-create-form")

      drop_right_silently!(role)
      assert_message = submit_create(view)

      assert assert_message =~ "You are not allowed to do that."
      refute has_element?(view, "#personal-api-keys-create-form")
      assert has_element?(view, "#personal-api-keys-message", "not allowed")
    end

    test "the message area is a live region, an error is an alert", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      fire(view, "make_me_admin", %{})

      assert has_element?(view, ~s(#personal-api-keys-messages[aria-live="polite"]))
      assert has_element?(view, ~s(#personal-api-keys-message[role="alert"]))
    end

    test "a success message is a status", %{conn: conn, scope: scope} do
      {key, _} = personal!(scope)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element(~s(#personal-api-keys-menu-#{key.uuid} button[phx-click="request_revoke"]))
      |> render_click()

      view |> element("#personal-api-keys-revoke-confirm") |> render_click()

      assert has_element?(view, ~s(#personal-api-keys-message[role="status"]))
    end

    test "opening a dialog clears the old message", %{conn: conn, scope: scope} do
      {key, _} = personal!(scope)
      {:ok, view, _html} = live(conn, @path)

      fire(view, "make_me_admin", %{})
      assert has_element?(view, "#personal-api-keys-message")

      view
      |> element(~s(#personal-api-keys-menu-#{key.uuid} button[phx-click="request_edit_scopes"]))
      |> render_click()

      refute has_element?(view, "#personal-api-keys-message")

      fire(view, "make_me_admin", %{})
      open_create(view)
      refute has_element?(view, "#personal-api-keys-message")
    end

    test "the revoke confirmation is a core button", %{conn: conn, scope: scope} do
      {key, _} = personal!(scope)
      {:ok, view, _html} = live(conn, @path)

      view
      |> element(~s(#personal-api-keys-menu-#{key.uuid} button[phx-click="request_revoke"]))
      |> render_click()

      assert has_element?(view, "#personal-api-keys-revoke-confirm.btn.btn-error")
    end
  end

  describe "an api holder's own non-personal key" do
    test "is not on the page and cannot be reached by uuid" do
      {holder, _role} = KeyTestSupport.user_with(["media"])
      holder_scope = KeyTestSupport.scope_of(holder)
      {plain, _token} = KeyTestSupport.issue_key!(holder, [@read], %{name: "Plain holder key"})
      assert plain.personal == false

      conn = log_in_user(Phoenix.ConnTest.build_conn(), holder)
      {:ok, view, html} = live(conn, @path)

      refute html =~ plain.name
      refute has_element?(view, "#personal-api-keys-key-#{plain.uuid}")

      for event <- ["request_revoke", "request_rotate", "request_edit_scopes"] do
        assert fire(view, event, %{"uuid" => plain.uuid}) =~ "That key was not found."
      end

      fire(view, "confirm_revoke", %{"uuid" => plain.uuid})

      after_events = Keys.get_key(plain.uuid)
      assert after_events.revoked_at == nil
      assert after_events.scopes == [@read]
      assert holder_scope.user.uuid == after_events.user_uuid
    end
  end
end
