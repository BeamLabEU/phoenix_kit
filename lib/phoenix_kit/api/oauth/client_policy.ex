defmodule PhoenixKit.API.OAuth.ClientPolicy do
  @moduledoc """
  Which clients may ask for access (Settings -> API).

    * Policy `any` (`api_oauth_client_policy`, the default): any https client; the person sees
      the host the browser goes back to on the consent screen and decides.
    * Policy `allow_list`: only a client whose every host is in `api_oauth_client_allow_hosts`.
      The hosts of a client are the host of its `client_id` (when that is a URL, a metadata
      document) and the host of each of its redirect URIs.
    * `api_oauth_client_deny_hosts` applies under either policy: one host of the client in it
      refuses the client.

  Hosts are compared in lower case and without a final dot, whole (no wildcards); an entry
  written as a URL, or with a port, counts as its host. A pre-registered client (the
  administrator typed it in) is exempt from both lists.
  A list that cannot be read refuses (fail closed), and so does a policy value nobody knows.
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
    hosts = hosts(kind, client_id, redirect_uris)

    with {:ok, denied} <- Config.fetch_oauth_hosts(:deny),
         true <- disjoint?(hosts, normalize(denied)) do
      allowed_by_policy?(hosts)
    else
      _ -> false
    end
  end

  defp allowed_by_policy?(hosts) do
    case Config.oauth_client_policy() do
      :any ->
        true

      :allow_list ->
        case Config.fetch_oauth_hosts(:allow) do
          {:ok, listed} ->
            listed = normalize(listed)
            hosts != [] and Enum.all?(hosts, &(&1 in listed))

          :unreadable ->
            false
        end
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

  defp disjoint?(hosts, listed), do: not Enum.any?(hosts, &(&1 in listed))

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
      entry |> String.replace(~r/^([^:\[\]]+):\d+$/, "\\1") |> host_name()
    end
  end

  # A host in lower case and without the final dot: `evil.example.` is the same name to the
  # resolver as `evil.example`.
  defp host_name(host), do: host |> String.downcase() |> String.trim_trailing(".")
end
