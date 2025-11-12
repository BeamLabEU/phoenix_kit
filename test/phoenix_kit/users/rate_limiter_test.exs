defmodule PhoenixKit.Users.RateLimiterTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Users.RateLimiter

  # Clean up rate limit buckets between tests
  setup do
    on_exit(fn ->
      # Clean up all rate limit buckets
      # Hammer stores data in ETS tables, we don't need to clean manually
      # as each test runs with fresh state due to async: false
      :ok
    end)

    :ok
  end

  describe "check_login_rate_limit/2" do
    test "allows requests within rate limit" do
      email = "user@example.com"

      # First 5 attempts should succeed
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit" do
      email = "blocked@example.com"

      # Exhaust the rate limit (default: 5 attempts)
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email)
      end

      # 6th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email)
    end

    test "rate limits are per-email" do
      email1 = "user1@example.com"
      email2 = "user2@example.com"

      # Exhaust rate limit for email1
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email1)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email1)

      # email2 should still be allowed
      assert :ok = RateLimiter.check_login_rate_limit(email2)
    end

    test "includes IP-based rate limiting when IP provided" do
      email = "user@example.com"
      ip = "192.168.1.1"

      # Should succeed with IP
      assert :ok = RateLimiter.check_login_rate_limit(email, ip)
    end

    test "normalizes email addresses" do
      email_lower = "user@example.com"
      email_upper = "USER@EXAMPLE.COM"
      email_mixed = "UsEr@ExAmPlE.cOm"

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
    test "allows requests within rate limit" do
      email = "user@example.com"

      # First 3 attempts should succeed (default magic link limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit" do
      email = "blocked@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_magic_link_rate_limit(email)
    end

    test "rate limits are per-email" do
      email1 = "user1@example.com"
      email2 = "user2@example.com"

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
    test "allows requests within rate limit" do
      email = "user@example.com"

      # First 3 attempts should succeed (default password reset limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit" do
      email = "blocked@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(email)
    end

    test "rate limits are per-email" do
      email1 = "user1@example.com"
      email2 = "user2@example.com"

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
    test "allows requests within rate limit" do
      email = "newuser@example.com"

      # First 3 attempts should succeed (default registration limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_registration_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit" do
      email = "spammer@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_registration_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_registration_rate_limit(email)
    end

    test "includes IP-based rate limiting when IP provided" do
      email = "user@example.com"
      ip = "192.168.1.100"

      # Should succeed with IP
      assert :ok = RateLimiter.check_registration_rate_limit(email, ip)
    end

    test "IP-based rate limiting is independent of email" do
      ip = "192.168.1.200"

      # Different emails from same IP should count toward IP limit
      # Default IP limit is 10, so we test a few
      for i <- 1..5 do
        email = "user#{i}@example.com"
        assert :ok = RateLimiter.check_registration_rate_limit(email, ip)
      end
    end
  end

  describe "reset_rate_limit/2" do
    test "resets rate limit for login" do
      email = "user@example.com"

      # Exhaust the rate limit
      for _ <- 1..5 do
        RateLimiter.check_login_rate_limit(email)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email)

      # Reset the rate limit (use email:identifier format for composite keys)
      assert :ok = RateLimiter.reset_rate_limit(:login, "email:#{email}")

      # Should be able to make requests again
      assert :ok = RateLimiter.check_login_rate_limit(email)
    end

    test "resets rate limit for magic link" do
      email = "user@example.com"

      # Exhaust the rate limit
      for _ <- 1..3 do
        RateLimiter.check_magic_link_rate_limit(email)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_magic_link_rate_limit(email)

      # Reset the rate limit
      assert :ok = RateLimiter.reset_rate_limit(:magic_link, email)

      # Should be able to make requests again
      assert :ok = RateLimiter.check_magic_link_rate_limit(email)
    end
  end

  describe "get_remaining_attempts/2" do
    test "returns correct remaining attempts for login" do
      email = "user@example.com"

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

    test "returns correct remaining attempts for magic link" do
      email = "user@example.com"

      # Initially should have 3 attempts remaining (default limit)
      assert 3 = RateLimiter.get_remaining_attempts(:magic_link, email)

      # After one attempt, should have 2 remaining
      RateLimiter.check_magic_link_rate_limit(email)
      assert 2 = RateLimiter.get_remaining_attempts(:magic_link, email)
    end
  end
end
