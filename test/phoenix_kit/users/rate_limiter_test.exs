defmodule PhoenixKit.Users.RateLimiterTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.RateLimiter.Backend

  # Start the Hammer ETS backend before all tests
  setup_all do
    # Start the RateLimiter backend if not already started
    case Backend.start_link([]) do
      {:ok, pid} -> {:ok, %{backend_pid: pid}}
      {:error, {:already_started, pid}} -> {:ok, %{backend_pid: pid}}
    end
  end

  # Generate unique email for each test to avoid cross-test pollution
  setup do
    unique_id = :erlang.unique_integer([:positive])
    {:ok, unique_id: unique_id}
  end

  describe "check_login_rate_limit/2" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "user_#{id}@example.com"

      # First 5 attempts should succeed
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "blocked_#{id}@example.com"

      # Exhaust the rate limit (default: 5 attempts)
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email)
      end

      # 6th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email)
    end

    test "rate limits are per-email", %{unique_id: id} do
      email1 = "user1_#{id}@example.com"
      email2 = "user2_#{id}@example.com"

      # Exhaust rate limit for email1
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email1)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email1)

      # email2 should still be allowed
      assert :ok = RateLimiter.check_login_rate_limit(email2)
    end

    test "includes IP-based rate limiting when IP provided", %{unique_id: id} do
      email = "user_#{id}@example.com"
      ip = "192.168.1.#{rem(id, 255)}"

      # Should succeed with IP
      assert :ok = RateLimiter.check_login_rate_limit(email, ip)
    end

    test "normalizes email addresses", %{unique_id: id} do
      email_lower = "norm_#{id}@example.com"
      email_upper = "NORM_#{id}@EXAMPLE.COM"
      email_mixed = "NoRm_#{id}@ExAmPlE.cOm"

      # All variations should count toward same limit
      assert :ok = RateLimiter.check_login_rate_limit(email_lower)
      assert :ok = RateLimiter.check_login_rate_limit(email_upper)
      assert :ok = RateLimiter.check_login_rate_limit(email_mixed)

      # Continue to exhaust limit with different case variations
      assert :ok = RateLimiter.check_login_rate_limit(email_lower)
      assert :ok = RateLimiter.check_login_rate_limit(email_upper)

      # Should be blocked now (5 attempts reached)
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

  describe "reset_rate_limit/2" do
    # Note: reset_rate_limit is deprecated in Hammer 7.x as delete_buckets was removed
    # Rate limits now expire automatically after their time window

    test "returns not_supported for login reset (deprecated)", %{unique_id: id} do
      email = "reset_login_#{id}@example.com"

      # Exhaust the rate limit
      for _ <- 1..5 do
        RateLimiter.check_login_rate_limit(email)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email)

      # Reset returns :not_supported in Hammer 7.x
      assert {:error, :not_supported} = RateLimiter.reset_rate_limit(:login, "email:#{email}")
    end

    test "returns not_supported for magic link reset (deprecated)", %{unique_id: id} do
      email = "reset_magic_#{id}@example.com"

      # Exhaust the rate limit
      for _ <- 1..3 do
        RateLimiter.check_magic_link_rate_limit(email)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_magic_link_rate_limit(email)

      # Reset returns :not_supported in Hammer 7.x
      assert {:error, :not_supported} = RateLimiter.reset_rate_limit(:magic_link, email)
    end
  end

  describe "get_remaining_attempts/2" do
    test "returns correct remaining attempts for login", %{unique_id: id} do
      email = "remaining_login_#{id}@example.com"

      # Initially should have 5 attempts remaining (default limit)
      assert 5 = RateLimiter.get_remaining_attempts(:login, email)

      # After one attempt, should have 4 remaining
      RateLimiter.check_login_rate_limit(email)
      assert 4 = RateLimiter.get_remaining_attempts(:login, email)

      # After 5 attempts, should have 0 remaining
      for _ <- 1..4 do
        RateLimiter.check_login_rate_limit(email)
      end

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
end
