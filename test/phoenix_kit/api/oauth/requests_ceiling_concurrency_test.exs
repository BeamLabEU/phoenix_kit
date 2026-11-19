defmodule PhoenixKit.API.OAuth.RequestsCeilingConcurrencyTest do
  @moduledoc """
  Authorization requests created at the same moment: separate database sessions, real commits, no
  sandbox. The ceiling of waiting requests for the whole install holds under load: the count and
  the insert of `PhoenixKit.API.OAuth.Requests.create/2` run under one advisory lock, so callers
  that arrive together cannot all pass it.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import PhoenixKit.API.OAuthTestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Test.Repo

  @moduletag :integration
  @ceiling 3
  @callers 12

  setup do
    Sandbox.mode(Repo, :auto)
    KeyTestSupport.start_key_cache!()
    client = client!()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(r in Request, where: r.client_uuid == ^client.uuid))
      Repo.delete_all(from(c in Client, where: c.uuid == ^client.uuid))
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'api_oauth_requests_ceiling'")
      Sandbox.mode(Repo, :manual)
    end)

    KeyTestSupport.put_setting("api_oauth_requests_ceiling", @ceiling)
    %{client: client}
  end

  defp create(client) do
    Requests.create(client, %{
      redirect_uri: hd(client.redirect_uris),
      code_challenge: elem(pkce(), 1),
      resource: Resource.resource(),
      browser: Requests.new_browser(),
      ip: KeyTestSupport.unique_ip()
    })
  end

  test "simultaneous authorization requests never pass the ceiling together", %{client: client} do
    results =
      1..@callers
      |> Enum.map(fn _ -> fn -> create(client) end end)
      |> Task.async_stream(& &1.(), max_concurrency: @callers, timeout: 60_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _token, %Request{}}, &1)) == @ceiling
    assert Enum.count(results, &(&1 == {:error, :busy})) == @callers - @ceiling

    assert Repo.aggregate(from(r in Request, where: r.client_uuid == ^client.uuid), :count) ==
             @ceiling

    assert Requests.live_count() == @ceiling
  end
end
