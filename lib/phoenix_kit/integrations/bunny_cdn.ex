defmodule PhoenixKit.Integrations.BunnyCDN do
  @moduledoc """
  A named Bunny CDN connection identifies one existing pull zone. Resolve its
  HTTPS hostname once per batch. Callers decide which public objects to expose.
  Token-protected zones require a separate signing policy.
  """
  @behaviour PhoenixKit.Integrations.Validator
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Integrations

  @impl true
  def validate_connection(data) do
    case zone(data) do
      {:ok, zone} -> {:ok, %{fact: zone["Name"]}}
      error -> error
    end
  end

  @doc "Returns the public HTTPS base URL of the selected owner's active pull zone."
  @spec public_base_url(String.t(), Integrations.owner()) :: {:ok, String.t()} | {:error, term()}
  def public_base_url(uuid, owner) do
    with {:ok, data} <- credentials(uuid, owner),
         {:ok, zone} <- zone(data) do
      public_base(zone)
    end
  end

  @doc "Purges one object on the connection's default delivery hostname."
  @spec purge(String.t(), Integrations.owner(), String.t()) :: :ok | {:error, term()}
  def purge(uuid, owner, key) do
    with {:ok, path} <- object_path(key),
         {:ok, data} <- credentials(uuid, owner),
         {:ok, zone} <- zone(data),
         {:ok, base} <- system_hostname(zone),
         {:ok, _} <- request(:post, "/purge", data["api_key"], url: base <> path, async: false) do
      :ok
    end
  end

  defp credentials(uuid, owner)
       when owner == :system or
              (is_tuple(owner) and tuple_size(owner) == 2 and elem(owner, 0) == :user and
                 is_binary(elem(owner, 1))) do
    case Integrations.get_credentials(uuid, owner: owner) do
      {:ok, %{"provider" => "bunny_cdn"} = data} -> {:ok, data}
      _ -> {:error, :not_configured}
    end
  end

  defp credentials(_, _), do: {:error, :not_configured}

  defp zone(%{"api_key" => key, "pull_zone_id" => id})
       when is_binary(id) and is_binary(key) and key != "" do
    with true <- Regex.match?(~r/\A[1-9][0-9]{0,18}\z/, id),
         {:ok, %{"Id" => zone_id, "Name" => name} = zone} when is_binary(name) <-
           request(:get, "/pullzone/" <> id, key, []),
         true <- zone_id == String.to_integer(id) do
      {:ok, zone}
    else
      {:error, _} = error -> error
      _ -> {:error, gettext("Invalid pull zone")}
    end
  end

  defp zone(_), do: {:error, gettext("Incomplete credentials")}

  defp public_base(
         %{
           "Enabled" => true,
           "Suspended" => false,
           "ZoneSecurityEnabled" => false
         } = zone
       ),
       do: system_hostname(zone)

  defp public_base(_), do: {:error, :no_public_hostname}

  defp system_hostname(%{"Hostnames" => hosts}) when is_list(hosts) do
    Enum.find_value(hosts, {:error, :no_public_hostname}, fn
      %{"Value" => host, "IsSystemHostname" => true, "HasCertificate" => true}
      when is_binary(host) ->
        if Regex.match?(~r/\A[a-z0-9.-]+\z/i, host), do: {:ok, "https://" <> host}

      _ ->
        nil
    end)
  end

  defp system_hostname(_), do: {:error, :no_public_hostname}

  defp object_path(key) when is_binary(key) and byte_size(key) > 0 do
    segments = String.split(key, "/")

    if Enum.any?(segments, &(&1 in ["", ".", ".."] or String.contains?(&1, ["*", "%", "\\"]))),
      do: {:error, :invalid_object_key},
      else:
        {:ok,
         "/" <> Enum.map_join(segments, "/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))}
  end

  defp object_path(_), do: {:error, :invalid_object_key}

  defp request(method, path, key, params) do
    test_opts =
      Application.get_env(:phoenix_kit, :integrations_check_req_options, [])
      |> Keyword.take([:plug])

    case Req.request(
           [
             method: method,
             url: "https://api.bunny.net" <> path,
             headers: [{"accesskey", key}],
             params: params,
             redirect: false,
             retry: false,
             receive_timeout: 10_000
           ] ++ test_opts
         ) do
      {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
      {:ok, %{status: s}} -> {:error, gettext("Bunny CDN returned HTTP %{status}", status: s)}
      {:error, _} -> {:error, gettext("Could not reach Bunny CDN")}
    end
  end
end
