defmodule PhoenixKit.API.OAuth.ClientPolicy do
  @moduledoc """
  Which clients may ask for access, and which of them work at once (Settings -> API).

    * Policy `approval` (`api_oauth_client_policy`; the default, and what a missing or empty
      setting reads as): a client whose every host is in `api_oauth_client_allow_hosts` connects
      at once; any other one is let through sign-in and consent but its connection waits for an
      owner's approval before it can call anything. An empty list approves nobody in advance.
    * Policy `any`: any https client, trusted at once; the person sees the host the browser goes
      back to on the consent screen and decides.
    * Policy `allow_list`: only a client whose every host is in `api_oauth_client_allow_hosts`.
      The hosts of a client are the host of its `client_id` (when that is a URL, a metadata
      document) and the host of each of its redirect URIs.

  Hosts are compared in lower case and without a final dot, whole (no wildcards); an entry
  written as a URL, or with a port, counts as its host. A pre-registered client (the
  administrator typed it in) is exempt from the list.
  A list that cannot be read refuses (fail closed) under both policies that use it, and so does a
  policy value nobody knows.

  The policy is judged again every time a client is used: when its authorization request is
  checked (`PhoenixKit.API.OAuth.Clients.resolve/2`), when the person answers the consent screen,
  and when a code or a refresh token is exchanged, so a client that stops being allowed can
  neither be connected nor, under `allow_list`, keep a connection alive through refreshes (see the
  next paragraph for `approval`). (An access token already
  issued lives out its lifetime; the person or an administrator can end the grant.)

  Taking a host off the list or tightening the policy does not end what already works: a
  connection that was trusted or approved keeps its tokens, and under `approval` a refresh is not
  blocked (it is under `allow_list`). To withdraw trust from an application, disconnect its
  connections (delete the client, or "Disconnect" on the connection).
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.RedirectUri

  @doc """
  Whether a client of `kind` (`"cimd"`, `"dcr"`, `"preregistered"`) with this `client_id` and
  these redirect URIs may use the server at all: everything `judge/3` does not refuse. Call it
  with `[]` for the URIs before they are known (a document not yet fetched): the host of the
  `client_id` has to pass in any case.
  """
  @spec allowed?(String.t(), String.t(), [String.t()]) :: boolean()
  def allowed?(kind, client_id, redirect_uris),
    do: judge(kind, client_id, redirect_uris) != :refused

  @typedoc "`:trusted` works at once, `:needs_approval` waits for an owner, `:refused` is kept out."
  @type verdict :: :trusted | :needs_approval | :refused

  @doc """
  What the policy says of a client: `:trusted` (its connection works at once), `:needs_approval`
  (it may connect, but nothing runs until an owner approves the connection) or `:refused`.

    * a pre-registered client, and every client under `any`: `:trusted`;
    * `allow_list`: `:trusted` when every host is listed, else `:refused`;
    * `approval`: `:trusted` when every host is listed, else `:needs_approval`;
    * a list that cannot be read: `:refused` under both policies that use it.
  """
  @spec judge(String.t(), String.t(), [String.t()]) :: verdict()
  def judge("preregistered", _client_id, _redirect_uris), do: :trusted

  def judge(kind, client_id, redirect_uris) do
    case Config.oauth_client_policy() do
      :any -> :trusted
      :allow_list -> kind |> listing(client_id, redirect_uris) |> allow_list_verdict()
      :approval -> kind |> listing(client_id, redirect_uris) |> approval_verdict()
    end
  end

  defp allow_list_verdict(:listed), do: :trusted
  defp allow_list_verdict(_unlisted_or_unreadable), do: :refused

  defp approval_verdict(:listed), do: :trusted
  defp approval_verdict(:unlisted), do: :needs_approval
  defp approval_verdict(:unreadable), do: :refused

  defp listing(kind, client_id, redirect_uris) do
    hosts = hosts(kind, client_id, redirect_uris)

    case Config.fetch_oauth_allow_hosts() do
      {:ok, entries} ->
        entries = normalize(entries)
        if hosts != [] and Enum.all?(hosts, &(&1 in entries)), do: :listed, else: :unlisted

      :unreadable ->
        :unreadable
    end
  end

  # The client id is a URL for a metadata document client; for a registered one it is an opaque
  # string with no host.
  defp hosts("cimd", client_id, redirect_uris),
    do: Enum.uniq(id_host(client_id) ++ Enum.flat_map(redirect_uris, &redirect_host/1))

  defp hosts(_kind, _client_id, redirect_uris),
    do: Enum.uniq(Enum.flat_map(redirect_uris, &redirect_host/1))

  defp id_host(client_id) do
    case URI.parse(client_id) do
      %URI{host: host} when is_binary(host) and host != "" -> [host_name(host)]
      _ -> []
    end
  end

  defp redirect_host(uri) do
    case RedirectUri.host(uri) do
      host when is_binary(host) -> [host_name(host)]
      nil -> []
    end
  end

  defp normalize(entries) do
    entries
    |> Enum.map(&entry_host/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp entry_host(entry) do
    entry = entry |> String.trim() |> String.downcase()

    if String.contains?(entry, "://") do
      case URI.parse(entry) do
        %URI{host: host} when is_binary(host) -> host_name(host)
        _ -> ""
      end
    else
      bare_host(entry)
    end
  end

  # `host`, `host:port`, `[v6]` and `[v6]:port` (an IPv6 literal is written in brackets, the host
  # of a URI is not).
  defp bare_host(entry) do
    case Regex.run(~r/^\[([^\]]+)\](?::\d+)?$/, entry) do
      [_whole, v6] -> host_name(v6)
      nil -> entry |> String.replace(~r/^([^:\[\]]+):\d+$/, "\\1") |> host_name()
    end
  end

  # A host in lower case and without the final dot: `evil.example.` is the same name to the
  # resolver as `evil.example`.
  defp host_name(host), do: host |> String.downcase() |> String.trim_trailing(".")
end
