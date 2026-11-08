defmodule PhoenixKit.Integration.Users.MultiSessionTest do
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Activity
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.Users.MultiSession

  defp unique_email, do: "ms_#{System.unique_integer([:positive])}@example.com"

  defp owner_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)

    # `Roles.assign_role/3` deliberately refuses to assign the Owner role
    # (`:owner_role_protected`) — Owner is only ever bootstrapped onto the first
    # user. Insert the assignment directly so this helper deterministically
    # yields an Owner regardless of user-creation order. `on_conflict: :nothing`
    # covers the case where this IS the first user and already got Owner.
    owner_role = Roles.get_role_by_name("Owner")

    {:ok, _} =
      %RoleAssignment{}
      |> RoleAssignment.changeset(%{
        user_uuid: user.uuid,
        role_uuid: owner_role.uuid
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:user_uuid, :role_uuid]
      )

    Repo.get!(Auth.User, user.uuid)
  end

  defp plain_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  defp custom_role_user(role_name) do
    {:ok, role} =
      Repo.insert(%PhoenixKit.Users.Role{
        name: role_name,
        description: role_name,
        is_system_role: false
      })

    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  # Build a conn whose root (active) account is `user`, logged in like log_in_user.
  defp conn_for(user) do
    token = Auth.generate_user_session_token(user)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
    |> Plug.Conn.put_session(:pk_session_accounts, [token])
  end

  # The FIRST user registered in a fresh sandbox auto-becomes Owner
  # (`Auth.register_user` → `Roles.ensure_first_user_is_owner`, which only
  # promotes when no active Owner exists yet). Seed a throwaway Owner up front so
  # the users each test builds get their INTENDED roles (plain "User" / a custom
  # role / an explicit Owner via `owner_user/0`) instead of being silently
  # promoted to Owner just for being the first account created.
  setup do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, _} = Auth.admin_confirm_user(seed)
    :ok
  end

  describe "add_account/3" do
    test "appends a real account and makes it active" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)

      assert {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      session = Plug.Conn.get_session(conn)
      assert length(session["pk_session_accounts"]) == 2
      # active token now resolves to the added user
      assert Auth.get_user_by_session_token(session["user_token"]).uuid == other.uuid
      # root unchanged
      [root_token | _] = session["pk_session_accounts"]
      assert Auth.get_user_by_session_token(root_token).uuid == owner.uuid
    end

    test "rejects invalid credentials, stack unchanged" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)

      assert {:error, :invalid_credentials} =
               MultiSession.add_account(conn, other.email, "wrong-password")

      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "rejects when the stack is full" do
      owner = owner_user()
      conn = conn_for(owner)

      conn =
        Enum.reduce(1..(MultiSession.max_accounts() - 1), conn, fn _, acc ->
          u = plain_user()
          {:ok, acc} = MultiSession.add_account(acc, u.email, "ValidPassword123!")
          acc
        end)

      full = plain_user()

      assert {:error, :stack_full} =
               MultiSession.add_account(conn, full.email, "ValidPassword123!")
    end
  end

  describe "switch_to/2" do
    test "is logged without a target, so nobody is notified of their own switch" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      [_root, added] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert {:ok, _conn, _user} = MultiSession.switch_to(conn, added.ref)

      assert %{entries: [entry]} =
               Activity.list(action: "session.switched", resource_uuid: other.uuid)

      assert entry.resource_uuid == other.uuid
      assert is_nil(entry.target_uuid)
    end

    test "activates a token already in the stack by ref" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      [root | _] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert {:ok, conn, user} = MultiSession.switch_to(conn, root.ref)
      assert user.uuid == owner.uuid

      assert Auth.get_user_by_session_token(Plug.Conn.get_session(conn)["user_token"]).uuid ==
               owner.uuid
    end

    test "rejects a ref not in the stack" do
      owner = owner_user()
      conn = conn_for(owner)
      assert {:error, :not_in_stack} = MultiSession.switch_to(conn, Ecto.UUID.generate())
    end
  end

  describe "remove_account/2" do
    test "deletes a non-root token from DB and stack" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      accounts = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      added = Enum.find(accounts, &(not &1.root?))
      added_token = Enum.at(Plug.Conn.get_session(conn)["pk_session_accounts"], 1)

      assert {:ok, conn} = MultiSession.remove_account(conn, added.ref)
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
      assert is_nil(Auth.get_user_by_session_token(added_token))
      # active fell back to root
      assert Auth.get_user_by_session_token(Plug.Conn.get_session(conn)["user_token"]).uuid ==
               owner.uuid
    end

    test "refuses to remove the root account" do
      owner = owner_user()
      conn = conn_for(owner)
      [root | _] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert {:error, :cannot_remove_root} = MultiSession.remove_account(conn, root.ref)
    end
  end

  describe "log_out_active/1 and delete_all_stack_tokens/1" do
    test "log_out_active switches to root when a non-root account is active" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      added_token = Plug.Conn.get_session(conn)["user_token"]

      assert {:switched, conn, user} = MultiSession.log_out_active(conn)
      assert user.uuid == owner.uuid
      assert is_nil(Auth.get_user_by_session_token(added_token))
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "log_out_active returns :full when the root account is active" do
      owner = owner_user()
      conn = conn_for(owner)
      assert {:full, _conn} = MultiSession.log_out_active(conn)
    end

    test "delete_all_stack_tokens deletes every token in the stack" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      tokens = Plug.Conn.get_session(conn)["pk_session_accounts"]

      _conn = MultiSession.delete_all_stack_tokens(conn)
      assert Enum.all?(tokens, &is_nil(Auth.get_user_by_session_token(&1)))
    end
  end

  # --- Change 1: role_label shows real role name ---

  describe "list_accounts/1 role labels" do
    test "owner account shows 'Owner'" do
      owner = owner_user()
      conn = conn_for(owner)
      [account] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert account.role == "Owner"
    end

    test "plain user account shows 'User'" do
      user = plain_user()
      conn = conn_for(user)
      [account] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert account.role == "User"
    end

    test "custom-role user is labelled with the actual role name, not 'Admin'" do
      # A custom role with no explicit permissions — admin?/1 would return false,
      # but it might return true if permissions were seeded. The real fix is that we
      # no longer call admin?/1 at all — we read cached_roles directly.
      user = custom_role_user("Manager")
      conn = conn_for(user)
      [account] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      # Must show the real role name, not "Admin" or "User"
      assert account.role == "Manager"
      refute account.role == "Admin"
    end
  end

  # --- Change 2: gate_allowed? for any authenticated user ---

  describe "gate_allowed?/1" do
    test "returns false when multi_session_enabled setting is off" do
      Settings.update_boolean_setting("multi_session_enabled", false)
      owner = owner_user()
      conn = conn_for(owner)
      refute MultiSession.gate_allowed?(Plug.Conn.get_session(conn))
    end

    test "returns true for a plain (non-admin) authenticated user when setting is on" do
      Settings.update_boolean_setting("multi_session_enabled", true)
      user = plain_user()
      conn = conn_for(user)
      assert MultiSession.gate_allowed?(Plug.Conn.get_session(conn))
    end

    test "returns true for an owner when setting is on" do
      Settings.update_boolean_setting("multi_session_enabled", true)
      owner = owner_user()
      conn = conn_for(owner)
      assert MultiSession.gate_allowed?(Plug.Conn.get_session(conn))
    end

    test "returns false when there is no root user token (anonymous)" do
      Settings.update_boolean_setting("multi_session_enabled", true)

      empty_session =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.get_session()

      refute MultiSession.gate_allowed?(empty_session)
    end
  end

  # --- Change 3: add_authenticated_user/2 stack-append path ---

  describe "add_authenticated_user/2" do
    test "appends an active user to the stack and makes them active" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)

      assert {:ok, conn} = MultiSession.add_authenticated_user(conn, other)

      session = Plug.Conn.get_session(conn)
      assert length(session["pk_session_accounts"]) == 2
      assert Auth.get_user_by_session_token(session["user_token"]).uuid == other.uuid
      [root_token | _] = session["pk_session_accounts"]
      assert Auth.get_user_by_session_token(root_token).uuid == owner.uuid
    end

    test "rejects when the account is already in the stack" do
      owner = owner_user()
      conn = conn_for(owner)

      # Add the same user a second time via add_authenticated_user
      assert {:ok, conn} = MultiSession.add_authenticated_user(conn, plain_user())
      added = plain_user()
      # Force a second call with the same user object (reuse owner)
      assert {:ok, conn_with_two} = MultiSession.add_authenticated_user(conn, added)

      assert {:error, :already_in_stack} =
               MultiSession.add_authenticated_user(conn_with_two, added)
    end

    test "rejects when the stack is full" do
      owner = owner_user()
      conn = conn_for(owner)

      conn =
        Enum.reduce(1..(MultiSession.max_accounts() - 1), conn, fn _, acc ->
          {:ok, acc} = MultiSession.add_authenticated_user(acc, plain_user())
          acc
        end)

      assert {:error, :stack_full} = MultiSession.add_authenticated_user(conn, plain_user())
    end

    test "rejects an inactive user" do
      owner = owner_user()
      conn = conn_for(owner)

      {:ok, inactive} =
        Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})

      # inactive user (not confirmed, is_active false by default until confirmed)
      # Deactivate explicitly
      inactive = %{inactive | is_active: false}

      assert {:error, :inactive} = MultiSession.add_authenticated_user(conn, inactive)
    end
  end

  describe "impersonate/2" do
    defp admin_user do
      {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
      {:ok, user} = Auth.admin_confirm_user(user)
      Roles.assign_role(user, "Admin")
      Repo.get!(Auth.User, user.uuid)
    end

    test "an admin can take a plain user's account without their password" do
      admin = admin_user()
      target = plain_user()

      assert {:ok, conn} = MultiSession.impersonate(conn_for(admin), target)

      accounts = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert length(accounts) == 2
      assert Enum.find(accounts, & &1.active?).email == target.email
      # the admin's own account stays, and stays the root
      assert Enum.find(accounts, & &1.root?).email == admin.email
      assert MultiSession.impersonated?(Plug.Conn.get_session(conn))
      refute MultiSession.impersonated?(Plug.Conn.get_session(conn_for(admin)))
    end

    test "the Owner account is never a target" do
      assert {:error, :target_is_owner} =
               MultiSession.impersonate(conn_for(admin_user()), owner_user())
    end

    test "an admin cannot take another admin — that is sideways, not support" do
      assert {:error, :target_is_staff} =
               MultiSession.impersonate(conn_for(admin_user()), admin_user())
    end

    test "an owner can take an admin, because there is nothing above it to reach" do
      assert {:ok, _conn} = MultiSession.impersonate(conn_for(owner_user()), admin_user())
    end

    test "a permission holder who is not staff cannot impersonate at all" do
      # The hole this guards: `can_access_admin_area?/1` is true for ANY
      # permission holder, so a customer granted one self-service permission
      # would qualify under a permission-based check and could borrow another
      # customer's account. The rule is role-based for exactly this reason.
      assert {:error, :not_allowed} =
               MultiSession.impersonate(conn_for(custom_role_user("Client")), plain_user())
    end

    test "an anonymous session cannot impersonate" do
      conn = Phoenix.ConnTest.build_conn() |> Phoenix.ConnTest.init_test_session(%{})
      assert {:error, :not_allowed} = MultiSession.impersonate(conn, plain_user())
    end

    test "taking your own account is refused rather than duplicated" do
      admin = admin_user()
      assert {:error, :self} = MultiSession.impersonate(conn_for(admin), admin)
    end

    test "the same account cannot be taken twice" do
      admin = admin_user()
      target = plain_user()

      assert {:ok, conn} = MultiSession.impersonate(conn_for(admin), target)
      assert {:error, :already_in_stack} = MultiSession.impersonate(conn, target)
    end

    test "a deactivated account is refused" do
      target = plain_user()
      {:ok, target} = Auth.update_user_status(target, %{"is_active" => false})

      assert {:error, :inactive} = MultiSession.impersonate(conn_for(admin_user()), target)
    end
  end

  # The predicates the admin menus are built on. Their whole job is to agree
  # with `impersonate/2` — an offer the POST refuses is a support tool that
  # lies, and a hidden offer the POST would have allowed is a missing feature.
  describe "impersonable?/2 and impersonable_uuids/2" do
    test "answer the same way impersonate/2 does, target by target" do
      admin = admin_user()
      owner = owner_user()
      other_admin = admin_user()
      plain = plain_user()

      assert MultiSession.impersonable?(admin, plain)
      refute MultiSession.impersonable?(admin, owner)
      refute MultiSession.impersonable?(admin, other_admin)
      refute MultiSession.impersonable?(admin, admin)
      assert MultiSession.impersonable?(owner, other_admin)

      # Not staff by role — the case `can_access_admin_area?/1` would have let
      # through. Same rule as the `impersonate/2` test above.
      refute MultiSession.impersonable?(custom_role_user("Client"), plain)
      refute MultiSession.impersonable?(nil, plain)
    end

    test "a deactivated target is not offered, because the POST would refuse it" do
      target = plain_user()
      {:ok, target} = Auth.update_user_status(target, %{"is_active" => false})
      admin = admin_user()

      refute MultiSession.impersonable?(admin, target)
      assert {:error, :inactive} = MultiSession.impersonate(conn_for(admin), target)

      refute target.uuid in MultiSession.impersonable_uuids(admin, [target])
    end

    test "impersonable_uuids/2 decides a list the same way impersonable?/2 decides one" do
      admin = admin_user()
      users = [owner_user(), admin_user(), plain_user(), custom_role_user("Client"), admin]

      uuids = MultiSession.impersonable_uuids(admin, users)

      for user <- users do
        assert user.uuid in uuids == MultiSession.impersonable?(admin, user),
               "list and single-target answers disagree for #{user.email}"
      end
    end

    test "impersonable_uuids/2 reads a preloaded :roles instead of querying" do
      admin = admin_user()
      target = Auth.get_user_with_roles(plain_user().uuid)

      assert is_list(target.roles)
      assert target.uuid in MultiSession.impersonable_uuids(admin, [target])
    end

    test "no actor means nothing is offered" do
      assert MultiSession.impersonable_uuids(nil, [plain_user()]) == MapSet.new()
    end
  end

  describe "impersonation_actor/1" do
    test "is the ROOT account, not whichever account is active" do
      Settings.update_boolean_setting("multi_session_enabled", true)
      admin = admin_user()
      target = plain_user()

      {:ok, conn} = MultiSession.impersonate(conn_for(admin), target)

      # Active is now the borrowed account; the actor stays the admin who
      # opened the stack, so a menu rendered from here still judges by them.
      actor = MultiSession.impersonation_actor(Plug.Conn.get_session(conn))
      assert actor.uuid == admin.uuid
    end

    test "is nil when multi-account switching is off, so the menus offer nothing" do
      Settings.update_boolean_setting("multi_session_enabled", false)
      admin = admin_user()
      conn = conn_for(admin)

      assert MultiSession.impersonation_actor(Plug.Conn.get_session(conn)) == nil

      assert MultiSession.impersonable_uuids(
               MultiSession.impersonation_actor(Plug.Conn.get_session(conn)),
               [plain_user()]
             ) == MapSet.new()
    end

    test "is nil for an anonymous session" do
      Settings.update_boolean_setting("multi_session_enabled", true)

      session =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.get_session()

      assert MultiSession.impersonation_actor(session) == nil
    end
  end

  describe "impersonated?/1 — own accounts and borrowed ones" do
    defp staff_user do
      {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
      {:ok, user} = Auth.admin_confirm_user(user)
      Roles.assign_role(user, "Admin")
      Repo.get!(Auth.User, user.uuid)
    end

    defp borrowed?(conn), do: MultiSession.impersonated?(Plug.Conn.get_session(conn))

    test "an account added with its own password is the user's, not borrowed" do
      {:ok, conn} =
        MultiSession.add_account(conn_for(plain_user()), plain_user().email, "ValidPassword123!")

      refute borrowed?(conn)
    end

    test "an account added through OAuth is the user's too" do
      {:ok, conn} = MultiSession.add_authenticated_user(conn_for(plain_user()), plain_user())
      refute borrowed?(conn)
    end

    test "an impersonation stays borrowed, beside the user's own added account" do
      admin = staff_user()
      own = plain_user()
      target = plain_user()

      {:ok, conn} = MultiSession.add_account(conn_for(admin), own.email, "ValidPassword123!")
      refute borrowed?(conn)

      {:ok, conn} = MultiSession.impersonate(conn, target)
      assert borrowed?(conn)

      [_root, own_row, borrowed_row] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      {:ok, conn, _} = MultiSession.switch_to(conn, own_row.ref)
      refute borrowed?(conn)

      {:ok, conn, _} = MultiSession.switch_to(conn, borrowed_row.ref)
      assert borrowed?(conn)
    end

    test "an account removed from the switcher leaves the own list" do
      other = plain_user()

      {:ok, conn} =
        MultiSession.add_account(conn_for(plain_user()), other.email, "ValidPassword123!")

      token = Plug.Conn.get_session(conn)["user_token"]
      [_root, row] = MultiSession.list_accounts(Plug.Conn.get_session(conn))

      {:ok, conn} = MultiSession.remove_account(conn, row.ref)
      refute token in Plug.Conn.get_session(conn)["pk_own_tokens"]
    end

    test "logging out of an added account takes it off the own list" do
      {:ok, conn} =
        MultiSession.add_account(conn_for(plain_user()), plain_user().email, "ValidPassword123!")

      token = Plug.Conn.get_session(conn)["user_token"]
      {:switched, conn, _root} = MultiSession.log_out_active(conn)
      refute token in Plug.Conn.get_session(conn)["pk_own_tokens"]
    end

    test "accounts restored from the remembered mirror come back as the user's own" do
      {:ok, _} = Settings.update_boolean_setting("multi_session_enabled", true)
      root = Auth.generate_user_session_token(plain_user())
      added = Auth.generate_user_session_token(plain_user())

      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, root)
        |> Plug.Conn.put_private(:pk_persisted_accounts, {root, [added], nil, added})
        |> MultiSession.restore_persisted_accounts(root)

      session = Plug.Conn.get_session(conn)
      assert session["user_token"] == added
      assert session["pk_own_tokens"] == [added]
      refute MultiSession.impersonated?(session)
    end
  end

  describe "impersonate/2 — the audit trail" do
    # Only the session.* family — registering and confirming the fixtures logs
    # its own `user.*` rows against the same resource_uuid.
    defp session_actions_for(target_uuid) do
      %{entries: entries} = Activity.list(action: "session.*", resource_uuid: target_uuid)
      Enum.map(entries, & &1.action)
    end

    test "a success writes ONE row, and it says impersonated — not account_added" do
      admin = admin_user()
      target = plain_user()

      assert {:ok, _conn} = MultiSession.impersonate(conn_for(admin), target)

      # `session.account_added` is what a user adding a second account of their
      # own writes. An impersonation that also wrote one would be indexed in the
      # feed under the sentence it is precisely not.
      assert ["session.impersonated"] = session_actions_for(target.uuid)
    end

    test "the impersonation row names the actor and the target" do
      admin = admin_user()
      target = plain_user()

      assert {:ok, _conn} = MultiSession.impersonate(conn_for(admin), target)

      assert %{entries: [entry]} = Activity.list(action: "session.impersonated")
      assert entry.actor_uuid == admin.uuid
      assert entry.resource_uuid == target.uuid
      # target_uuid drives the inbox: the person whose account was borrowed is
      # told about it.
      assert entry.target_uuid == target.uuid
    end

    test "a refusal is recorded too, with the rule that stopped it" do
      # The entry a security review most wants to find is the attempt that was
      # turned away — before this it left no trace at all.
      admin = admin_user()
      owner = owner_user()

      assert {:error, :target_is_owner} = MultiSession.impersonate(conn_for(admin), owner)

      assert %{entries: [entry]} = Activity.list(action: "session.impersonation_refused")
      assert entry.actor_uuid == admin.uuid
      assert entry.resource_uuid == owner.uuid
      assert entry.metadata["reason"] == "target_is_owner"
    end

    test "a refusal does not notify the account it named" do
      admin = admin_user()
      owner = owner_user()

      assert {:error, :target_is_owner} = MultiSession.impersonate(conn_for(admin), owner)

      assert %{entries: [entry]} = Activity.list(action: "session.impersonation_refused")
      # `Activity.log/1` fans a row with a target_uuid out to that user's inbox.
      # "Someone tried to sign in as you and was refused" is a feed entry, not a
      # message to send the owner.
      assert entry.target_uuid == nil
    end

    test "a non-staff actor's refusal is recorded as well" do
      client = custom_role_user("Client")
      target = plain_user()

      assert {:error, :not_allowed} = MultiSession.impersonate(conn_for(client), target)

      assert %{entries: [entry]} = Activity.list(action: "session.impersonation_refused")
      assert entry.actor_uuid == client.uuid
      assert entry.metadata["reason"] == "not_allowed"
    end
  end

  describe "may_impersonate?/1" do
    # The controller asks this BEFORE it resolves the target uuid, so that a
    # non-staff caller cannot tell an existing account from an unused uuid by
    # the flash it gets back. It must agree with `impersonate/2`'s own rule.
    test "true for the roles impersonate/2 accepts" do
      assert MultiSession.may_impersonate?(Plug.Conn.get_session(conn_for(owner_user())))
      assert MultiSession.may_impersonate?(Plug.Conn.get_session(conn_for(admin_user())))
    end

    test "false for a permission holder who is not staff, and for anonymous" do
      refute MultiSession.may_impersonate?(
               Plug.Conn.get_session(conn_for(custom_role_user("Client")))
             )

      refute MultiSession.may_impersonate?(Plug.Conn.get_session(conn_for(plain_user())))
      refute MultiSession.may_impersonate?(%{})
    end
  end
end
