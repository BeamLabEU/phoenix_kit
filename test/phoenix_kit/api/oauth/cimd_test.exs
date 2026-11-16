defmodule PhoenixKit.API.OAuth.CimdTest do
  @moduledoc """
  Client ID Metadata Documents (`PhoenixKit.API.OAuth.Cimd`): the shape of the `client_id` URL
  (judged before anything is fetched), what a fetched document may say, and how it is fetched
  (the options the downloader is given). The HTTP layer is a stub; no test here opens a socket.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.OAuth.Cimd
  alias PhoenixKit.API.OAuthCimdStub, as: Stub

  @claude Stub.claude_id()
  @chatgpt Stub.chatgpt_id()

  describe "validate_client_id/1" do
    test "accepts the identifiers of the two live clients" do
      assert :ok = Cimd.validate_client_id(@claude)
      assert :ok = Cimd.validate_client_id(@chatgpt)
      assert :ok = Cimd.validate_client_id("https://app.example:443/client.json")
      assert :ok = Cimd.validate_client_id("https://APP.example/Client")
    end

    test "refuses what the draft forbids, before anything is fetched" do
      for bad <- [
            "http://app.example/client.json",
            "ftp://app.example/client.json",
            "app.example/client.json",
            "https://app.example",
            "https://app.example/client.json#frag",
            "https://user@app.example/client.json",
            "https://user:pw@app.example/client.json",
            "https://app.example/a/../client.json",
            "https://app.example/a/./client.json",
            "https://app.example/%2e%2e/client.json",
            "https://app.example/a/%2E/client.json",
            "https://app.example:8443/client.json",
            "https://app.example/client json",
            "https://app.example/a\\b",
            "https://app.example/a\nb",
            "https:///client.json",
            "https://" <> String.duplicate("a", 2100) <> ".example/c",
            "",
            nil,
            123
          ] do
        assert {:error, :invalid_client_id} = Cimd.validate_client_id(bad), inspect(bad)
      end
    end

    test "a query string is not refused (the draft discourages it)" do
      assert :ok = Cimd.validate_client_id("https://app.example/client.json?v=2")
    end
  end

  describe "parse/2" do
    test "the live Claude document" do
      assert {:ok, doc} = Cimd.parse(@claude, Stub.claude_body())

      assert doc == %{
               client_name: "Claude",
               client_uri: "https://claude.ai",
               redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]
             }
    end

    test "the live ChatGPT document, private_key_jwt and jwks_uri included, is not refused" do
      assert {:ok, doc} = Cimd.parse(@chatgpt, Stub.chatgpt_body())

      assert doc.client_name == "ChatGPT"
      # The live document writes its home page with the slash.
      assert doc.client_uri == "https://chatgpt.com/"
      assert doc.redirect_uris == ["https://chatgpt.com/connector_platform_oauth_redirect"]
      # Only what is used is kept: nothing of the key material or the logo.
      assert Map.keys(doc) |> Enum.sort() == [:client_name, :client_uri, :redirect_uris]
    end

    test "the identifier in the document must be the URL it was fetched from, exactly" do
      for id <- [@claude <> "/", String.replace(@claude, "claude.ai", "evil.example"), nil, 7] do
        body = Stub.claude_document() |> Map.put("client_id", id) |> JSON.encode!()
        assert {:error, :client_id_mismatch} = Cimd.parse(@claude, body), inspect(id)
      end

      body = Stub.claude_document() |> Map.delete("client_id") |> JSON.encode!()
      assert {:error, :client_id_mismatch} = Cimd.parse(@claude, body)
    end

    test "a shared secret in the document is refused" do
      for extra <- [
            %{"client_secret" => "s3cret"},
            %{"client_secret_expires_at" => 0},
            %{"client_secret" => nil},
            %{"token_endpoint_auth_method" => "client_secret_basic"},
            %{"token_endpoint_auth_method" => "client_secret_post"},
            %{"token_endpoint_auth_method" => "client_secret_jwt"}
          ] do
        body = Stub.claude_document() |> Map.merge(extra) |> JSON.encode!()

        assert {:error, :client_secret_not_allowed} = Cimd.parse(@claude, body),
               inspect(extra)
      end
    end

    test "other authentication methods are not a reason to refuse: they are ignored" do
      for method <- ["none", "private_key_jwt", "tls_client_auth", "whatever", 5, nil] do
        body =
          Stub.claude_document()
          |> Map.put("token_endpoint_auth_method", method)
          |> JSON.encode!()

        assert {:ok, _doc} = Cimd.parse(@claude, body), inspect(method)
      end
    end

    test "redirect URIs follow the redirect rules and are required" do
      for bad <- [
            nil,
            [],
            "https://claude.ai/cb",
            [5],
            ["cursor://anysphere.cursor-retrieval/oauth"],
            ["http://claude.ai/cb"],
            ["https://claude.ai/cb#frag"],
            ["https://*.claude.ai/cb"],
            ["https://claude.ai/cb", "vscode://x/y"],
            Enum.map(1..11, &"https://claude.ai/cb/#{&1}")
          ] do
        body = Stub.claude_document() |> Map.put("redirect_uris", bad) |> JSON.encode!()
        assert {:error, :invalid_redirect_uris} = Cimd.parse(@claude, body), inspect(bad)
      end

      loopback = ["http://127.0.0.1/cb", "http://[::1]/cb", "https://claude.ai/cb"]
      body = Stub.claude_document() |> Map.put("redirect_uris", loopback) |> JSON.encode!()
      assert {:ok, %{redirect_uris: ^loopback}} = Cimd.parse(@claude, body)
    end

    test "the name is cleaned and cut, and a name that is not text is left out" do
      long = String.duplicate("n", 300)

      body =
        Stub.claude_document()
        |> Map.put("client_name", "  Cla\u0000ude\u202E \n" <> long)
        |> JSON.encode!()

      assert {:ok, %{client_name: name}} = Cimd.parse(@claude, body)
      assert String.length(name) == 160
      assert String.starts_with?(name, "Claude")
      refute name =~ ~r/[\p{C}\p{Zl}\p{Zp}]/u

      body = Stub.claude_document() |> Map.put("client_name", 42) |> JSON.encode!()
      assert {:ok, %{client_name: nil}} = Cimd.parse(@claude, body)
    end

    test "client_uri is kept only when it is an https URL" do
      for {uri, expected} <- [
            {"https://claude.ai", "https://claude.ai"},
            {"http://claude.ai", nil},
            {"javascript:alert(1)", nil},
            {"https://claude.ai/ a", nil},
            {7, nil}
          ] do
        body = Stub.claude_document() |> Map.put("client_uri", uri) |> JSON.encode!()
        assert {:ok, %{client_uri: ^expected}} = Cimd.parse(@claude, body), inspect(uri)
      end
    end

    test "what is not a JSON object is refused" do
      for body <- ["not json", "[]", "\"x\"", "null", "{", <<255, 254>>, ""] do
        assert {:error, :invalid_document} = Cimd.parse(@claude, body), inspect(body)
      end
    end
  end

  describe "fetch/1 with the stubbed HTTP layer" do
    setup do
      Stub.install!()
    end

    test "asks for a small, quick, redirect-free download that returns the headers" do
      Stub.put(@claude, Stub.claude_document())

      assert {:ok, %{client_name: "Claude"}} = Cimd.fetch(@claude)

      assert [{@claude, opts}] = Stub.calls()
      assert opts[:max_bytes] == 65_536
      assert opts[:timeout] == 5_000
      assert opts[:max_redirects] == 0
      assert opts[:return_headers] == true
      refute opts[:allow_http]
    end

    test "the two live documents, served with the headers they were saved with, are accepted" do
      live = [{"content-type", "application/json"}, {"cache-control", "public, max-age=300"}]
      Stub.put(@claude, {:body, Stub.claude_body(), live})
      Stub.put(@chatgpt, {:body, Stub.chatgpt_body(), live})

      assert {:ok, %{client_name: "Claude", ttl: 300}} = Cimd.fetch(@claude)
      assert {:ok, %{client_name: "ChatGPT", ttl: 300}} = Cimd.fetch(@chatgpt)
    end

    test "never fetches an identifier whose form is wrong" do
      assert {:error, :invalid_client_id} = Cimd.fetch("http://app.example/client.json")
      assert {:error, :invalid_client_id} = Cimd.fetch("https://app.example/../client.json")
      assert Stub.calls() == []
    end

    test "removes the temporary file it was given, on success and on a refusal" do
      test_pid = self()

      write = fn body ->
        path = Path.join(System.tmp_dir!(), "pk_cimd_own_#{System.unique_integer([:positive])}")
        File.write!(path, body)
        send(test_pid, {:path, path})

        {:ok,
         %{
           path: path,
           filename: "c.json",
           url: @claude,
           headers: [{"content-type", "application/json"}]
         }}
      end

      Stub.put(@claude, fn _opts -> write.(JSON.encode!(Stub.claude_document())) end)
      assert {:ok, _doc} = Cimd.fetch(@claude)
      assert_received {:path, path}
      refute File.exists?(path)

      Stub.put(@claude, fn _opts -> write.("not json") end)
      assert {:error, :invalid_document} = Cimd.fetch(@claude)
      assert_received {:path, path}
      refute File.exists?(path)
    end

    test "a refused download is a refusal, with the reason" do
      for reason <- [
            :blocked_host,
            :nxdomain,
            :too_large,
            :timeout,
            :too_many_redirects,
            {:http_status, 404},
            {:connect_failed, :econnrefused}
          ] do
        Stub.put(@claude, {:error, reason})
        assert {:error, {:fetch_failed, ^reason}} = Cimd.fetch(@claude)
      end
    end

    test "only a JSON content type is read" do
      for headers <- [
            [{"content-type", "text/html"}],
            [{"content-type", "text/plain; charset=utf-8"}],
            []
          ] do
        Stub.put(@claude, Stub.claude_document(), headers)
        assert {:error, :not_json} = Cimd.fetch(@claude), inspect(headers)
      end

      for type <- ["application/json", "Application/JSON; charset=utf-8", "application/ld+json"] do
        Stub.put(@claude, Stub.claude_document(), [{"Content-Type", type}])
        assert {:ok, _doc} = Cimd.fetch(@claude), type
      end
    end

    test "a body bigger than the limit is refused even if the downloader let it through" do
      Stub.put(
        @claude,
        {:body, String.duplicate(" ", 65_537) <> "{}", [{"content-type", "application/json"}]}
      )

      assert {:error, {:fetch_failed, :too_large}} = Cimd.fetch(@claude)
    end

    test "how long the document may be cached follows Cache-Control, between 5 minutes and a day" do
      for {cache_control, ttl} <- [
            {"max-age=600", 600},
            {"public, max-age=7200", 7200},
            {"max-age=10", 300},
            {"max-age=0", 300},
            {"no-store", 300},
            {"no-cache", 300},
            {"max-age=600, no-store", 300},
            {"no-store, max-age=600", 300},
            {"public, max-age=600, no-cache", 300},
            {"max-age=banana, no-store", 300},
            {"max-age=999999999", 86_400},
            {"max-age=banana", 3600},
            {nil, 3600}
          ] do
        headers =
          [{"content-type", "application/json"}] ++
            if(cache_control, do: [{"Cache-Control", cache_control}], else: [])

        Stub.put(@claude, Stub.claude_document(), headers)
        assert {:ok, %{ttl: ^ttl}} = Cimd.fetch(@claude), inspect(cache_control)
      end
    end
  end
end
