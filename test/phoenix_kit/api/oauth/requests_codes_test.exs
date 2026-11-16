defmodule PhoenixKit.API.OAuth.RequestsCodesTest do
  @moduledoc """
  The two one-shot tokens of the flow: the stored authorization request (behind the consent URL)
  and the authorization code. Both are stored as hashes only, are used once, atomically, and
  run out.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Codes
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.Test.Repo

  setup do
    register_fake_module!()
    start_key_cache!()
    enable_oauth!()
    {_user, _role, scope} = oauth_holder(["media"])
    %{scope: scope, client: client!()}
  end

  defp attrs,
    do: %{
      redirect_uri: "https://client.example/callback",
      code_challenge: "c",
      resource: "https://x.example/mcp/admin"
    }

  describe "requests" do
    test "are stored as a hash of a 32-byte token, pinned to the client as it was", %{
      client: client
    } do
      assert {:ok, token, %Request{} = request} = Requests.create(client, attrs())

      assert byte_size(Base.url_decode64!(token, padding: false)) == 32

      assert request.request_token_hash ==
               :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))

      refute request.request_token_hash == token
      assert request.client_snapshot["client_id"] == client.client_id
      assert DateTime.diff(request.expires_at, DateTime.utc_now()) in 595..600

      assert {:ok, %Request{uuid: uuid}} = Requests.fetch(token)
      assert uuid == request.uuid
    end

    test "fetch/1 accepts nothing but a canonical token", %{client: client} do
      {:ok, token, _} = Requests.create(client, attrs())

      for bad <- [
            nil,
            1,
            "",
            "x",
            String.duplicate("A", 43),
            token <> "=",
            token <> "A",
            String.upcase(token) <> "x"
          ] do
        assert Requests.fetch(bad) == :error
      end
    end

    test "a request is used once", %{client: client} do
      {:ok, token, request} = Requests.create(client, attrs())
      assert Requests.consume(request) == :ok
      assert Requests.consume(request) == :error
      assert Requests.fetch(token) == :error
    end

    test "a request that ran out cannot be fetched or consumed", %{client: client} do
      {:ok, token, request} = Requests.create(client, attrs())
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      Repo.update_all(Request, set: [expires_at: past])

      assert Requests.fetch(token) == :error
      assert Requests.consume(request) == :error
      assert Requests.live_count() == 0
    end

    test "the ceiling of waiting requests", %{client: client} do
      put_setting_value("api_oauth_requests_ceiling", "2")
      assert {:ok, _, _} = Requests.create(client, attrs())
      assert {:ok, _, _} = Requests.create(client, attrs())
      assert Requests.create(client, attrs()) == {:error, :busy}
      assert Requests.live_count() == 2
    end
  end

  describe "codes" do
    setup %{scope: scope, client: client} do
      {:ok, grant, _key} =
        Grants.create(
          scope,
          client,
          %{
            scopes: [read_scope()],
            expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
          },
          impersonated: false
        )

      %{grant: grant}
    end

    test "are stored as a hash and live a minute", %{grant: grant} do
      assert {:ok, code, %Code{} = row} =
               Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})

      refute row.code_hash == code
      assert DateTime.diff(row.expires_at, DateTime.utc_now()) in 55..60
      assert Codes.ttl_seconds() == 60
    end

    test "redeem/1 gives a code to one caller, the second finds it reused", %{grant: grant} do
      {:ok, code, _} = Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})

      assert {:ok, %Code{used_at: %DateTime{}} = row} = Codes.redeem(code)
      assert row.grant_uuid == grant.uuid
      assert {:error, :reused, %Code{}} = Codes.redeem(code)
    end

    test "an unknown, malformed or expired code is invalid, an expired one is not 'reused'", %{
      grant: grant
    } do
      assert Codes.redeem(nil) == {:error, :invalid}
      assert Codes.redeem("short") == {:error, :invalid}
      assert Codes.redeem(String.duplicate("A", 43)) == {:error, :invalid}

      {:ok, code, _} = Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})
      Repo.update_all(Code, set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])
      assert Codes.redeem(code) == {:error, :invalid}
    end
  end

  defp put_setting_value(key, value) do
    write_setting(fn -> PhoenixKit.Settings.update_setting(key, value) end)
  end
end
