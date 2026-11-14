defmodule PhoenixKit.Users.RateLimiterTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.RateLimiter.Backend

  # Start the Hammer ETS backend before all tests (may already be running from test_helper)
  setup_all do
    case :ets.whereis(Backend) do
      :undefined ->
        {:ok, pid} = Backend.start_link([])
        {:ok, %{backend_pid: pid}}

      _ref ->
        {:ok, %{backend_pid: nil}}
    end
  end

  # Generate unique email for each test to avoid cross-test pollution
  setup do
    unique_id = :erlang.unique_integer([:positive])
    {:ok, unique_id: unique_id}
  end

  describe "check_login_rate_limit/2 and record_successful_login/2" do
    # The check runs BEFORE the password is verified, so it cannot know whether
    # the request should count. It takes the slot anyway — atomically — and a
    # success hands it back.
    test "successful logins do not lock the account out", %{unique_id: id} do
      email = "success_#{id}@example.com"

      # Ten sign-ins inside one window, every one of them correct. Counting
      # them locked the account out at the sixth.
      for _ <- 1..10 do
        assert :ok = RateLimiter.check_login_rate_limit(email)
        RateLimiter.record_successful_login(email)
      end

      assert :ok = RateLimiter.check_login_rate_limit(email)
    end

    test "blocks after the limit is reached in FAILURES", %{unique_id: id} do
      email = "blocked_#{id}@example.com"

      for _ <- 1..5, do: assert(:ok = RateLimiter.check_login_rate_limit(email))

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email)
    end

    # The regression a peek-then-count check had: every request in a parallel
    # burst read an empty bucket, so the whole burst reached the password
    # verify. The slot is taken by the check itself, so a burst is bounded no
    # matter how long each verify takes.
    test "a parallel burst is bounded by the limit", %{unique_id: id} do
      email = "burst_#{id}@example.com"

      allowed =
        1..50
        |> Task.async_stream(fn _ -> RateLimiter.check_login_rate_limit(email) end,
          max_concurrency: 50
        )
        |> Enum.count(&(&1 == {:ok, :ok}))

      assert allowed == 5
    end

    test "a success never pushes the bucket below empty", %{unique_id: id} do
      email = "floor_#{id}@example.com"

      for _ <- 1..3, do: RateLimiter.record_successful_login(email)

      assert 5 = RateLimiter.get_remaining_attempts(:login, email)
    end

    test "rate limits are per-email", %{unique_id: id} do
      email1 = "user1_#{id}@example.com"
      email2 = "user2_#{id}@example.com"

      for _ <- 1..5, do: RateLimiter.check_login_rate_limit(email1)

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email1)
      assert :ok = RateLimiter.check_login_rate_limit(email2)
    end

    # A client blocked for its network must not be able to lock out an account
    # by naming it: the refused request never reaches the email bucket.
    test "a request refused for its IP does not spend the named email's slots", %{unique_id: id} do
      ip = "203.0.113.#{rem(id, 255)}"
      victim = "victim_#{id}@example.com"

      for n <- 1..15, do: RateLimiter.check_login_rate_limit("fill_#{id}_#{n}@example.com", ip)

      for _ <- 1..10 do
        assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(victim, ip)
      end

      assert 5 = RateLimiter.get_remaining_attempts(:login, victim)
    end

    test "includes IP-based rate limiting when IP provided", %{unique_id: id} do
      email = "user_#{id}@example.com"
      ip = "192.168.1.#{rem(id, 255)}"

      assert :ok = RateLimiter.check_login_rate_limit(email, ip)
    end

    test "the IP bucket blocks a spray across many addresses", %{unique_id: id} do
      ip = "198.51.100.#{rem(id, 255)}"

      # The IP limit is login_limit * 3, and each address is its own email
      # bucket — so only the IP bucket can catch this shape.
      for n <- 1..15, do: RateLimiter.check_login_rate_limit("spray_#{id}_#{n}@example.com", ip)

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_login_rate_limit("spray_#{id}_fresh@example.com", ip)
    end

    test "normalizes email addresses", %{unique_id: id} do
      email_lower = "norm_#{id}@example.com"
      email_upper = "NORM_#{id}@EXAMPLE.COM"
      email_mixed = "NoRm_#{id}@ExAmPlE.cOm"

      # All case variations count toward the same bucket.
      RateLimiter.check_login_rate_limit(email_lower)
      RateLimiter.check_login_rate_limit(email_upper)
      RateLimiter.check_login_rate_limit(email_mixed)
      RateLimiter.check_login_rate_limit(email_lower)
      RateLimiter.check_login_rate_limit(email_upper)

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email_mixed)
    end
  end

  describe "check_magic_link_rate_limit/1" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "magic_#{id}@example.com"

      # First 3 attempts should succeed (default magic link limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "magic_blocked_#{id}@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_magic_link_rate_limit(email)
    end

    test "rate limits are per-email", %{unique_id: id} do
      email1 = "magic1_#{id}@example.com"
      email2 = "magic2_#{id}@example.com"

      # Exhaust rate limit for email1
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email1)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_magic_link_rate_limit(email1)

      # email2 should still be allowed
      assert :ok = RateLimiter.check_magic_link_rate_limit(email2)
    end
  end

  describe "check_password_reset_rate_limit/1" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "pwreset_#{id}@example.com"

      # First 3 attempts should succeed (default password reset limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "pwreset_blocked_#{id}@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(email)
    end

    test "rate limits are per-email", %{unique_id: id} do
      email1 = "pwreset1_#{id}@example.com"
      email2 = "pwreset2_#{id}@example.com"

      # Exhaust rate limit for email1
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email1)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(email1)

      # email2 should still be allowed
      assert :ok = RateLimiter.check_password_reset_rate_limit(email2)
    end
  end

  describe "check_registration_rate_limit/2" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "newuser_#{id}@example.com"

      # First 3 attempts should succeed (default registration limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_registration_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "spammer_#{id}@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_registration_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_registration_rate_limit(email)
    end

    test "includes IP-based rate limiting when IP provided", %{unique_id: id} do
      email = "reg_#{id}@example.com"
      ip = "10.0.#{rem(id, 255)}.100"

      # Should succeed with IP
      assert :ok = RateLimiter.check_registration_rate_limit(email, ip)
    end

    test "IP-based rate limiting is independent of email", %{unique_id: id} do
      ip = "10.1.#{rem(id, 255)}.200"

      # Different emails from same IP should count toward IP limit
      # Default IP limit is 10, so we test a few
      for i <- 1..5 do
        email = "regip_#{id}_#{i}@example.com"
        assert :ok = RateLimiter.check_registration_rate_limit(email, ip)
      end
    end
  end

  describe "check_qr_login_rate_limit/1" do
    test "allows requests within rate limit", %{unique_id: id} do
      ip = "172.16.0.#{rem(id, 255)}"

      # First 10 attempts should succeed (default QR login limit)
      for _ <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit(ip)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      ip = "172.16.1.#{rem(id, 255)}"

      for _ <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit(ip)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_qr_login_rate_limit(ip)
    end

    test "rate limits are per-IP", %{unique_id: id} do
      ip1 = "172.16.2.#{rem(id, 255)}"
      ip2 = "172.16.3.#{rem(id, 255)}"

      for _ <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit(ip1)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_qr_login_rate_limit(ip1)
      assert :ok = RateLimiter.check_qr_login_rate_limit(ip2)
    end

    # Every address in a /64 belongs to the same client, who can pick a
    # fresh one per request — the bucket has to be the /64.
    test "IPv6 addresses in the same /64 share one bucket", %{unique_id: id} do
      net = Integer.to_string(rem(id, 0xFFFF), 16)

      for n <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit("2001:db8:#{net}:1::#{n}")
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_qr_login_rate_limit("2001:db8:#{net}:1:dead:beef:0:99")

      assert :ok = RateLimiter.check_qr_login_rate_limit("2001:db8:#{net}:2::1")
    end
  end

  describe "IPv6 /64 grouping on login and mail IP buckets" do
    # QR already covers check_qr_login_rate_limit/1. Login keys the IP
    # itself; the mail endpoints go through charge_ip/4. A revert of either
    # call site must fail without the QR test catching it.
    test "login IP bucket is the /64", %{unique_id: id} do
      net = Integer.to_string(rem(id, 0xFFFF), 16)
      # login IP limit is login_limit * 3 = 15
      for n <- 1..15 do
        assert :ok =
                 RateLimiter.check_login_rate_limit(
                   "login6_#{id}_#{n}@e.com",
                   "2001:db8:#{net}:1::#{n}"
                 )
      end

      # Each address is its own /128 but the bucket is the /64, so those
      # fifteen failures share one counter.

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_login_rate_limit(
                 "login6_#{id}_16@e.com",
                 "2001:db8:#{net}:1:dead:beef:0:99"
               )

      assert :ok =
               RateLimiter.check_login_rate_limit(
                 "login6_#{id}_other@e.com",
                 "2001:db8:#{net}:2::1"
               )
    end

    test "mail IP bucket is the /64", %{unique_id: id} do
      net = Integer.to_string(rem(id, 0xFFFF), 16)

      for n <- 1..10 do
        assert :ok =
                 RateLimiter.check_password_reset_rate_limit(
                   "spray6_#{id}_#{n}@e.com",
                   "2001:db8:#{net}:1::#{n}"
                 )
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(
                 "spray6_#{id}_11@e.com",
                 "2001:db8:#{net}:1:dead:beef:0:99"
               )

      assert :ok =
               RateLimiter.check_password_reset_rate_limit(
                 "spray6_#{id}_other@e.com",
                 "2001:db8:#{net}:2::1"
               )
    end
  end

  describe "get_remaining_attempts/2" do
    test "returns correct remaining attempts for login", %{unique_id: id} do
      email = "remaining_login_#{id}@example.com"

      # Initially should have 5 attempts remaining (default limit)
      assert 5 = RateLimiter.get_remaining_attempts(:login, email)

      # The check takes a slot; only a success hands it back.
      RateLimiter.check_login_rate_limit(email)
      assert 4 = RateLimiter.get_remaining_attempts(:login, email)

      RateLimiter.check_login_rate_limit(email)
      RateLimiter.record_successful_login(email)
      assert 4 = RateLimiter.get_remaining_attempts(:login, email)

      for _ <- 1..4, do: RateLimiter.check_login_rate_limit(email)
      assert 0 = RateLimiter.get_remaining_attempts(:login, email)
    end

    test "returns correct remaining attempts for magic link", %{unique_id: id} do
      email = "remaining_magic_#{id}@example.com"

      # Initially should have 3 attempts remaining (default limit)
      assert 3 = RateLimiter.get_remaining_attempts(:magic_link, email)

      # After one attempt, should have 2 remaining
      RateLimiter.check_magic_link_rate_limit(email)
      assert 2 = RateLimiter.get_remaining_attempts(:magic_link, email)
    end
  end

  # The address bucket cannot see a spray: every address takes a single hit, so
  # none of them ever fires and the install sends one email per address asked
  # for. These cover the two buckets that can.
  describe "per-IP bucket on the mail-sending endpoints" do
    test "a spray of fresh addresses from one IP is stopped", %{unique_id: id} do
      ip = "198.51.100.#{rem(id, 200)}"

      # Ten distinct addresses, one hit each — the per-address bucket (3) never
      # fires, and before the IP bucket existed all ten went through.
      for n <- 1..10 do
        assert :ok = RateLimiter.check_password_reset_rate_limit("spray_#{id}_#{n}@e.com", ip)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit("spray_#{id}_11@e.com", ip)
    end

    test "another IP is unaffected", %{unique_id: id} do
      ip = "198.51.100.#{rem(id, 200)}"

      for n <- 1..10 do
        assert :ok = RateLimiter.check_magic_link_rate_limit("ipa_#{id}_#{n}@e.com", ip)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_magic_link_rate_limit("ipa_#{id}_11@e.com", ip)

      assert :ok = RateLimiter.check_magic_link_rate_limit("ipb_#{id}@e.com", "203.0.113.42")
    end

    test "each endpoint has its own IP bucket", %{unique_id: id} do
      ip = "198.51.100.#{rem(id, 200)}"

      for n <- 1..10 do
        assert :ok = RateLimiter.check_confirmation_resend_rate_limit("mix_#{id}_#{n}@e.com", ip)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_confirmation_resend_rate_limit("mix_#{id}_11@e.com", ip)

      # Exhausting one endpoint must not close the others for that IP.
      assert :ok = RateLimiter.check_password_reset_rate_limit("mix2_#{id}@e.com", ip)
    end

    test "a request with no IP still gets the address bucket", %{unique_id: id} do
      email = "noip_#{id}@example.com"

      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email, nil)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(email, nil)
    end

    test "an unreadable address is treated as no IP, not as one shared bucket",
         %{unique_id: id} do
      # Lumping every unknown-IP visitor into one bucket would let a host that
      # cannot read peer data lock out its own users site-wide.
      for n <- 1..12 do
        assert :ok =
                 RateLimiter.check_password_reset_rate_limit("unk_#{id}_#{n}@e.com", "unknown")
      end
    end
  end

  # The site-wide cap. Switched off in config/test.exs (one counter shared by
  # the whole run), so these turn it on for themselves and put it back.
  describe "site-wide cap" do
    setup do
      previous = Application.get_env(:phoenix_kit, RateLimiter, [])

      on_exit(fn -> Application.put_env(:phoenix_kit, RateLimiter, previous) end)

      {:ok, previous: previous}
    end

    defp with_global_limit(previous, key, limit) do
      Application.put_env(:phoenix_kit, RateLimiter, Keyword.put(previous, key, limit))
    end

    test "refuses everyone once the install's hourly allowance is spent", %{previous: previous} do
      with_global_limit(previous, :password_reset_global_limit, 3)
      id = :erlang.unique_integer([:positive])

      # Distinct address AND distinct IP each time, so neither narrower bucket
      # is what stops it — only the site-wide one can.
      for n <- 1..3 do
        assert :ok =
                 RateLimiter.check_password_reset_rate_limit("g_#{id}_#{n}@e.com", "10.0.0.#{n}")
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit("g_#{id}_4@e.com", "10.0.0.4")
    end

    test "a request the address bucket already refused does not spend it",
         %{previous: previous} do
      with_global_limit(previous, :magic_link_global_limit, 5)
      id = :erlang.unique_integer([:positive])
      victim = "victim_#{id}@example.com"

      # Three accepted (the address limit), then hammer the same address: those
      # are refused and send nothing, so they must not drain everyone's
      # allowance — charging the cap first would make this the whole DoS.
      for _ <- 1..3, do: RateLimiter.check_magic_link_rate_limit(victim, "10.1.0.1")
      for _ <- 1..20, do: RateLimiter.check_magic_link_rate_limit(victim, "10.1.0.1")

      # Two of the five are left for everybody else.
      assert :ok = RateLimiter.check_magic_link_rate_limit("other_#{id}_a@e.com", "10.1.0.2")
      assert :ok = RateLimiter.check_magic_link_rate_limit("other_#{id}_b@e.com", "10.1.0.3")

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_magic_link_rate_limit("other_#{id}_c@e.com", "10.1.0.4")
    end

    # The registration counter is one for the whole run and other files spend
    # from it, so a limit here is "what it holds now, plus n".
    defp registration_headroom(previous, n) do
      with_global_limit(previous, :registration_global_limit, 1_000_000_000)
      used = Enum.find(RateLimiter.overview(), &(&1.action == :registration)).site_wide.used
      with_global_limit(previous, :registration_global_limit, used + n)
    end

    test "registration: only a request marked site_wide spends the cap",
         %{previous: previous} do
      registration_headroom(previous, 3)
      id = :erlang.unique_integer([:positive])

      # Fixtures, imports, OAuth sign-ups: any number, the cap untouched.
      for n <- 1..10 do
        assert :ok = RateLimiter.check_registration_rate_limit("prog_#{id}_#{n}@e.com")
      end

      # The public forms: a fresh address and a fresh IP each time, so only the
      # site-wide bucket can be what stops the fourth.
      for n <- 1..3 do
        assert :ok =
                 RateLimiter.check_registration_rate_limit(
                   "anon_#{id}_#{n}@e.com",
                   "10.3.#{n}.1",
                   site_wide: true
                 )
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_registration_rate_limit("anon_#{id}_4@e.com", "10.3.4.1",
                 site_wide: true
               )

      # ...and a tripped cap still does not stop a programmatic registration.
      assert :ok = RateLimiter.check_registration_rate_limit("prog_#{id}_after@e.com")
    end

    test "registration: a request the address bucket refused does not spend the cap",
         %{previous: previous} do
      registration_headroom(previous, 4)
      id = :erlang.unique_integer([:positive])
      victim = "reg_victim_#{id}@example.com"

      for _ <- 1..20 do
        RateLimiter.check_registration_rate_limit(victim, "10.4.0.1", site_wide: true)
      end

      # Three accepted for the victim; one of the four is left.
      assert :ok =
               RateLimiter.check_registration_rate_limit("reg_o_#{id}@e.com", "10.4.0.2",
                 site_wide: true
               )

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_registration_rate_limit("reg_p_#{id}@e.com", "10.4.0.3",
                 site_wide: true
               )
    end

    test "overview/0 reports the limits and what the site-wide bucket holds",
         %{previous: previous} do
      with_global_limit(previous, :registration_global_limit, 1_000_000_000)
      id = :erlang.unique_integer([:positive])

      before = Enum.find(RateLimiter.overview(), &(&1.action == :registration))

      RateLimiter.check_registration_rate_limit("ov_#{id}@e.com", "10.5.0.1", site_wide: true)

      row = Enum.find(RateLimiter.overview(), &(&1.action == :registration))

      assert row.address == %{limit: 3, window_ms: 3_600_000}
      assert row.ip == %{limit: 10, window_ms: 3_600_000}
      assert %{limit: 1_000_000_000, window_ms: 3_600_000} = row.site_wide
      assert row.site_wide.used == before.site_wide.used + 1
      assert row.site_wide.resets_in_ms in 1..3_600_000

      assert Enum.map(RateLimiter.overview(), & &1.action) ==
               [:login, :registration, :magic_link, :password_reset, :confirmation_resend]

      # Sign-in has no site-wide cap, and a cap switched off reads as none.
      assert %{site_wide: nil, ip: %{limit: 15}} =
               Enum.find(RateLimiter.overview(), &(&1.action == :login))

      with_global_limit(previous, :registration_global_limit, nil)
      assert %{site_wide: nil} = Enum.find(RateLimiter.overview(), &(&1.action == :registration))
    end

    test "nil switches the cap off", %{previous: previous} do
      with_global_limit(previous, :confirmation_resend_global_limit, nil)
      id = :erlang.unique_integer([:positive])

      for n <- 1..25 do
        assert :ok =
                 RateLimiter.check_confirmation_resend_rate_limit(
                   "off_#{id}_#{n}@e.com",
                   "10.2.0.#{n}"
                 )
      end
    end
  end
end
