# Igniter-only helper: every caller is a `mix phoenix_kit.*` igniter task,
# which is itself guarded the same way. Igniter is an OPTIONAL dependency
# (see mix.exs), so a host that scopes it to `only: [:dev, :test]` compiles
# :prod without it.
if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixKit.Install.EncryptionKeyConfig do
    @moduledoc """
    Gives a new installation a dedicated key for stored credentials.

    Without `config :phoenix_kit, :integrations_encryption_key`,
    `PhoenixKit.Integrations.Encryption` falls back to a key derived from
    `secret_key_base`, and the first credential an admin saves is met by the
    "protected only by a shared application secret" warning. This step sets
    the key up the way `mix phx.new` sets up `secret_key_base`:

      * `config/dev.exs` and `config/test.exs` get a generated secret each;
      * the `:prod` block of `config/runtime.exs` reads
        `PHOENIX_KIT_INTEGRATIONS_ENCRYPTION_KEY` and refuses to boot
        without it. A production node that started on the fallback key and was
        given the variable later could no longer read what it had stored, so a
        missing variable stops the boot instead.

    ## Only for a new installation

    Switching to another key makes every credential already stored unreadable
    (`mix phoenix_kit.integrations.rotate_key` is the way to change it). So
    the step does nothing when the project already has a PhoenixKit migration,
    or when its config already names an encryption key or a key store. For the
    same reason `mix phoenix_kit.update` does not call it.
    """
    use PhoenixKit.Install.IgniterCompat

    alias Igniter.Project.Config

    @env_var "PHOENIX_KIT_INTEGRATIONS_ENCRYPTION_KEY"
    @key :integrations_encryption_key

    @doc "The environment variable the production config reads."
    @spec env_var() :: String.t()
    def env_var, do: @env_var

    @doc """
    Adds the dedicated encryption key to a new installation's config.

    A no-op for an existing installation (see the moduledoc).
    """
    @spec add_encryption_key(Igniter.t()) :: Igniter.t()
    def add_encryption_key(igniter) do
      igniter =
        igniter
        |> Igniter.include_glob("priv/repo/migrations/*.exs")
        |> Igniter.include_glob("config/*.exs")

      if new_installation?(igniter) and not key_configured?(igniter) do
        configure(igniter)
      else
        igniter
      end
    end

    defp configure(igniter) do
      igniter
      |> Config.configure_new("dev.exs", :phoenix_kit, [@key], generate_secret())
      |> Config.configure_new("test.exs", :phoenix_kit, [@key], generate_secret())
      |> Config.configure_runtime_env(:prod, :phoenix_kit, [@key], {:code, production_value()})
      |> Igniter.add_notice(production_notice())
    rescue
      _ -> Igniter.add_notice(igniter, manual_notice())
    end

    # Same shape as `mix phx.gen.secret`: 64 characters of base64.
    defp generate_secret do
      48 |> :crypto.strong_rand_bytes() |> Base.encode64()
    end

    defp production_value do
      Sourceror.parse_string!("""
      System.get_env("#{@env_var}") ||
        raise \"\"\"
        environment variable #{@env_var} is missing.
        It encrypts the credentials PhoenixKit stores (integrations, storage buckets).
        Generate one with: mix phx.gen.secret
        Keep it: without the same value the stored credentials cannot be read.
        \"\"\"
      """)
    end

    defp new_installation?(igniter) do
      not Enum.any?(source_paths(igniter), fn path ->
        Path.dirname(path) == "priv/repo/migrations" and
          String.contains?(Path.basename(path), "phoenix_kit")
      end)
    end

    defp key_configured?(igniter) do
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.any?(fn source ->
        Path.dirname(Rewrite.Source.get(source, :path)) == "config" and
          names_key?(Rewrite.Source.get(source, :content))
      end)
    end

    defp names_key?(content) do
      String.contains?(content, "integrations_encryption_key") or
        String.contains?(content, "integrations_key_store")
    end

    defp source_paths(igniter) do
      igniter.rewrite |> Rewrite.sources() |> Enum.map(&Rewrite.Source.get(&1, :path))
    end

    defp production_notice do
      """
      🔑 Stored credentials get their own encryption key.
        • dev and test: a generated key in config/dev.exs and config/test.exs
        • production: set #{@env_var} before the first deploy
          (generate one with `mix phx.gen.secret`); config/runtime.exs
          refuses to boot without it. Keep the value: it is the only thing
          that reads the stored credentials.
      """
      |> String.trim()
    end

    defp manual_notice do
      """
      ⚠️  Could not add the credentials encryption key automatically.

      Add to config/dev.exs (a value from `mix phx.gen.secret`):

        config :phoenix_kit, integrations_encryption_key: "..."

      and to the :prod block of config/runtime.exs:

        config :phoenix_kit,
          integrations_encryption_key: System.fetch_env!("#{@env_var}")
      """
      |> String.trim()
    end
  end
end
