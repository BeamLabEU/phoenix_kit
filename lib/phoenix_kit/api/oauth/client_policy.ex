defmodule PhoenixKit.API.OAuth.ClientPolicy do
  @moduledoc """
  Which clients may ask for access (Settings -> API).

    * Policy `any` (`api_oauth_client_policy`, the default): any https client; the person sees
      the host the browser goes back to on the consent screen and decides.
    * Policy `allow_list`: only a client whose every host is in `api_oauth_client_allow_hosts`.
      The hosts of a client are the host of its `client_id` (when that is a URL, a metadata
      document) and the host of each of its redirect URIs.

  Hosts are compared in lower case and without a final dot, whole (no wildcards); an entry
  written as a URL, or with a port, counts as its host. A pre-registered client (the
  administrator typed it in) is exempt from the list.
  A list that cannot be read refuses (fail closed), and so does a policy value nobody knows.

  The policy is judged again every time a client is used: when its authorization request is
  checked (`PhoenixKit.API.OAuth.Clients.resolve/2`), when the person answers the consent screen,
  and when a code or a refresh token is exchanged, so a client that stops being allowed can
  neither be connected nor keep a connection alive through refreshes. (An access token already
  issued lives out its lifetime; the person or an administrator can end the grant.)
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.RedirectUri

  @doc """
  Whether a client of `kind` (`"cimd"`, `"dcr"`, `"preregistered"`) with this `client_id` and
  these redirect URIs may use the server. Call it with `[]` for the URIs before they are known
  (a document not yet fetched): the host of the `client_id` has to pass in any case.
  """
  @spec allowed?(String.t(), String.t(), [String.t()]) :: boolean()
  def allowed?("preregistered", _client_id, _redirect_uris), do: true

  def allowed?(kind, client_id, redirect_uris) do
    case Config.oauth_client_policy() do
      :any -> true
      :allow_list -> listed?(hosts(kind, client_id, redirect_uris))
    end
  end

  defp listed?(hosts) do
    case Config.fetch_oauth_allow_hosts() do
      {:ok, entries} ->
        entries = normalize(entries)
        hosts != [] and Enum.all?(hosts, &(&1 in entries))

      :unreadable ->
        false
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
