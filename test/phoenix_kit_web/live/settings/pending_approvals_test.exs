defmodule PhoenixKitWeb.Live.Settings.PendingApprovalsTest do
  @moduledoc """
  The block "Waiting for approval" of the OAuth tab of Settings -> API
  (`PhoenixKitWeb.Live.Components.PendingApprovals`): an Owner sees the connections of
  applications that are not on the list of trusted ones, approves or rejects each through a
  confirmation dialog, and nobody else sees or decides anything. The rights are read again at every
  render and every event, the dialog holds the uuid, and a borrowed session decides nothing.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.Users.Auth, as: AuthCtx
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api?tab=oauth")
  @block "#api-oauth-pending-approvals"

  setup do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    enable_oauth!()

    {user, _role, scope} = oauth_holder(["media"])
    client = client!(%{client_name: "Agent One"})
    seeded = seed_grant!(scope, client: client, approved?: false)
    %{user: user, scope: scope, client: client, seeded: seeded}
  end

  defp owner_view(%{} = _ctx, owner \\ nil) do
    conn =
      log_in_user(Phoenix.ConnTest.build_conn(), owner || KeyTestSupport.owner_user())

    {:ok, view, _html} = live(conn, @path)
    view
  end

  defp fire(view, event, params \\ %{}),
    do: view |> with_target(@block) |> render_hook(event, params)

  defp row(seeded), do: "#{@block}-grant-#{seeded.grant.uuid}"

  defp grant(seeded), do: Repo.get!(Grant, seeded.grant.uuid)

  describe "the block" do
    test "shows the waiting connection: the name, whose account, the rights, the count", ctx do
      view = owner_view(ctx)

      assert has_element?(view, "#{@block}-card")
      assert has_element?(view, row(ctx.seeded))
      assert has_element?(view, "#{row(ctx.seeded)}", "Agent One")
      assert has_element?(view, "#{row(ctx.seeded)}", ctx.user.email)
      assert has_element?(view, "#{@block}-unverified-#{ctx.seeded.grant.uuid}")
      assert has_element?(view, "#{@block}-hosts-#{ctx.seeded.grant.uuid}", "client.example")
      assert has_element?(view, "#{@block}-count", "1")
      assert has_element?(view, "#{@block}-approve-#{ctx.seeded.grant.uuid}")
      assert has_element?(view, "#{@block}-reject-#{ctx.seeded.grant.uuid}")
    end

    test "names the host of the metadata document of an application that has one", ctx do
      client =
        client!(%{client_id: "https://docs.agent.example/client.json", client_name: "Cimd One"})

      client |> Ecto.Changeset.change(kind: "cimd") |> Repo.update!()
      other = seed_grant!(ctx.scope, client: client, approved?: false)

      view = owner_view(ctx)
      assert has_element?(view, "#{@block}-described-#{other.grant.uuid}", "docs.agent.example")
      refute has_element?(view, "#{@block}-described-#{ctx.seeded.grant.uuid}")
    end

    test "leaves out an approved connection and says so when nothing waits", ctx do
      {:ok, _} =
        Grants.approve(
          KeyTestSupport.scope_of(KeyTestSupport.owner_user()),
          ctx.seeded.grant.uuid
        )

      view = owner_view(ctx)
      refute has_element?(view, row(ctx.seeded))
      refute has_element?(view, "#{@block}-count")
      assert has_element?(view, "#{@block}-empty")
    end

    test "is not shown to an administrator who is not an Owner", %{conn: conn} do
      {admin, _token} = create_admin_user()
      role = Roles.get_role_by_name("Admin")
      for key <- ["api", "media"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

      {:ok, view, _html} = live(log_in_user(conn, admin), @path)
      refute has_element?(view, @block)
    end

    test "the status of the tab warns that connections wait", ctx do
      view = owner_view(ctx)
      assert has_element?(view, "#api-oauth-warning-approvals_waiting")
    end

    test "the list of every connection shows the same one as waiting", ctx do
      view = owner_view(ctx)

      assert has_element?(
               view,
               "#api-oauth-connected-apps-status-#{ctx.seeded.grant.uuid}[data-status=awaiting_approval]"
             )

      assert has_element?(view, "#api-oauth-connected-apps-awaiting-#{ctx.seeded.grant.uuid}")
    end
  end

  describe "approving" do
    test "asks first, then approves; the same access token works, the lists follow", ctx do
      view = owner_view(ctx)

      view |> element("#{@block}-approve-#{ctx.seeded.grant.uuid}") |> render_click()
      assert has_element?(view, "#{@block}-approve-warning")
      assert grant(ctx.seeded).approved_at == nil

      view |> element("#{@block}-decision-confirm") |> render_click()

      assert %DateTime{} = grant(ctx.seeded).approved_at
      refute has_element?(view, row(ctx.seeded))
      assert has_element?(view, "#{@block}-message")
      assert has_element?(view, "#{@block}-empty")
      refute has_element?(view, "#api-oauth-warning-approvals_waiting")

      assert has_element?(
               view,
               "#api-oauth-connected-apps-status-#{ctx.seeded.grant.uuid}[data-status=active]"
             )

      assert {:ok, %{awaiting_approval: false}} = Tokens.verify(ctx.seeded.access, "203.0.113.9")

      assert [entry] = Activity.list(action: "oauth.grant_approved").entries
      assert entry.resource_uuid == ctx.seeded.grant.uuid
    end

    test "a second confirm, with no dialog open, does nothing", ctx do
      view = owner_view(ctx)
      view |> element("#{@block}-approve-#{ctx.seeded.grant.uuid}") |> render_click()
      view |> element("#{@block}-decision-confirm") |> render_click()

      fire(view, "confirm_decision")
      refute has_element?(view, "#{@block}-message[role=alert]")
      assert [_one] = Activity.list(action: "oauth.grant_approved").entries
    end

    test "a connection ended before the confirm is not approved", ctx do
      view = owner_view(ctx)
      view |> element("#{@block}-approve-#{ctx.seeded.grant.uuid}") |> render_click()

      {:ok, _} = Grants.revoke(ctx.seeded.grant)
      view |> element("#{@block}-decision-confirm") |> render_click()

      assert grant(ctx.seeded).approved_at == nil
      assert has_element?(view, "#{@block}-message[role=alert]")
      assert Activity.list(action: "oauth.grant_approved").entries == []
    end

    test "a forged uuid opens no dialog and approves nothing", ctx do
      view = owner_view(ctx)

      html = fire(view, "request_approve", %{"uuid" => Ecto.UUID.generate()})
      assert html =~ "not waiting for approval any more"

      fire(view, "request_approve", %{"uuid" => "nope"})
      fire(view, "confirm_decision")
      assert grant(ctx.seeded).approved_at == nil
    end

    test "the uuid of the confirm is the one of the dialog: a param of the event changes nothing",
         ctx do
      other = seed_grant!(ctx.scope, approved?: false)
      view = owner_view(ctx)

      view |> element("#{@block}-approve-#{ctx.seeded.grant.uuid}") |> render_click()
      fire(view, "confirm_decision", %{"uuid" => other.grant.uuid})

      assert %DateTime{} = grant(ctx.seeded).approved_at
      assert grant(other).approved_at == nil
    end
  end

  describe "rejecting" do
    test "asks first, then ends the connection with its key and tokens", ctx do
      view = owner_view(ctx)

      view |> element("#{@block}-reject-#{ctx.seeded.grant.uuid}") |> render_click()
      assert has_element?(view, "#{@block}-reject-warning")
      assert grant(ctx.seeded).revoked_at == nil

      view |> element("#{@block}-decision-confirm") |> render_click()

      assert %DateTime{} = grant(ctx.seeded).revoked_at
      assert %DateTime{} = Repo.get!(Key, ctx.seeded.key.uuid).revoked_at
      assert {:error, _} = Tokens.verify(ctx.seeded.access, "203.0.113.9")
      refute has_element?(view, row(ctx.seeded))

      assert [entry] =
               Enum.filter(
                 Activity.list(action: "oauth.grant_revoked").entries,
                 &(&1.resource_uuid == ctx.seeded.grant.uuid)
               )

      assert entry.metadata["reason"] == "approval_rejected"
    end

    test "cancelling the dialog changes nothing", ctx do
      view = owner_view(ctx)
      view |> element("#{@block}-reject-#{ctx.seeded.grant.uuid}") |> render_click()
      fire(view, "cancel_decision")

      assert grant(ctx.seeded).revoked_at == nil
      assert has_element?(view, row(ctx.seeded))
    end
  end

  describe "rights" do
    test "an Owner demoted to Admin before confirming decides nothing", ctx do
      owner = KeyTestSupport.owner_user()
      view = owner_view(ctx, owner)
      view |> element("#{@block}-approve-#{ctx.seeded.grant.uuid}") |> render_click()

      {:ok, _} = Roles.remove_role(owner, "Owner", broadcast: false)
      {:ok, _} = Roles.assign_role(owner, "Admin", nil, broadcast: false)

      html = fire(view, "confirm_decision")

      assert html =~ "You are not allowed to do that."
      assert grant(ctx.seeded).approved_at == nil
      refute has_element?(view, row(ctx.seeded))
    end

    test "an unknown event is refused", ctx do
      view = owner_view(ctx)
      assert fire(view, "approve_all", %{}) =~ "That action is not available."
      assert grant(ctx.seeded).approved_at == nil
    end
  end

  describe "a borrowed session" do
    test "shows the rows but decides nothing", ctx do
      owner = KeyTestSupport.owner_user()
      {root, _role} = KeyTestSupport.user_without_api(["api"])
      root_token = AuthCtx.generate_user_session_token(root)

      conn = log_in_user(Phoenix.ConnTest.build_conn(), owner)
      active_token = Plug.Conn.get_session(conn, :user_token)
      conn = Plug.Conn.put_session(conn, :pk_session_accounts, [root_token, active_token])

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, row(ctx.seeded))
      refute has_element?(view, "#{@block}-approve-#{ctx.seeded.grant.uuid}")

      for event <- ["request_approve", "request_reject"] do
        html = fire(view, event, %{"uuid" => ctx.seeded.grant.uuid})
        assert html =~ "while you act in another account", event
      end

      fire(view, "confirm_decision")
      assert grant(ctx.seeded).approved_at == nil
      assert grant(ctx.seeded).revoked_at == nil
    end
  end
end
