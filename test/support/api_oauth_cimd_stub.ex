defmodule PhoenixKit.API.OAuthCimdStub do
  @moduledoc """
  The HTTP layer of the client metadata documents (`PhoenixKit.API.OAuth.Cimd`) for the tests: a
  downloader with the contract of `PhoenixKit.Modules.Storage.RemoteFetch.download/2` that serves
  documents from memory, so no test opens a socket for them.

  `install!/0` (call it from a `setup`, it starts an Agent under the test) points
  `:oauth_cimd_downloader` at this module and removes the setting afterwards. `put/2` says what a
  URL answers, `calls/1` lists what was asked of it (the URL and the options the code passed, so a
  test can check the limits the code asks for).

  The fixtures are shaped like the live documents of the two clients that matter:
  `claude_document/0` (`https://claude.ai/oauth/mcp-oauth-client-metadata`: auth method `none`,
  redirect `https://claude.ai/api/mcp/auth_callback`) and `chatgpt_document/0`
  (`https://chatgpt.com/oauth/client.json`: `private_key_jwt`, a `jwks_uri`, redirect
  `https://chatgpt.com/connector_platform_oauth_redirect`).
  """

  use Agent

  @claude_id "https://claude.ai/oauth/mcp-oauth-client-metadata"
  @chatgpt_id "https://chatgpt.com/oauth/client.json"

  def claude_id, do: @claude_id
  def chatgpt_id, do: @chatgpt_id

  def claude_document do
    %{
      "client_id" => @claude_id,
      "client_name" => "Claude",
      "client_uri" => "https://claude.ai",
      "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
      "grant_types" => [
        "authorization_code",
        "refresh_token",
        "urn:ietf:params:oauth:grant-type:jwt-bearer"
      ],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }
  end

  def chatgpt_document do
    %{
      "client_id" => @chatgpt_id,
      "client_name" => "ChatGPT",
      "client_uri" => "https://chatgpt.com",
      "logo_uri" => "https://chatgpt.com/logo.png",
      "redirect_uris" => ["https://chatgpt.com/connector_platform_oauth_redirect"],
      "grant_types" => [
        "authorization_code",
        "refresh_token",
        "urn:ietf:params:oauth:grant-type:jwt-bearer"
      ],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "private_key_jwt",
      "token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"],
      "token_endpoint_auth_signing_alg" => "RS256",
      "jwks_uri" => "https://chatgpt.com/oauth/jwks.json"
    }
  end

  @doc "Starts the stub under the test and makes the code use it."
  def install! do
    ExUnit.Callbacks.start_supervised!(%{
      id: __MODULE__,
      start: {Agent, :start_link, [fn -> %{responses: %{}, calls: []} end, [name: __MODULE__]]}
    })

    Application.put_env(:phoenix_kit, :oauth_cimd_downloader, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:phoenix_kit, :oauth_cimd_downloader)
    end)

    :ok
  end

  @headers [
    {"content-type", "application/json"},
    {"cache-control", "max-age=3600"}
  ]

  @doc """
  Sets the answer of `url`: a map (a document, sent as JSON with ok headers), `{:body, binary,
  headers}`, `{:error, reason}` (what `RemoteFetch.download/2` returns on failure) or a function
  of arity 1 called with the options (it may block; the code under test calls it in a task).
  """
  def put(url, %{} = document), do: put(url, {:body, JSON.encode!(document), @headers})

  def put(url, answer),
    do: Agent.update(__MODULE__, &put_in(&1, [:responses, url], answer))

  @doc "A document with a header list of its own."
  def put(url, %{} = document, headers), do: put(url, {:body, JSON.encode!(document), headers})

  @doc "`[{url, opts}]` of the downloads asked for, oldest first; of one `url` when given."
  def calls(url \\ nil) do
    calls = Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    if url, do: Enum.filter(calls, &(elem(&1, 0) == url)), else: calls
  end

  @doc "The contract of `RemoteFetch.download/2`."
  def download(url, opts) do
    answer =
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.get(state.responses, url, {:error, {:http_status, 404}}),
         %{state | calls: [{url, opts} | state.calls]}}
      end)

    case answer do
      {:body, body, headers} -> write(url, body, headers)
      {:error, _reason} = error -> error
      fun when is_function(fun, 1) -> fun.(opts)
    end
  end

  defp write(url, body, headers) do
    path = Path.join(System.tmp_dir!(), "pk_cimd_stub_#{System.unique_integer([:positive])}")
    File.write!(path, body)
    {:ok, %{path: path, filename: "client.json", url: url, headers: headers}}
  end
end
