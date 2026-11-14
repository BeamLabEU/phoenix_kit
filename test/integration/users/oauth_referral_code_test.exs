defmodule PhoenixKit.Integration.Users.OAuthReferralCodeTest do
  @moduledoc """
  A referral code on the OAuth callback (`?referral_code=` on
  `/users/auth/:provider`) is a sign-up code.

  It is honoured only for the account the callback has just created. It used
  to be redeemed on every callback, so an account parked by invite-only could
  guess codes by repeating the provider round trip, outside the per-account
  limit the code screen applies. The new-account case still checks a code per
  callback, so it is charged to the per-IP budget the signup forms use.

  `phoenix_kit_referrals` is not a core dependency, so a stub registered under
  the `"referrals"` key answers for one live code, `GOODCODE`, and reports
  every claim to the test process.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Referrals

  defmodule StubReferrals do
    @moduledoc false
    def module_key, do: "referrals"
    def get_config, do: %{enabled: true, required: true}

    def get_code_by_string("GOODCODE"), do: %{code: "GOODCODE", status: true}
    def get_code_by_string(_), do: nil

    def expired?(_code), do: false
    def usage_limit_reached?(_code), do: false

    def use_code(code, user_uuid) do
      send(self(), {:use_code, code, user_uuid})
      {:ok, %{code: code, user_uuid: user_uuid}}
    end
  end

  setup do
    ModuleRegistry.register(StubReferrals)
    on_exit(fn -> ModuleRegistry.unregister(StubReferrals) end)
    :ok
  end

  # A /64 of its own per test, so no other test shares the per-IP bucket.
  defp unique_ip do
    n = System.unique_integer([:positive])

    "2001:db8:#{Integer.to_string(rem(n, 65_536), 16)}:#{Integer.to_string(div(n, 65_536) |> rem(65_536), 16)}::1"
  end

  defp auth_struct(uid \\ nil) do
    n = System.unique_integer([:positive])
    email = "oauth_ref_#{n}@example.com"

    %Ueberauth.Auth{
      provider: :google,
      uid: uid || "uid_ref_#{n}",
      info: %Ueberauth.Auth.Info{email: email, first_name: "Test", last_name: "User"},
      credentials: %Ueberauth.Auth.Credentials{token: "at"},
      extra: %Ueberauth.Auth.Extra{
        raw_info: %{token: "tok", user: %{"email" => email, "email_verified" => true}}
      }
    }
  end

  defp callback(auth, code, ip),
    do: OAuth.handle_oauth_callback(auth, referral_code: code, ip_address: ip)

  defp reload(user), do: Auth.get_user(user.uuid)

  test "a new account with a live code is admitted and the code is claimed" do
    assert {:ok, user} = callback(auth_struct(), " GOODCODE ", unique_ip())

    assert_received {:use_code, "GOODCODE", uuid}
    assert uuid == user.uuid
    assert Referrals.marked_satisfied?(reload(user))
    assert reload(user).custom_fields["referral_satisfied_via"] == "code"
  end

  test "a new account with a dead code is created but not admitted" do
    assert {:ok, user} = callback(auth_struct(), "NOSUCH", unique_ip())

    refute_received {:use_code, _, _}
    refute Referrals.marked_satisfied?(reload(user))
  end

  test "an existing parked account cannot redeem a code through the callback" do
    auth = auth_struct()
    ip = unique_ip()
    {:ok, parked} = callback(auth, nil, ip)

    # Signing in again with the same Google identity and a live code.
    assert {:ok, same} = callback(auth, "GOODCODE", ip)
    assert same.uuid == parked.uuid

    refute_received {:use_code, _, _}
    refute Referrals.marked_satisfied?(reload(parked))
  end

  test "an already-admitted account keeps its original admission" do
    auth = auth_struct()
    {:ok, user} = callback(auth, nil, unique_ip())
    {:ok, _} = Referrals.mark_satisfied(user, "admin_created")

    assert {:ok, _} = callback(auth, "GOODCODE", unique_ip())

    refute_received {:use_code, _, _}
    assert reload(user).custom_fields["referral_satisfied_via"] == "admin_created"
  end

  # The per-IP budget the signup forms spend from. Registration has its own,
  # smaller per-IP limit, so the budget is spent directly rather than by
  # creating twenty accounts.
  @code_check_limit 20

  defp spend_code_checks(ip, n) do
    capture_log(fn ->
      for _ <- 1..n, do: RateLimiter.check_referral_validation_rate_limit(ip)
    end)
  end

  test "a new account's code check is charged to the per-IP budget" do
    ip = unique_ip()
    spend_code_checks(ip, @code_check_limit)

    # Over the budget even a live code is not checked; the account stays parked.
    capture_log(fn -> send(self(), {:over, callback(auth_struct(), "GOODCODE", ip)}) end)
    assert_received {:over, {:ok, over}}
    refute_received {:use_code, _, _}
    refute Referrals.marked_satisfied?(reload(over))

    # Another IP still has its own budget.
    assert {:ok, other} = callback(auth_struct(), "GOODCODE", unique_ip())
    assert_received {:use_code, "GOODCODE", _}
    assert Referrals.marked_satisfied?(reload(other))
  end

  test "the callback spends one token per code it checks" do
    ip = unique_ip()
    spend_code_checks(ip, @code_check_limit - 2)

    # One wrong code spends the second-to-last token, the live one the last.
    assert {:ok, _} = callback(auth_struct(), "WRONG", ip)
    assert {:ok, last} = callback(auth_struct(), "GOODCODE", ip)
    assert Referrals.marked_satisfied?(reload(last))

    capture_log(fn -> send(self(), {:after, callback(auth_struct(), "GOODCODE", ip)}) end)
    assert_received {:after, {:ok, after_limit}}
    refute Referrals.marked_satisfied?(reload(after_limit))
  end

  test "a blank code is not charged against the budget" do
    ip = unique_ip()
    spend_code_checks(ip, @code_check_limit - 1)

    assert {:ok, _} = callback(auth_struct(), "  ", ip)
    assert {:ok, _} = callback(auth_struct(), "", ip)

    assert {:ok, user} = callback(auth_struct(), "GOODCODE", ip)
    assert Referrals.marked_satisfied?(reload(user))
  end
end
