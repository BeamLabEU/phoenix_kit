defmodule PhoenixKit.Users.Setup do
  @moduledoc """
  Who may become the first Owner of an install, and the operator's ways of
  making one.

  A fresh install has no Owner. Before this module, whoever registered first
  became the Owner — on a public URL that is anyone who finds the sign-up page
  before the operator does. Now the first Owner is made one of three ways:

    1. **From the console** — `mix phoenix_kit.create_owner EMAIL`, or in a
       release `create_owner/2` through `bin/my_app rpc` (see below).
    2. **Through the setup link** — while no active Owner exists, every boot
       logs a one-time link (`/users/register?setup=TOKEN`, under the
       configured `url_prefix`). The account registered through it becomes
       the Owner; the link then stops working. Only a hash of the token is
       stored (setting `#{"first_owner_setup_token_hash"}`); a new one replaces
       it at every boot while there is still no Owner, so after a restart, or
       on a cluster, use the link the most recent boot printed.
    3. **On a laptop** — with the default policy, a registration on a dev
       server (`Mix.env() == :dev`) reached at `localhost`/`127.0.0.1`/`::1`
       still makes the first registrant the Owner, so `mix phx.server` and
       *Register* works as it always did.

  ## The policy

      config :phoenix_kit, first_owner: :auto   # the default
      config :phoenix_kit, first_owner: :token  # setup link or console only, even in dev
      config :phoenix_kit, first_owner: :open   # the old behaviour: first registrant is Owner

  `:open` brings back the unconditional grant. Use it only where nobody but
  you can reach the sign-up page before you register.

  ## What a public sign-up sees while there is no Owner

  The kit's own doors — the registration form, the magic-link registration,
  and OAuth sign-up — **refuse** the registration (no account is created)
  unless the request carries the setup token or is the local dev case above.
  The message tells the operator where to look. Refusing, rather than
  creating a plain account, keeps addresses and usernames from being claimed
  on an install nobody administers yet, and makes the missing setup visible to
  the operator who tries to sign up first.

  A host's own public form is a door too when it calls
  `PhoenixKit.Users.Auth.register_user/3` with `site_wide: true` (which its
  docs already ask of an anonymous request): without the token it is refused
  the same way. Pass `first_owner: Setup.claim_from_socket(socket, token)` (or
  `claim_from_conn/2`) to let it accept the setup link.

  Code-level callers — seeds, imports, `PhoenixKit.Test.Fixtures` — still make
  the first user the Owner: whoever runs code on the server is the operator.
  `Auth.admin_create_user/2` does not (an admin is not an Owner); it creates a
  plain user.

  ## Creating the Owner from a console

      $ mix phoenix_kit.create_owner you@example.com

  In a running release (`rpc` runs inside the node, so the repo is up):

      $ bin/my_app rpc 'PhoenixKit.Users.Setup.create_owner("you@example.com") |> IO.inspect()'

  `create_owner/2` generates a password when none is given and returns it once
  in the result — sign in with it and change it. Passing `password:` on a
  command line leaves it in the shell history; prefer the generated one.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes

  @token_key "first_owner_setup_token_hash"
  @policies [:auto, :token, :open]

  @typedoc """
  What a request offers as proof for the first-Owner grant: the setup token it
  carried (or nil) and whether it is the local dev case. Built by
  `claim_from_socket/2`, `claim_from_conn/2` or `claim/3`.
  """
  @type claim :: %{setup_token: String.t() | nil, local: boolean()}

  @typedoc """
  The `:first_owner` option of `Auth.register_user/3`: `:allow` (trusted code:
  the first user becomes Owner), `:deny` (never), or a request's `t:claim/0`.
  """
  @type first_owner :: :allow | :deny | claim()

  ## Policy

  @doc """
  The configured policy (`config :phoenix_kit, first_owner: …`): `:auto`
  (default), `:token` or `:open`. An unknown value is read as `:token`, the
  strictest, with a warning.
  """
  @spec policy() :: :auto | :token | :open
  def policy do
    case Application.get_env(:phoenix_kit, :first_owner, :auto) do
      policy when policy in @policies ->
        policy

      other ->
        Logger.warning(
          "[PhoenixKit] config :phoenix_kit, first_owner: #{inspect(other)} is not one of " <>
            "#{inspect(@policies)}; treating it as :token"
        )

        :token
    end
  end

  ## Claims

  @doc """
  The claim of a request no one vouches for: no token, not local. What a
  public door is held to when its caller passed nothing.
  """
  @spec public_claim() :: claim()
  def public_claim, do: %{setup_token: nil, local: false}

  @doc """
  The claim of a LiveView request. Call it in `mount/3` — the peer address is
  only readable there — with the `setup` query parameter.
  """
  @spec claim_from_socket(Phoenix.LiveView.Socket.t(), term()) :: claim()
  def claim_from_socket(socket, setup_token) do
    host =
      case socket.host_uri do
        %URI{host: host} -> host
        _ -> nil
      end

    claim(setup_token, host, IpAddress.client_address_from_socket(socket))
  end

  @doc "The claim of a plain HTTP request (an OAuth callback, a host controller)."
  @spec claim_from_conn(Plug.Conn.t(), term()) :: claim()
  def claim_from_conn(%Plug.Conn{} = conn, setup_token \\ nil) do
    claim(setup_token, conn.host, IpAddress.client_address(conn))
  end

  @doc """
  Builds a claim from its parts.

  `local` is true only under the `:auto` policy, on a dev server, for a request
  addressed to a loopback name (`localhost`, `*.localhost`, `127.0.0.0/8`,
  `::1`) whose client address is known to be loopback. The host name alone is
  not trusted: it is the client's to write. The dev check is what keeps a
  production node whose proxy rewrites `Host` to `127.0.0.1` out of it.
  `opts[:dev]` overrides the dev check (tests).
  """
  @spec claim(term(), String.t() | nil, String.t() | nil, keyword()) :: claim()
  def claim(setup_token, host, peer, opts \\ []) do
    dev? = Keyword.get_lazy(opts, :dev, &dev_runtime?/0)

    %{
      setup_token: normalize_token(setup_token),
      local: policy() == :auto and dev? and loopback_host?(host) and loopback_ip?(peer)
    }
  end

  defp normalize_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      token -> token
    end
  end

  defp normalize_token(_), do: nil

  @doc false
  @spec loopback_host?(term()) :: boolean()
  def loopback_host?(host) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    cond do
      host == "localhost" -> true
      String.ends_with?(host, ".localhost") -> true
      true -> host |> String.trim_leading("[") |> String.trim_trailing("]") |> loopback_ip?()
    end
  end

  def loopback_host?(_), do: false

  defp loopback_ip?(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 65_535, a, _}} -> div(a, 256) == 127
      _ -> false
    end
  end

  defp loopback_ip?(_), do: false

  # Runtime, not compile time: Mix compiles dependencies in :prod whatever the
  # host runs, and `Mix` is absent from a release.
  defp dev_runtime? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  ## Decisions

  @doc false
  # The `:first_owner` option `Auth.register_user/3` applies: an explicit one
  # wins; otherwise a public request (`site_wide: true`) is held to the
  # public claim and trusted code is allowed.
  @spec resolve(keyword()) :: first_owner()
  def resolve(opts) do
    case Keyword.fetch(opts, :first_owner) do
      {:ok, value} -> normalize_first_owner(value)
      :error -> if Keyword.get(opts, :site_wide, false), do: public_claim(), else: :allow
    end
  end

  defp normalize_first_owner(value) when value in [:allow, :deny], do: value

  defp normalize_first_owner(%{} = claim) do
    %{
      setup_token: normalize_token(Map.get(claim, :setup_token)),
      local: Map.get(claim, :local) == true
    }
  end

  defp normalize_first_owner(nil), do: public_claim()

  @doc """
  Whether a registration carrying `first_owner` may go ahead. Checked before
  the account is inserted, so a refused sign-up leaves nothing behind.

  Only a request claim can be refused, and only while no active Owner exists
  and the claim proves nothing (no valid token, not local, policy not `:open`).
  `:allow` and `:deny` are never refused here.
  """
  @spec check_registration(first_owner()) :: :ok | {:error, :setup_required}
  def check_registration(%{} = claim) do
    cond do
      policy() == :open -> :ok
      claim.local -> :ok
      Roles.count_active_owners() > 0 -> :ok
      setup_token_valid?(claim.setup_token) -> :ok
      true -> {:error, :setup_required}
    end
  end

  def check_registration(_), do: :ok

  @doc false
  # Called by `Roles.ensure_first_user_is_owner/2` inside its transaction,
  # after it found no active Owner under the Owner-role lock. Consumes the
  # setup token when that is the proof; a rollback of the caller's
  # transaction puts it back.
  @spec grant_first_owner?(first_owner(), module()) :: boolean()
  def grant_first_owner?(first_owner, repo) do
    cond do
      first_owner == :allow -> true
      first_owner == :deny -> false
      policy() == :open -> true
      first_owner.local -> true
      true -> consume_setup_token(first_owner.setup_token, repo)
    end
  end

  ## The setup token

  @doc """
  Makes a new setup token, stores its hash (replacing any earlier one) and
  returns it. The token is never stored or logged anywhere by this function.
  """
  @spec generate_setup_token() :: {:ok, String.t()} | {:error, term()}
  def generate_setup_token do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = UtilsDate.utc_now()

    setting = %Setting{
      key: @token_key,
      value: hash_token(token),
      module: "users",
      date_added: now,
      date_updated: now
    }

    case RepoHelper.repo().insert(setting,
           on_conflict: [set: [value: setting.value, date_updated: now]],
           conflict_target: :key
         ) do
      {:ok, _} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether `token` is the current setup token. Does not consume it."
  @spec setup_token_valid?(term()) :: boolean()
  def setup_token_valid?(token) when is_binary(token) and token != "" do
    case stored_hash(RepoHelper.repo()) do
      stored when is_binary(stored) -> Plug.Crypto.secure_compare(stored, hash_token(token))
      _ -> false
    end
  end

  def setup_token_valid?(_), do: false

  @doc "Removes the setup token, if any. Done whenever an Owner is made."
  @spec clear_setup_token(module()) :: :ok
  def clear_setup_token(repo \\ RepoHelper.repo()) do
    repo.delete_all(from(s in Setting, where: s.key == ^@token_key))
    :ok
  end

  defp consume_setup_token(token, repo) when is_binary(token) do
    hash = hash_token(token)

    case repo.delete_all(from(s in Setting, where: s.key == ^@token_key and s.value == ^hash)) do
      {1, _} -> true
      _ -> false
    end
  end

  defp consume_setup_token(_token, _repo), do: false

  defp stored_hash(repo) do
    repo.one(from(s in Setting, where: s.key == ^@token_key, select: s.value))
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  The setup link for `token`: the registration page under the configured
  `url_prefix`, on the site URL (`site_url` setting, else the endpoint's).
  """
  @spec setup_url(String.t()) :: String.t()
  def setup_url(token) when is_binary(token) do
    Routes.url("/users/register", locale: :none) <> "?setup=" <> token
  end

  @doc false
  # Run once per boot by `PhoenixKit.Supervisor`: while there is no active
  # Owner, replace the setup token and log the link. Silent under `:open`,
  # in tests, and when the database cannot be read.
  @spec announce_at_boot(keyword()) :: :ok
  def announce_at_boot(opts \\ []) do
    Process.sleep(Keyword.get(opts, :delay, :timer.seconds(3)))

    if policy() != :open and not test_runtime?() and Roles.count_active_owners() == 0 do
      case refresh_setup_token() do
        {:ok, token} ->
          Logger.warning(boot_message(token))

        {:error, :owner_exists} ->
          :ok

        {:error, reason} ->
          Logger.error("[PhoenixKit] Could not make a setup token: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.debug("[PhoenixKit] First-owner check skipped at boot: #{Exception.message(error)}")
      :ok
  catch
    :exit, _reason -> :ok
  end

  @doc false
  # The boot path's token write: the active-Owner count and the write share
  # the Owner-role lock `Roles.ensure_first_user_is_owner/2` and
  # `create_owner/2` take, so a token is never minted (and logged) after
  # another node committed the first Owner. A token left behind that way
  # outlived the Owner's grant and could make a second Owner once the first
  # went inactive.
  @spec refresh_setup_token() :: {:ok, String.t()} | {:error, :owner_exists | term()}
  def refresh_setup_token do
    repo = RepoHelper.repo()

    repo.transaction(fn ->
      if Roles.count_active_owners_locked() > 0, do: repo.rollback(:owner_exists)

      case generate_setup_token() do
        {:ok, token} -> token
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  @doc false
  @spec boot_message(String.t()) :: String.t()
  def boot_message(token) do
    """
    [PhoenixKit] This site has no Owner yet. Public sign-up cannot create one.
      Register the Owner through this one-time link:
        #{setup_url(token)}
      or create it from a console:
        mix phoenix_kit.create_owner you@example.com
        bin/<app> rpc 'PhoenixKit.Users.Setup.create_owner("you@example.com") |> IO.inspect()'
      The link works once and is replaced at the next boot while there is still no Owner.\
    """
  end

  defp test_runtime? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  ## Creating an Owner from a console

  @doc """
  Makes `email` an Owner: confirmed, active, holding the Owner role.

  Refuses with `{:error, :owner_exists}` when an active Owner already exists,
  unless `force: true`. When an account with this address exists it is
  promoted (its password is left alone unless `password:` is given);
  otherwise one is created.

  ## Options

    * `:password` — the new account's password. When omitted, a random one is
      generated and returned in the result, once.
    * `:force` — also when an active Owner already exists.

  ## Returns

    * `{:ok, %{user: user, created: boolean, password: String.t() | nil}}` —
      `password` is the generated or given password of a created account, or
      the new password of a promoted one when `password:` was given; nil when
      an existing account's password was left as it was.
    * `{:error, :owner_exists}`, `{:error, %Ecto.Changeset{}}` (a bad address
      or a password the registration rules refuse), or `{:error, reason}`.
  """
  @spec create_owner(String.t(), keyword()) ::
          {:ok, %{user: User.t(), created: boolean(), password: String.t() | nil}}
          | {:error, :owner_exists | Ecto.Changeset.t() | term()}
  def create_owner(email, opts \\ []) when is_binary(email) do
    repo = RepoHelper.repo()
    email = String.trim(email)
    force? = Keyword.get(opts, :force, false)
    given_password = Keyword.get(opts, :password)

    result =
      repo.transaction(fn ->
        if Roles.count_active_owners_locked() > 0 and not force?,
          do: repo.rollback(:owner_exists)

        {user, created?, password} = owner_account!(repo, email, given_password)

        case Roles.grant_owner(user) do
          {:ok, owner} ->
            clear_setup_token(repo)
            {owner, created?, password}

          {:error, reason} ->
            repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {user, created?, password}} ->
        # The Owner is committed: nothing after this may lose the generated
        # password, which exists nowhere else (a retry answers :owner_exists).
        if created?,
          do:
            after_owner_created(
              fn -> Events.broadcast_user_created(user) end,
              "broadcast the new account"
            )

        Logger.info(
          "[PhoenixKit] #{user.uuid} (#{user.email}) made Owner from the console" <>
            if(created?, do: " (new account)", else: "")
        )

        {:ok, %{user: user, created: created?, password: password}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_owner_created(fun, what) do
    fun.()
  rescue
    error ->
      Logger.error(
        "[PhoenixKit] Owner created, but could not #{what}: #{Exception.message(error)}"
      )
  catch
    :exit, reason ->
      Logger.error("[PhoenixKit] Owner created, but could not #{what}: #{inspect(reason)}")
  end

  defp owner_account!(repo, email, given_password) do
    case repo.one(
           from(u in User, where: fragment("lower(?)", u.email) == ^String.downcase(email))
         ) do
      nil ->
        password = given_password || generate_password()

        case %User{}
             |> User.registration_changeset(%{"email" => email, "password" => password})
             |> repo.insert() do
          {:ok, user} -> {user, true, password}
          {:error, changeset} -> repo.rollback(changeset)
        end

      %User{} = user when is_binary(given_password) ->
        case user |> User.password_changeset(%{"password" => given_password}) |> repo.update() do
          {:ok, user} -> {user, false, given_password}
          {:error, changeset} -> repo.rollback(changeset)
        end

      %User{} = user ->
        {user, false, nil}
    end
  end

  # Satisfies the registration rules (length, and the classes the strength
  # setting may ask for) whatever they are set to.
  defp generate_password do
    body = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    "Pk-" <> body <> "9a"
  end
end
