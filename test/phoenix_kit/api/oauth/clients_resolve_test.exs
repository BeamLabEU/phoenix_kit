defmodule PhoenixKit.API.OAuth.ClientsResolveTest do
  @moduledoc """
  `Clients.resolve/2`: the client behind a `client_id` an authorization request names. A
  registered or pre-registered one is a row; a URL is a metadata document, fetched (through a
  stub of the HTTP layer; no socket is opened), checked against the policy, remembered for the time
  the response allows and fetched again when that has run out. A refusal is never remembered.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.OAuthTestSupport, only: [client!: 1]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0, unique_ip: 0]

  alias PhoenixKit.API.OAuth.Cimd
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.OAuthCimdStub, as: Stub

  @claude Stub.claude_id()
  @chatgpt Stub.chatgpt_id()

  setup do
    setup_api()
    Stub.install!()
    Stub.put(@claude, Stub.claude_document())
    Stub.put(@chatgpt, Stub.chatgpt_document())

    # The counters live as long as the node: start each test with these two clients unspent.
    for client_id <- [@claude, @chatgpt], do: Limits.reset(:cimd_client, client_id)

    %{ip: unique_ip()}
  end

  defp resolve(client_id, ip), do: Clients.resolve(client_id, ip: ip)

  describe "a document on the authorization server's own host" do
    # A path on the site's own domain (a shared pages host, a person's page) must not be able to
    # name a client: nothing is fetched, the request meets the ordinary "no such client".
    test "is no client, and nothing is fetched or counted", %{ip: ip} do
      put_setting("site_url", "https://pages.example.com")
      own = "https://pages.example.com/someone/client.json"
      Stub.put(own, Stub.claude_document() |> Map.put("client_id", own))

      for id <- [own, "https://PAGES.example.com./x/client.json"] do
        assert resolve(id, ip) == {:error, :unknown_client}
      end

      assert Stub.calls(own) == []
      assert Repo.all(Client) == []
    end

    test "a stored document of that host that ran out is not fetched again", %{ip: ip} do
      put_setting("site_url", "https://pages.example.com")
      own = "https://pages.example.com/old/client.json"
      Stub.put(own, Stub.claude_document() |> Map.put("client_id", own))

      Repo.insert!(%Client{
        kind: "cimd",
        client_id: own,
        redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
        metadata_expires_at:
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      })

      assert resolve(own, ip) == {:error, :unknown_client}
      assert Stub.calls(own) == []
    end

    test "another host of the same domain is another host", %{ip: ip} do
      put_setting("site_url", "https://pages.example.com")
      assert {:ok, %Client{}} = resolve(@claude, ip)
    end
  end

  describe "clean_name/1" do
    test "cuts by graphemes and by code points, whichever is shorter" do
      assert Clients.clean_name(String.duplicate("n", 300)) |> String.length() == 160

      zalgo = String.duplicate("a\u0301\u0302\u0303", 160)
      cut = Clients.clean_name(zalgo)
      assert length(String.codepoints(cut)) <= 160
      assert String.valid?(cut)
    end

    test "removes control characters and answers nil for what is left empty or not text" do
      assert Clients.clean_name("  Ag\u0000ent\u202E ") == "Agent"
      assert Clients.clean_name(" \u0000 ") == nil
      assert Clients.clean_name(42) == nil
    end

    test "an administrator's name for a pre-registered client is cut the same way" do
      zalgo = String.duplicate("a\u0301\u0302\u0303", 160)

      assert {:ok, %Client{client_name: stored}} =
               Clients.register_preregistered(%{
                 client_id: "pre_zalgo",
                 client_name: zalgo,
                 redirect_uris: ["https://app.example/cb"]
               })

      assert length(String.codepoints(stored)) <= 160
    end
  end

  describe "an administrator's name with a control character" do
    test "is stripped, not a database error" do
      assert {:ok, %Client{client_name: "ab"}} =
               Clients.register_preregistered(%{
                 client_id: "pre_nul",
                 client_name: "a\u0000b",
                 redirect_uris: ["https://app.example/cb"]
               })
    end

    test "a name of nothing but control characters is stored as no name" do
      assert {:ok, %Client{client_name: nil}} =
               Clients.register_preregistered(%{
                 client_id: "pre_blank",
                 client_name: " \u0000 ",
                 redirect_uris: ["https://app.example/cb"]
               })
    end
  end

  describe "an administrator's input the database cannot hold" do
    test "a NUL byte in the id, the home page or a redirect URI is a changeset error" do
      for attrs <- [
            %{client_id: "pre\0x", redirect_uris: ["https://app.example/cb"]},
            %{client_id: "pre_ok", client_uri: "https://app.example/\0", redirect_uris: []},
            %{client_id: "pre_ok", redirect_uris: ["https://app.example/cb\0"]}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} = Clients.register_preregistered(attrs)
      end

      assert Repo.aggregate(Client, :count) == 0
    end

    test "bytes that are not UTF-8 are a changeset error, and a name of them is no name" do
      assert {:error, %Ecto.Changeset{}} =
               Clients.register_preregistered(%{
                 client_id: <<"pre", 0xFF>>,
                 redirect_uris: ["https://app.example/cb"]
               })

      assert {:ok, %Client{client_name: nil}} =
               Clients.register_preregistered(%{
                 client_id: "pre_bytes",
                 client_name: <<0xFF, ?a>>,
                 redirect_uris: ["https://app.example/cb"]
               })

      assert Clients.clean_name(<<0xFF, ?a>>) == nil
    end

    test "a client is never looked up, or resolved, by such an id", %{ip: ip} do
      for id <- ["a\0b", <<0xFF>>, "https://claude.ai/\0", "dcr_\0"] do
        assert Clients.get_by_client_id(id) == nil
        assert {:error, :unknown_client} = resolve(id, ip)
      end

      assert Stub.calls() == []
    end
  end

  describe "an identifier that is not a URL" do
    test "is looked up and never fetched", %{ip: ip} do
      assert {:error, :unknown_client} = resolve("dcr_nobody", ip)
      assert {:error, :unknown_client} = resolve("", ip)
      assert {:error, :unknown_client} = resolve(nil, ip)
      assert {:error, :unknown_client} = resolve(String.duplicate("x", 3000), ip)
      assert Stub.calls() == []
    end

    test "a registered client is returned as it is", %{ip: ip} do
      {:ok, dcr} =
        Repo.insert(%Client{
          kind: "dcr",
          client_id: "dcr_known",
          redirect_uris: ["https://a.example/cb"]
        })

      assert {:ok, %Client{uuid: uuid}} = resolve("dcr_known", ip)
      assert uuid == dcr.uuid
    end
  end

  describe "a pre-registered client" do
    test "whose id happens to be a URL is not fetched", %{ip: ip} do
      client = client!(%{client_id: "https://client.example/mine.json"})

      assert {:ok, %Client{uuid: uuid}} = resolve(client.client_id, ip)
      assert uuid == client.uuid
      assert Stub.calls() == []
    end
  end

  describe "a metadata document client" do
    test "is fetched once, stored with what the document says, and cached", %{ip: ip} do
      assert {:ok, %Client{} = client} = resolve(@claude, ip)

      assert client.kind == "cimd"
      assert client.client_id == @claude
      assert client.client_name == "Claude"
      assert client.client_uri == "https://claude.ai"
      assert client.redirect_uris == ["https://claude.ai/api/mcp/auth_callback"]
      assert %DateTime{} = client.metadata_fetched_at
      assert DateTime.diff(client.metadata_expires_at, client.metadata_fetched_at) == 3600

      assert {:ok, again} = resolve(@claude, ip)
      assert again.uuid == client.uuid
      assert length(Stub.calls(@claude)) == 1
      assert Repo.aggregate(Client, :count) == 1
    end

    test "the ChatGPT document (private_key_jwt, jwks_uri) gives a usable public client", %{
      ip: ip
    } do
      assert {:ok, client} = resolve(@chatgpt, ip)

      assert client.kind == "cimd"
      assert client.client_name == "ChatGPT"
      assert client.redirect_uris == ["https://chatgpt.com/connector_platform_oauth_redirect"]
    end

    test "is fetched again when the time runs out, and the row follows the document", %{ip: ip} do
      {:ok, first} = resolve(@claude, ip)
      expire!(first)

      Stub.put(
        @claude,
        Stub.claude_document()
        |> Map.put("client_name", "Claude 2")
        |> Map.put("redirect_uris", [
          "https://claude.ai/api/mcp/auth_callback",
          "https://claude.ai/two"
        ])
      )

      assert {:ok, second} = resolve(@claude, ip)
      assert second.uuid == first.uuid
      assert second.client_name == "Claude 2"

      assert second.redirect_uris == [
               "https://claude.ai/api/mcp/auth_callback",
               "https://claude.ai/two"
             ]

      assert DateTime.compare(second.metadata_expires_at, DateTime.utc_now()) == :gt
      assert length(Stub.calls(@claude)) == 2
      assert Repo.aggregate(Client, :count) == 1
    end

    test "when the document is gone while the old row is stale, the client is refused", %{ip: ip} do
      {:ok, first} = resolve(@claude, ip)
      expire!(first)
      Stub.put(@claude, {:error, {:http_status, 404}})

      assert {:error, :fetch_failed} = resolve(@claude, ip)
      # The row stays, stale; it is not used.
      assert Repo.get(Client, first.uuid).client_name == "Claude"
    end

    test "a document that is refused is not remembered: no row, and the next ask fetches again",
         %{
           ip: ip
         } do
      Stub.put(@claude, {:error, :blocked_host})
      assert {:error, :fetch_failed} = resolve(@claude, ip)
      assert {:error, :fetch_failed} = resolve(@claude, ip)

      assert length(Stub.calls(@claude)) == 2
      assert Repo.aggregate(Client, :count) == 0
    end

    test "documents with a secret or the wrong id are refused and not stored", %{ip: ip} do
      Stub.put(@claude, Map.put(Stub.claude_document(), "client_secret", "s"))
      assert {:error, :fetch_failed} = resolve(@claude, ip)

      Stub.put(@claude, Map.put(Stub.claude_document(), "client_id", "https://evil.example/x"))
      assert {:error, :fetch_failed} = resolve(@claude, ip)

      assert Repo.aggregate(Client, :count) == 0
    end

    test "an identifier of the wrong form is refused before anything is fetched", %{ip: ip} do
      assert {:error, :unknown_client} = resolve("http://claude.ai/oauth/x", ip)
      assert {:error, :unknown_client} = resolve("https://claude.ai", ip)
      assert {:error, :unknown_client} = resolve("https://claude.ai/a/../b", ip)
      assert Stub.calls() == []
    end

    test "the cache time follows the response (a short max-age is held to five minutes)", %{
      ip: ip
    } do
      Stub.put(@claude, Stub.claude_document(), [
        {"content-type", "application/json"},
        {"cache-control", "max-age=5"}
      ])

      assert {:ok, client} = resolve(@claude, ip)
      assert DateTime.diff(client.metadata_expires_at, client.metadata_fetched_at) == 300
    end
  end

  describe "the policy" do
    test "a host outside the allow-list is refused before the document is fetched", %{ip: ip} do
      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "other.example")

      assert {:error, :not_allowed} = resolve(@claude, ip)
      assert Stub.calls() == []
      assert Repo.aggregate(Client, :count) == 0
    end

    test "under the allow-list, a document that names a host outside it is refused and not stored",
         %{
           ip: ip
         } do
      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "claude.ai")

      Stub.put(
        @claude,
        Map.put(Stub.claude_document(), "redirect_uris", ["https://elsewhere.example/cb"])
      )

      assert {:error, :not_allowed} = resolve(@claude, ip)
      assert length(Stub.calls(@claude)) == 1
      assert Repo.aggregate(Client, :count) == 0
    end

    test "is judged again for a client that is already stored", %{ip: ip} do
      assert {:ok, _client} = resolve(@claude, ip)

      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "other.example")
      assert {:error, :not_allowed} = resolve(@claude, ip)
      assert length(Stub.calls(@claude)) == 1
    end

    test "a registered client is judged by its redirect hosts", %{ip: ip} do
      Repo.insert!(%Client{
        kind: "dcr",
        client_id: "dcr_a",
        redirect_uris: ["https://evil.example/cb"]
      })

      assert {:ok, _client} = resolve("dcr_a", ip)

      put_setting("api_oauth_client_policy", "allow_list")
      put_setting("api_oauth_client_allow_hosts", "other.example")
      assert {:error, :not_allowed} = resolve("dcr_a", ip)
    end
  end

  describe "a document that cannot be had" do
    setup do
      Logger.put_module_level(Clients, :info)
      on_exit(fn -> Logger.delete_module_level(Clients) end)
    end

    test "leaves a line with the reason, and neither the URL nor the body", %{ip: ip} do
      cases = [
        {fn -> Stub.put(@claude, {:error, :blocked_host}) end, "blocked_host"},
        {fn -> Stub.put(@claude, {:error, {:http_status, 404}}) end, "http_status 404"},
        {fn ->
           Stub.put(@claude, Map.put(Stub.claude_document(), "client_secret", "s3cret-value"))
         end, "client_secret_not_allowed"},
        {fn -> Stub.put(@claude, {:body, "not json at all", [{"content-type", "text/html"}]}) end,
         "not_json"}
      ]

      for {setup, reason} <- cases do
        setup.()
        Limits.reset(:cimd_client, @claude)

        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            assert {:error, :fetch_failed} = resolve(@claude, ip)
          end)

        assert log =~ reason
        refute log =~ "claude.ai"
        refute log =~ "s3cret-value"
        refute log =~ "not json at all"
      end
    end
  end

  describe "two first requests for one new document" do
    test "end with one row and the same client for both" do
      test_pid = self()

      Stub.put(@claude, fn _opts ->
        send(test_pid, {:started, self()})

        receive do
          :go -> :ok
        end

        path = Path.join(System.tmp_dir!(), "pk_cimd_race_#{System.unique_integer([:positive])}")
        File.write!(path, Stub.claude_body())

        {:ok,
         %{
           path: path,
           filename: "client.json",
           url: @claude,
           headers: [{"content-type", "application/json"}, {"cache-control", "max-age=600"}]
         }}
      end)

      tasks = for _n <- 1..3, do: Task.async(fn -> resolve(@claude, unique_ip()) end)

      pids =
        for _n <- 1..3 do
          assert_receive {:started, pid}, 2_000
          pid
        end

      # All three downloads are in flight before any of them answers: all three go on to insert.
      for pid <- pids, do: send(pid, :go)
      results = Enum.map(tasks, &Task.await/1)

      assert [{:ok, %Client{uuid: uuid}} | _] = results
      assert Enum.all?(results, &match?({:ok, %Client{uuid: ^uuid}}, &1))
      assert Repo.aggregate(Client, :count) == 1
    end
  end

  describe "the limits" do
    test "a client is fetched at most so many times a minute, whatever the network", %{ip: _ip} do
      put_setting("api_oauth_cimd_client_per_min", 2)
      Stub.put(@claude, {:error, {:http_status, 500}})

      assert {:error, :fetch_failed} = resolve(@claude, unique_ip())
      assert {:error, :fetch_failed} = resolve(@claude, unique_ip())
      assert {:error, :rate_limited} = resolve(@claude, unique_ip())
      assert length(Stub.calls(@claude)) == 2
    end

    test "a network may start so many fetches a minute, whatever the clients", %{ip: ip} do
      put_setting("api_oauth_cimd_per_min", 2)

      for n <- 1..2 do
        url = "https://client.example/#{n}-#{System.unique_integer([:positive])}"
        assert {:error, :fetch_failed} = resolve(url, ip)
      end

      assert {:error, :rate_limited} =
               resolve("https://client.example/third-#{System.unique_integer([:positive])}", ip)

      # A stored client costs nothing.
      assert {:ok, _client} = resolve(@claude, unique_ip())
      assert {:ok, _client} = resolve(@claude, ip)
    end

    test "no more than four fetches run at once", %{ip: _ip} do
      test_pid = self()

      blocking = fn _opts ->
        send(test_pid, {:started, self()})

        receive do
          :go -> {:error, {:http_status, 500}}
        end
      end

      urls =
        for n <- 1..5,
            do: "https://client.example/slow-#{n}-#{System.unique_integer([:positive])}"

      for url <- urls, do: Stub.put(url, blocking)

      running =
        for url <- Enum.take(urls, 4) do
          task = Task.async(fn -> resolve(url, unique_ip()) end)
          assert_receive {:started, _pid}, 2_000
          task
        end

      assert {:error, :busy} = resolve(Enum.at(urls, 4), unique_ip())
      assert Stub.calls(Enum.at(urls, 4)) == []

      Stub.put(Enum.at(urls, 4), {:error, {:http_status, 500}})
      for pid <- started_pids(), do: send(pid, :go)
      assert Enum.map(running, &Task.await/1) == List.duplicate({:error, :fetch_failed}, 4)

      # A place is free again.
      assert {:error, :fetch_failed} = resolve(Enum.at(urls, 4), unique_ip())
    end
  end

  describe "the number of downloads at once is a setting" do
    test "a smaller number closes the places sooner, a larger one opens more" do
      test_pid = self()

      blocking = fn _opts ->
        send(test_pid, {:started, self()})

        receive do
          :go -> {:error, {:http_status, 500}}
        end
      end

      url = fn n -> "https://client.example/pool-#{n}-#{System.unique_integer([:positive])}" end
      urls = for n <- 1..7, do: url.(n)
      for u <- urls, do: Stub.put(u, blocking)

      put_setting("api_oauth_cimd_concurrency", 2)

      two =
        for u <- Enum.take(urls, 2) do
          task = Task.async(fn -> resolve(u, unique_ip()) end)
          assert_receive {:started, _pid}, 2_000
          task
        end

      assert {:error, :busy} = resolve(Enum.at(urls, 2), unique_ip())
      assert Stub.calls(Enum.at(urls, 2)) == []

      put_setting("api_oauth_cimd_concurrency", 6)

      more =
        for u <- Enum.slice(urls, 2, 4) do
          task = Task.async(fn -> resolve(u, unique_ip()) end)
          assert_receive {:started, _pid}, 2_000
          task
        end

      assert {:error, :busy} = resolve(Enum.at(urls, 6), unique_ip())

      for pid <- started_pids(), do: send(pid, :go)
      assert Enum.map(two ++ more, &Task.await/1) == List.duplicate({:error, :fetch_failed}, 6)
    end

    test "a stored number above what the supervisor admits is held to it" do
      put_setting("api_oauth_cimd_concurrency", 500)
      assert Cimd.concurrency() == 64
      put_setting("api_oauth_cimd_concurrency", 3)
      assert Cimd.concurrency() == 3
    end
  end

  defp started_pids do
    # The four messages were consumed by `assert_receive`; ask the tasks of the supervisor.
    PhoenixKit.API.OAuth.FetchSupervisor |> Task.Supervisor.children()
  end

  defp expire!(%Client{} = client) do
    past = DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.truncate(:second)

    client
    |> Ecto.Changeset.change(metadata_expires_at: past)
    |> Repo.update!()
  end
end
