# Igniter-only helper: every caller is a `mix phoenix_kit.*` igniter task,
# which is itself guarded the same way (Igniter is an optional dependency).
if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixKit.Install.InstallDefaults do
    @moduledoc """
    Configuration `mix phoenix_kit.install` writes for a NEW installation only.

    `mix phoenix_kit.update` never calls this module: an upgraded host keeps
    whatever it had (or the runtime default for a key it never set), so
    nothing here changes behaviour on an existing site.

    ## Trusted proxies

    `config :phoenix_kit, trusted_proxies:` says which peers may tell the kit
    the client's address through `X-Forwarded-For` / `X-Real-IP`
    (`PhoenixKit.Utils.IpAddress`). Left unset, any loopback or private peer
    is believed and the first such request logs a warning. The installer
    settles it at install time:

      * `--trusted-proxy CIDR` (repeatable) writes exactly those blocks;
      * otherwise, in an interactive terminal, it asks whether the app runs
        behind a reverse proxy. The default answer is **no**, which writes
        `trusted_proxies: []` (the client is always the connection's peer, and
        the warning is silenced). "Yes" writes the loopback blocks
        (`127.0.0.1/8`, `::1/128`) and offers the private ranges as a
        separate, explicit choice;
      * with no flag and no terminal (CI, `--yes`), nothing is written: the
        long-standing default and its warning stay, and a notice says how to
        set the key.

    An entry the host already has is never replaced.
    """

    alias Igniter.Project.Config
    alias PhoenixKit.API.Keys.CIDR
    alias PhoenixKit.Install.MigrationStrategy

    @loopback ["127.0.0.1/8", "::1/128"]
    @private ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"]

    @answer_key :phoenix_kit_install_trusted_proxies

    @doc "The loopback blocks a \"yes, behind a proxy\" answer trusts."
    @spec loopback_blocks() :: [String.t()]
    def loopback_blocks, do: @loopback

    @doc "The private ranges offered as an extra, explicit choice."
    @spec private_blocks() :: [String.t()]
    def private_blocks, do: @private

    @doc """
    What to write for `trusted_proxies`: `{:write, blocks}` or `:skip`.

    `flags` are the `--trusted-proxy` values (validated, raises on a bad
    one). `interactive?` says whether a person can answer; `ask` is called
    with a question and returns true/false (injectable for tests).
    """
    @spec trusted_proxies_choice([String.t()], boolean(), (String.t() -> boolean())) ::
            {:write, [String.t()]} | :skip
    def trusted_proxies_choice(flags, interactive?, ask \\ &ask_no_default/1)

    def trusted_proxies_choice([_ | _] = flags, _interactive?, _ask) do
      case CIDR.normalize_all(flags) do
        {:ok, blocks} ->
          {:write, blocks}

        {:error, invalid} ->
          Mix.raise(
            "--trusted-proxy takes a CIDR block or an address (e.g. 10.0.0.0/8); " <>
              "could not read: #{Enum.map_join(invalid, ", ", &inspect/1)}"
          )
      end
    end

    def trusted_proxies_choice([], false, _ask), do: :skip

    def trusted_proxies_choice([], true, ask) do
      if ask.(
           "Does this app run behind a reverse proxy or load balancer " <>
             "(nginx, Caddy, a cloud load balancer) that sets X-Forwarded-For?"
         ) do
        private? =
          ask.(
            "Also trust the private network ranges (#{Enum.join(@private, ", ")})? " <>
              "Only if the proxy reaches the app over a private network (Docker, a LAN)"
          )

        {:write, if(private?, do: @loopback ++ @private, else: @loopback)}
      else
        {:write, []}
      end
    end

    @doc """
    Writes `config :phoenix_kit, trusted_proxies:` for a new install (see the
    moduledoc). The answer is asked once per `mix` invocation: the direct
    `mix phoenix_kit.install` path can run `igniter/1` twice.
    """
    def add_trusted_proxies(igniter, flags, interactive? \\ nil) do
      choice =
        case Process.get(@answer_key) do
          nil ->
            interactive? =
              if is_nil(interactive?), do: interactive_terminal?(), else: interactive?

            choice = trusted_proxies_choice(List.wrap(flags), interactive?)
            Process.put(@answer_key, choice)
            choice

          choice ->
            choice
        end

      write_trusted_proxies(igniter, choice)
    end

    @doc false
    def forget_answers, do: Process.delete(@answer_key)

    @doc false
    def write_trusted_proxies(igniter, :skip) do
      Igniter.add_notice(
        igniter,
        """
        ℹ️  config :phoenix_kit, trusted_proxies: was not set (no terminal to ask).
           Set it to your reverse proxies' blocks, e.g. ["127.0.0.1/8"], or to []
           when clients connect directly; until then any loopback or private peer
           may set the client address (see PhoenixKit.Utils.IpAddress).\
        """
      )
    end

    def write_trusted_proxies(igniter, {:write, blocks}) do
      # configure_new leaves an existing entry alone.
      Config.configure_new(igniter, "config.exs", :phoenix_kit, [:trusted_proxies], blocks)
    end

    defp interactive_terminal? do
      MigrationStrategy.interactive_terminal?()
    end

    # A yes/no question whose Enter means "no".
    defp ask_no_default(question) do
      case Mix.shell().prompt(question <> " [y/N]") do
        answer when is_binary(answer) ->
          String.downcase(String.trim(answer)) in ["y", "yes"]

        _ ->
          false
      end
    end
  end
end
