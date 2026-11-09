defmodule PhoenixKitWeb.Users.MultiSessionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Users.MultiSession

  describe "stack_tokens/1" do
    test "returns the explicit stack when present" do
      session = %{"user_token" => "a", "pk_session_accounts" => ["a", "b"]}
      assert MultiSession.stack_tokens(session) == ["a", "b"]
    end

    test "falls back to [active_token] when stack absent" do
      session = %{"user_token" => "a"}
      assert MultiSession.stack_tokens(session) == ["a"]
    end

    test "returns [] when no active token" do
      assert MultiSession.stack_tokens(%{}) == []
    end
  end

  describe "impersonated?/1" do
    test "false for a single-account session and for the root of a stack" do
      refute MultiSession.impersonated?(%{"user_token" => "a"})

      refute MultiSession.impersonated?(%{
               "user_token" => "a",
               "pk_session_accounts" => ["a", "b"]
             })
    end

    test "true when the active account is not the root of the stack" do
      assert MultiSession.impersonated?(%{
               "user_token" => "b",
               "pk_session_accounts" => ["a", "b"]
             })
    end

    test "false for an added account the user added themselves" do
      refute MultiSession.impersonated?(%{
               "user_token" => "b",
               "pk_session_accounts" => ["a", "b"],
               "pk_own_tokens" => ["b"]
             })
    end

    test "true for an added account that is not on the own list, or with a broken list" do
      assert MultiSession.impersonated?(%{
               "user_token" => "c",
               "pk_session_accounts" => ["a", "b", "c"],
               "pk_own_tokens" => ["b"]
             })

      assert MultiSession.impersonated?(%{
               "user_token" => "b",
               "pk_session_accounts" => ["a", "b"],
               "pk_own_tokens" => "b"
             })
    end

    test "false without an active token" do
      refute MultiSession.impersonated?(%{})
      refute MultiSession.impersonated?(%{"pk_session_accounts" => ["a", "b"]})
    end
  end

  describe "max_accounts/0" do
    test "is 5" do
      assert MultiSession.max_accounts() == 5
    end
  end
end
