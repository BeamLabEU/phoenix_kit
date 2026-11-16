defmodule PhoenixKit.API.OAuth.Cimd do
  @moduledoc """
  Client ID Metadata Documents (the OAuth Client ID Metadata Document draft): a client names itself
  by an `https` URL, and the document at that URL says who it is and where its redirects go.
  ChatGPT and Claude both use it.

  ## The identifier

  `validate_client_id/1` judges the *form* of the URL before anything is fetched: `https`, a host,
  a path (not just the host), no fragment, no userinfo, no `.` or `..` segment (written plainly or
  percent-encoded), the port 443, no whitespace or control character, 2048 bytes at most. A
  query string is allowed (the draft discourages it, it does not forbid it).

  ## The document

  `parse/2` reads the JSON object and keeps three things: `client_name`, `client_uri` (only when
  an `https` URL) and `redirect_uris` (required, at most ten, each one `PhoenixKit.API.OAuth.RedirectUri`
  accepts). The document's `client_id` must be the URL it was fetched from, character for
  character. Everything else (`jwks_uri`, `grant_types`, `logo_uri`, `token_endpoint_auth_method`
  `private_key_jwt`...) is **ignored, not refused**: the live ChatGPT document carries them, and
  the client is treated as public (`none` and PKCE) either way. What is refused is a shared secret:
  a `client_secret` or `client_secret_expires_at` property, or a `token_endpoint_auth_method` that
  starts with `client_secret_` (the draft forbids methods on a secret the server would have to keep).

  ## The fetch

  `fetch/1` downloads through `PhoenixKit.Modules.Storage.RemoteFetch`: https only, port 443, every
  address the name resolves to must be public, the connection goes to the address that was checked
  (so a name that resolves to a private address, or changes its answer after the check, reaches
  nothing), **no redirect is followed**, 64 KB at most whatever the server claims, 5 seconds in
  all, and the response must say it is JSON. The download runs in a task of
  `PhoenixKit.API.OAuth.FetchSupervisor`, at most four at a time (`{:error, :busy}` beyond that).
  The temporary file is always removed.

  `fetch/1` returns the document and `ttl`, the seconds it may be cached: `max-age` of
  `Cache-Control`, one hour without one, and never less than 5 minutes nor more than a day. A
  failed fetch is a refusal that is **not remembered** (`PhoenixKit.API.OAuth.Clients` keeps only
  what it fetched).

  The downloader is `RemoteFetch`; the `:oauth_cimd_downloader` application setting replaces it
  with another module that has `download/2` of the same contract (for tests: nothing else should
  set it).
  """

  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.Modules.Storage.RemoteFetch

  @max_bytes 65_536
  @timeout 5_000
  # The caller waits a little longer than the download's own deadline, then kills the task.
  @outer_timeout 8_000
  @max_redirect_uris 10
  @max_client_id 2048
  @ttl_default 3_600
  @ttl_min 300
  @ttl_max 86_400
  @supervisor PhoenixKit.API.OAuth.FetchSupervisor

  @type document :: %{
          client_name: String.t() | nil,
          client_uri: String.t() | nil,
          redirect_uris: [String.t()]
        }

  @doc "Whether `client_id` has the form of a metadata document URL (see the moduledoc)."
  @spec validate_client_id(term()) :: :ok | {:error, :invalid_client_id}
  def validate_client_id(client_id) when is_binary(client_id) do
    if valid_form?(client_id), do: :ok, else: {:error, :invalid_client_id}
  end

  def validate_client_id(_client_id), do: {:error, :invalid_client_id}

  defp valid_form?(url) when byte_size(url) in 1..@max_client_id do
    with false <- Regex.match?(~r/[\x00-\x20\x7F\\]/, url),
         {:ok, %URI{} = uri} <- URI.new(url) do
      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
        is_nil(uri.userinfo) and is_nil(uri.fragment) and uri.port == 443 and
        is_binary(uri.path) and uri.path != "" and not dot_segment?(uri.path)
    else
      _ -> false
    end
  end

  defp valid_form?(_url), do: false

  defp dot_segment?(path) do
    path
    |> String.split("/")
    |> Enum.any?(fn segment ->
      URI.decode(segment) in [".", ".."]
    end)
  rescue
    # A broken percent-escape is not a form to trust.
    _ -> true
  end

  @doc "Reads a document body fetched from `client_id` (see the moduledoc for what is kept and refused)."
  @spec parse(String.t(), binary()) ::
          {:ok, document()}
          | {:error,
             :invalid_document
             | :client_id_mismatch
             | :client_secret_not_allowed
             | :invalid_redirect_uris}
  def parse(client_id, body) when is_binary(client_id) and is_binary(body) do
    with {:ok, document} <- decode(body),
         :ok <- same_id(document, client_id),
         :ok <- no_secret(document),
         {:ok, uris} <- redirect_uris(document) do
      {:ok,
       %{
         client_name: Clients.clean_name(document["client_name"]),
         client_uri: Clients.clean_uri(document["client_uri"]),
         redirect_uris: uris
       }}
    end
  end

  defp decode(body) do
    with true <- String.valid?(body),
         {:ok, %{} = document} <- JSON.decode(body) do
      {:ok, document}
    else
      _ -> {:error, :invalid_document}
    end
  end

  defp same_id(%{"client_id" => client_id}, client_id), do: :ok
  defp same_id(_document, _client_id), do: {:error, :client_id_mismatch}

  defp no_secret(document) do
    if Map.has_key?(document, "client_secret") or
         Map.has_key?(document, "client_secret_expires_at") or
         secret_method?(document["token_endpoint_auth_method"]),
       do: {:error, :client_secret_not_allowed},
       else: :ok
  end

  defp secret_method?(method) when is_binary(method),
    do: method |> String.downcase() |> String.starts_with?("client_secret_")

  defp secret_method?(_method), do: false

  defp redirect_uris(%{"redirect_uris" => [_ | _] = uris})
       when length(uris) <= @max_redirect_uris do
    if Enum.all?(uris, &RedirectUri.valid?/1),
      do: {:ok, uris},
      else: {:error, :invalid_redirect_uris}
  end

  defp redirect_uris(_document), do: {:error, :invalid_redirect_uris}

  @doc """
  Fetches and reads the document of `client_id`. `{:ok, document}` carries `ttl` besides the
  fields of `t:document/0`. Refusals: `:invalid_client_id` (nothing was fetched), `:busy` (four
  downloads already run), `:unavailable` (no download supervisor), `{:fetch_failed, reason}` (the
  reason of `RemoteFetch`, `:too_large` for a body over the limit), `:not_json` (the response is
  not `application/json`) and the refusals of `parse/2`.
  """
  @spec fetch(term()) :: {:ok, map()} | {:error, term()}
  def fetch(client_id) do
    with :ok <- validate_client_id(client_id),
         {:ok, body, headers} <- download(client_id),
         :ok <- json?(headers),
         {:ok, document} <- parse(client_id, body) do
      {:ok, Map.put(document, :ttl, ttl(headers))}
    end
  end

  defp download(url) do
    opts = [max_bytes: @max_bytes, timeout: @timeout, max_redirects: 0, return_headers: true]

    case run(fn -> downloader().download(url, opts) end) do
      {:ok, {:ok, %{path: path} = result}} -> read(path, Map.get(result, :headers, []))
      {:ok, {:error, reason}} -> {:error, {:fetch_failed, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp read(path, headers) do
    with {:ok, %File.Stat{size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, body} <- File.read(path) do
      {:ok, body, headers}
    else
      {:ok, %File.Stat{}} -> {:error, {:fetch_failed, :too_large}}
      {:error, reason} -> {:error, {:fetch_failed, {:read_failed, reason}}}
    end
  after
    File.rm(path)
  end

  defp downloader, do: Application.get_env(:phoenix_kit, :oauth_cimd_downloader, RemoteFetch)

  # The download runs in a task of its own supervisor (`max_children` is the concurrency limit).
  defp run(fun) do
    parent = self()
    ref = make_ref()

    start =
      if Process.whereis(@supervisor),
        do: Task.Supervisor.start_child(@supervisor, fn -> send(parent, {ref, fun.()}) end),
        else: {:error, :unavailable}

    case start do
      {:ok, pid} -> await(pid, ref)
      {:error, :max_children} -> {:error, :busy}
      _other -> {:error, :unavailable}
    end
  end

  defp await(pid, ref) do
    monitor = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, {:fetch_failed, :crashed}}
    after
      @outer_timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, {:fetch_failed, :timeout}}
    end
  end

  defp json?(headers) do
    type =
      headers
      |> header("content-type")
      |> to_string()
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    if type == "application/json" or String.ends_with?(type, "+json"),
      do: :ok,
      else: {:error, :not_json}
  end

  defp ttl(headers) do
    directives =
      headers
      |> header("cache-control")
      |> to_string()
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    # `no-store` and `no-cache` win over any `max-age` beside them: the shortest time we allow
    # ourselves to remember a document.
    seconds =
      if Enum.any?(directives, &(&1 in ["no-store", "no-cache"])),
        do: 0,
        else: Enum.find_value(directives, @ttl_default, &max_age/1)

    seconds
    |> max(@ttl_min)
    |> min(@ttl_max)
  end

  defp max_age("max-age=" <> seconds) do
    case Integer.parse(seconds) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp max_age(_directive), do: nil

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) -> if String.downcase(key) == name, do: value
      _other -> nil
    end)
  end

  defp header(_headers, _name), do: nil
end
