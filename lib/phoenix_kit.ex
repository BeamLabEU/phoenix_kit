defmodule PhoenixKit do
  @moduledoc """
  PhoenixKit
  """

  alias PhoenixKit.Config
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions

  @doc """
  Returns the current version of PhoenixKit.

  Read from the loaded application spec, so it always reports the version the
  host actually has rather than anything written down here — the example this
  replaced still claimed `"1.3.3"` several majors later.

      PhoenixKit.version()
      #=> "2.5.0"

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:phoenix_kit, :vsn) |> to_string()
  end

  @doc """
  Validates if PhoenixKit is properly configured.

  Checks for required configuration keys and returns a status.

  ## Examples

      iex> PhoenixKit.configured?()
      false

  """
  @spec configured?() :: boolean()
  def configured? do
    case Config.get(:repo, nil) do
      nil -> false
      _repo -> true
    end
  end

  @doc """
  Returns PhoenixKit configuration.

  ## Examples

      iex> PhoenixKit.config()
      %{ecto_repos: []}

  """
  @spec config() :: map()
  def config do
    :phoenix_kit
    |> Application.get_all_env()
    |> Enum.into(%{})
  end

  @doc """
  Final boot step — call from `Application.start/2` right after
  `Supervisor.start_link/2`.

  Picks up `:phoenix_kit_<x>` modules whose beams loaded after
  `PhoenixKit.ModuleRegistry` initialised (a `:phoenix_kit_*` dep starts
  *after* `:phoenix_kit` itself, so the registry's first scan can miss
  it), then runs every registered module's `migrate_legacy/0` callback.

  With `update_mode` on (`mix phoenix_kit.update` and `mix phoenix_kit.doctor`
  start the host that way) the `migrate_legacy/0` callbacks are skipped. They
  are one-shot data transitions whose "already done" checks usually read
  `PhoenixKit.Settings`, which answers nil in that mode while writes still go
  through — so they redid their work (re-granting permissions an Owner had
  revoked, re-stamping markers) on every update or doctor run. The update
  task also starts the host before it migrates, so they would run against
  the old schema. The host's next ordinary start runs them.

  Returns the supervisor result unchanged so it composes:

      def start(_type, _args) do
        children = [...]
        opts = [strategy: :one_for_one, name: MyApp.Supervisor]
        Supervisor.start_link(children, opts) |> PhoenixKit.boot()
      end

  If `Supervisor.start_link/2` returned `{:error, _}`, this is a no-op —
  the error passes through unchanged.

  `mix phoenix_kit.install` and `mix phoenix_kit.update` wire this in
  automatically; existing apps can add the call manually.
  """
  @spec boot({:ok, pid()} | {:error, term()}) :: {:ok, pid()} | {:error, term()}
  def boot({:ok, _pid} = result) do
    harden_filter_parameters()
    PhoenixKit.ModuleRegistry.rescan()

    unless Application.get_env(:phoenix_kit, :update_mode, false),
      do: PhoenixKit.ModuleRegistry.run_all_legacy_migrations()

    register_custom_permission_keys()
    warn_if_integrations_encryption_insecure()
    result
  end

  def boot({:error, _reason} = result), do: result

  # Custom permission keys declared in config:
  #
  #     config :phoenix_kit,
  #       custom_permission_keys: [
  #         {"analytics", label: "Analytics"},
  #         "exports"
  #       ]
  #
  # `Permissions.register_custom_key/2` has to run AFTER boot, because the Admin
  # auto-grant touches the database — which is why it could not simply be read
  # from config at compile time, and why every host was writing an imperative
  # call at the end of its own `Application.start/2`. Admin *tabs* have been
  # declarative all along; permission keys were the odd one out.
  #
  # ⚠️ Two things a host needs to know:
  #
  #   * This is only read from `boot/1`, which is opt-in. A host that never calls
  #     it registers nothing, silently. `install`/`update` wire the call in.
  #   * It is read once, at boot. Changing the config needs a restart.
  #
  # A key that already has an admin tab carrying `permission:` is registered by
  # that tab and must NOT be listed here — double-registration hits the override
  # path. This is for matrix-only keys with no tab of their own.
  #
  # Bad entries RAISE, failing app start. Config is a deploy-time contract, and
  # logging-and-skipping would hide the mistake until a colleague hit a 403 —
  # exactly the failure declaring keys is meant to prevent. (`Dashboard.Registry`
  # rescues instead, correctly: one bad tab should not take the dashboard down.)
  defp register_custom_permission_keys do
    :phoenix_kit
    |> Application.get_env(:custom_permission_keys, [])
    |> Enum.each(fn
      {key, opts} when is_binary(key) and is_list(opts) ->
        Permissions.register_custom_key(key, opts)

      key when is_binary(key) ->
        Permissions.register_custom_key(key)

      other ->
        raise ArgumentError, """
        Invalid entry in config :phoenix_kit, :custom_permission_keys — #{inspect(other)}

        Each entry must be a key string, or a {key, opts} tuple:

            custom_permission_keys: [
              "exports",
              {"analytics", label: "Analytics"}
            ]
        """
    end)
  end

  # One-time boot check: warns (never raises) when integration credentials
  # are not protected by a dedicated encryption key. Deliberately here, not
  # as a child `Task` of `PhoenixKit.Supervisor` — that supervisor commonly
  # starts BEFORE the host app's own Endpoint (a generated
  # `Application.start/2` lists `PhoenixKit.Supervisor` ahead of
  # `MyAppWeb.Endpoint`, matching Phoenix's own convention of starting the
  # Endpoint last), so `Encryption.status/0`'s Endpoint-config lookup would
  # rescue a startup `ArgumentError` (the Endpoint's config ETS table
  # doesn't exist yet) into `nil` and misreport the common,
  # correctly-configured `secret_key_base`-fallback install as
  # `:disabled_no_key` instead of `:legacy_secret_key_base`. `boot/1` runs
  # only after `Supervisor.start_link/2` returns — i.e. after every child in
  # the HOST's own tree has started, Endpoint included, regardless of where
  # it's listed.
  #
  # Off by default. The `secret_key_base`-derived fallback this warns about
  # is the tier every install used before a dedicated key existed (see
  # `Encryption`'s moduledoc) — for a host that hasn't opted into a
  # dedicated key, this log line fired on every single boot/restart with no
  # way to quiet it short of configuring one. `Encryption.warn_if_insecure/0`
  # itself still runs unconditionally from `mix phoenix_kit.doctor` and the
  # admin-only system page, so the diagnosis stays available on demand — this
  # only silences the boot-time push. Opt in with
  # `config :phoenix_kit, integration_encryption_warn_on_boot: true`.
  defp warn_if_integrations_encryption_insecure do
    if Application.get_env(:phoenix_kit, :integration_encryption_warn_on_boot, false) do
      Encryption.warn_if_insecure()
    end
  rescue
    error ->
      require Logger

      Logger.error(
        "[PhoenixKit] Failed to check integrations encryption status at startup: #{inspect(error)}"
      )
  end

  # `config :phoenix, :filter_parameters` is what both the endpoint's own
  # request logging AND `Phoenix.LiveView.Logger` consult (via
  # `Phoenix.Logger.filter_values/1`) before writing a "Parameters: ..."
  # log line for every LiveView `handle_event` — including the
  # Settings/Authorization form's `validate_settings`/`save_settings`,
  # which carry OAuth/AWS credentials stored generically in
  # `phoenix_kit_settings` (key names like `oauth_google_client_secret`).
  # Found leaking those values in cleartext into a live install's log file.
  #
  # `filter_parameters` is a HOST-app `Application` env key: a dependency's
  # own `config/config.exs` is never merged into it, so PhoenixKit cannot
  # ship this as config the usual way — and asking every host to remember
  # to add the line is the same silent-blacklist failure mode `settings.ex`
  # already moved away from for the settings *display* side (see
  # `@public_setting_keys`). Setting it once here, at boot, protects every
  # host without any action on its part.
  #
  # `{:keep, [...]}` mode is left alone: in keep-mode anything NOT
  # explicitly kept is already filtered by default, so a key we don't know
  # about here is already safe.
  #
  # Every OTHER shape gets REPLACED, not merged into — deliberately, found
  # by a destructive test (a real LiveView save, run through the real
  # code path) after an earlier "merge with whatever's there" version
  # silently protected nobody:
  #
  # `Phoenix.start/2` (`:phoenix`'s own OTP app boot — always finishes
  # before the HOST's supervisor tree, and therefore before `boot/1` runs)
  # unconditionally pre-compiles `:phoenix, :filter_parameters` into an
  # opaque `{:compiled, key_match, value_match}` `:binary.compile_pattern/1`
  # term, on EVERY boot — not only when a host configured something: Phoenix
  # itself ships a package-level default env of `["password", "token"]`
  # (`deps/phoenix/mix.exs`, `application/0`), so `Application.get_env/2`
  # already returns non-nil before any host config is even read. That means
  # by the time `boot/1` runs, this is ALWAYS already `{:compiled, ...}` —
  # not a rare shape a sophisticated host opts into. There is no API to
  # recover a word list from it, so "leave a compiled filter alone" is, in
  # practice, "leave every host alone" — the opposite of this function's
  # purpose. A plain (uncompiled) list works exactly the same at the
  # `filter_values/1` call site (it just re-compiles the pattern on that
  # one call instead of reusing a cached one — negligible on a settings
  # save) — so overwrite with Phoenix's own documented default plus ours.
  # The one real cost: a host that customized this beyond Phoenix's default
  # loses that customization here.
  #
  # The word list is two tiers on purpose, not just the generic one:
  # `password`/`token`/`secret`/`api_key` catch anything shaped like a
  # credential by NAMING CONVENTION (covers a setting key nobody has
  # written down as sensitive yet), while
  # `PhoenixKit.Settings.restricted_setting_keys/0` — the same list
  # `list_public_settings/0` uses to keep these OUT of the settings-display
  # allow list — closes the gap the generic words miss:
  # `aws_access_key_id` is genuinely a credential half of an AWS keypair,
  # but its name contains none of `secret`/`token`/`api_key`. Duplicating
  # that list by hand here instead would drift from it exactly the way the
  # settings-display side used to drift from `module == "integrations"`.
  defp harden_filter_parameters do
    case Application.get_env(:phoenix, :filter_parameters, ["password"]) do
      {:keep, _} = keep_mode ->
        keep_mode

      _other ->
        filter =
          Enum.uniq(~w(password token secret api_key) ++ Settings.restricted_setting_keys())

        Application.put_env(:phoenix, :filter_parameters, filter)
    end
  rescue
    error ->
      require Logger

      Logger.error(
        "[PhoenixKit] Failed to harden :phoenix, :filter_parameters at startup: #{inspect(error)}"
      )
  end
end
