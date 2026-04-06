defmodule PhoenixKit.Integrations.OAuthTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations.OAuth

  @google_oauth_config %{
    auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: "https://oauth2.googleapis.com/token",
    userinfo_url: "https://www.googleapis.com/oauth2/v2/userinfo",
    default_scopes: "https://www.googleapis.com/auth/drive",
    auth_params: %{"access_type" => "offline", "prompt" => "consent"}
  }

  describe "authorization_url/4" do
    test "builds valid URL with client_id" do
      data = %{"client_id" => "test-client-id"}
      redirect = "http://localhost:4000/callback"

      assert {:ok, url} = OAuth.authorization_url(@google_oauth_config, data, redirect)
      assert url =~ "accounts.google.com"
      assert url =~ "client_id=test-client-id"
      assert url =~ URI.encode_www_form(redirect)
      assert url =~ "response_type=code"
      assert url =~ "access_type=offline"
      assert url =~ "prompt=consent"
    end

    test "uses default scopes from oauth_config" do
      data = %{"client_id" => "test-client-id"}
      redirect = "http://localhost:4000/callback"

      {:ok, url} = OAuth.authorization_url(@google_oauth_config, data, redirect)
      assert url =~ URI.encode_www_form("https://www.googleapis.com/auth/drive")
    end

    test "overrides scopes with extra_scopes" do
      data = %{"client_id" => "test-client-id"}
      redirect = "http://localhost:4000/callback"
      extra = "custom-scope"

      {:ok, url} = OAuth.authorization_url(@google_oauth_config, data, redirect, extra)
      assert url =~ "scope=custom-scope"
      refute url =~ "auth%2Fdrive"
    end

    test "returns error when client_id is missing" do
      data = %{}
      redirect = "http://localhost:4000/callback"

      assert {:error, :client_id_not_configured} =
               OAuth.authorization_url(@google_oauth_config, data, redirect)
    end

    test "returns error when client_id is empty string" do
      data = %{"client_id" => ""}
      redirect = "http://localhost:4000/callback"

      assert {:error, :client_id_not_configured} =
               OAuth.authorization_url(@google_oauth_config, data, redirect)
    end

    test "works with string-keyed oauth_config" do
      config = %{
        "auth_url" => "https://example.com/auth",
        "default_scopes" => "scope1",
        "auth_params" => %{"foo" => "bar"}
      }

      data = %{"client_id" => "my-id"}
      redirect = "http://localhost/cb"

      {:ok, url} = OAuth.authorization_url(config, data, redirect)
      assert url =~ "example.com/auth"
      assert url =~ "scope=scope1"
      assert url =~ "foo=bar"
    end
  end

  describe "generate_state/0" do
    test "returns a non-empty string" do
      state = OAuth.generate_state()
      assert is_binary(state)
      assert byte_size(state) > 0
    end

    test "returns unique values" do
      states = for _ <- 1..10, do: OAuth.generate_state()
      assert length(Enum.uniq(states)) == 10
    end
  end

  describe "authorization_url/5 with state" do
    test "includes state parameter when provided" do
      data = %{"client_id" => "test-client-id"}
      redirect = "http://localhost:4000/callback"
      state = "random-state-token"

      {:ok, url} = OAuth.authorization_url(@google_oauth_config, data, redirect, nil, state)
      assert url =~ "state=random-state-token"
    end

    test "omits state parameter when nil" do
      data = %{"client_id" => "test-client-id"}
      redirect = "http://localhost:4000/callback"

      {:ok, url} = OAuth.authorization_url(@google_oauth_config, data, redirect, nil, nil)
      refute url =~ "state="
    end
  end

  describe "exchange_code/4 validation" do
    test "returns error when client_id is missing" do
      config = %{token_url: "https://example.com/token"}
      data = %{"client_secret" => "secret"}

      assert {:error, :client_credentials_not_configured} =
               OAuth.exchange_code(config, data, "code123", "http://localhost/cb")
    end

    test "returns error when client_secret is missing" do
      config = %{token_url: "https://example.com/token"}
      data = %{"client_id" => "id"}

      assert {:error, :client_credentials_not_configured} =
               OAuth.exchange_code(config, data, "code123", "http://localhost/cb")
    end

    test "returns error when both credentials empty" do
      config = %{token_url: "https://example.com/token"}
      data = %{"client_id" => "", "client_secret" => ""}

      assert {:error, :client_credentials_not_configured} =
               OAuth.exchange_code(config, data, "code123", "http://localhost/cb")
    end
  end

  describe "refresh_access_token/2 validation" do
    test "returns error when refresh_token is missing" do
      config = %{token_url: "https://example.com/token"}
      data = %{"client_id" => "id", "client_secret" => "secret"}

      assert {:error, :no_refresh_token} = OAuth.refresh_access_token(config, data)
    end

    test "returns error when refresh_token is empty string" do
      config = %{token_url: "https://example.com/token"}
      data = %{"client_id" => "id", "client_secret" => "secret", "refresh_token" => ""}

      assert {:error, :no_refresh_token} = OAuth.refresh_access_token(config, data)
    end

    test "returns error when client credentials missing for refresh" do
      config = %{token_url: "https://example.com/token"}
      data = %{"refresh_token" => "valid-refresh-token"}

      assert {:error, :client_credentials_not_configured} =
               OAuth.refresh_access_token(config, data)
    end
  end

  describe "fetch_userinfo/2" do
    test "returns empty map when userinfo_url is nil" do
      config = %{userinfo_url: nil}
      assert {:ok, %{}} = OAuth.fetch_userinfo(config, "some-token")
    end

    test "returns empty map when userinfo_url is empty" do
      config = %{userinfo_url: ""}
      assert {:ok, %{}} = OAuth.fetch_userinfo(config, "some-token")
    end
  end
end
