defmodule Mix.Tasks.PhoenixKit.Cdn.CheckOrigin do
  @shortdoc "Check the configured Bunny pull zone against the intended public CDN origin"
  @moduledoc """
  mix phoenix_kit.cdn.check_origin CONNECTION_UUID EXPECTED_HTTPS_ORIGIN [--user OWNER_UUID]

  Reads a system connection by default. Pass the library owner's UUID for a
  personal connection. The check reads Bunny's management API and prints the
  verified delivery hostname. It never changes the zone or delivery settings.
  """
  use Mix.Task
  alias PhoenixKit.Integrations.BunnyCDN

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [user: :string]) do
      {opts, [uuid, origin], []} ->
        with {:ok, uuid} <- Ecto.UUID.cast(uuid),
             {:ok, owner} <- owner(opts[:user]) do
          Mix.Task.run("app.start")

          case BunnyCDN.check_origin(uuid, owner, origin) do
            {:ok, base} -> Mix.shell().info("Pull zone matches the expected origin: #{base}")
            {:error, reason} -> Mix.raise("Pull zone check failed: #{inspect(reason)}")
          end
        else
          :error -> Mix.raise("Expected a valid connection and owner UUID")
        end

      _ ->
        Mix.raise(
          "Usage: mix phoenix_kit.cdn.check_origin CONNECTION_UUID EXPECTED_HTTPS_ORIGIN [--user OWNER_UUID]"
        )
    end
  end

  defp owner(nil), do: {:ok, :system}

  defp owner(value) do
    with {:ok, id} <- Ecto.UUID.cast(value), do: {:ok, {:user, id}}
  end
end
