defmodule PhoenixKit.Integrations.Telegram.Linking do
  @moduledoc """
  Links a Telegram chat to a user account through the site bot, with a
  one-time deep link instead of guessing who wrote to the bot last.

  ## Flow

    1. `create_token/2` mints a token for a signed-in user and a site bot
       connection. `deep_link/2` turns it into
       `https://t.me/<bot>?start=<token>`.
    2. The user opens the link and presses **Start**. Telegram sends the bot
       `/start <token>`.
    3. `poll/1` reads the bot's pending updates, and every `/start <token>`
       from a private chat links THAT chat to the token's owner. The sender is
       never asked who they are — the token already says.

  The token is 48 random bytes in base64url (64 characters, the most Telegram
  allows in a start parameter). Only its SHA-256 hash is stored, in
  `phoenix_kit_users_tokens` under the `"telegram_link"` context with the
  connection uuid in `sent_to`. It lives 15 minutes and is spent by the
  delete that reads it, so two racing polls cannot both use it.

  ## Reading the updates

  There is no webhook and no always-on poller: `poll/1` runs when someone is
  waiting (the profile page polls while a link is pending, and has a "I sent
  it" button). Telegram keeps the offset, so nothing is stored here.

  The database work of a batch — spending the tokens and recording the links —
  is one short transaction under a Postgres advisory lock (so two nodes do not
  link the same batch together). Everything that talks to Telegram happens
  outside it: the read before, and after the commit the confirmation of the
  offset and the replies. If the confirmation fails the batch is read again;
  that is harmless, because a `/start` whose chat is already linked to this bot
  is passed over without a word instead of answered "expired".

  ## A resident reader

  A bot's updates can be read by one reader only. A host that reads the site
  bot's updates all the time (to answer inline buttons, say) declares it:

      config :phoenix_kit, :telegram_updates_reader, {MyApp.BotReader, :holds?, []}

  `MyApp.BotReader.holds?(connection_uuid)` answers `true` while it reads that
  bot. `poll/1` then reads nothing, and the reader hands every batch it reads
  to `handle_updates/3`, which links the chats as `poll/1` would.

  The question is asked from any node (a request on one node, the reader on
  another), so `holds?` must answer for the whole cluster, not for its own node.
  It fails closed: a reader that raises, exits (a call that times out while it is
  busy in its long poll) or answers anything but `false` is taken to hold the bot,
  and nothing is read; only a reader that is not running (an exit with `:noproc`)
  holds nothing. `handle_updates/3` confirms nothing unless it is given a
  `:confirm` function: the reader moves the offset itself.

  Updates are acted on by the host, so it has to know who wrote.
  `chat_for_update/1` and `actor_ref/2` are the one place that says "a private
  chat, written by that very person": a host builds the
  `PhoenixKit.API.Executor` reference of a chat from `actor_ref/2` only.

  The stored link is `custom_fields["notification_channel:telegram"]`
  (`"site_chat_id"`, `"site_connection_uuid"`, `"linked_at"`), next to the
  routing the notification channel already keeps there.

  ## A link is a standing credential

  A linked chat can act as the user in the Machine API (`PhoenixKit.API.Executor`),
  so the link is dropped (`drop_links/1`, the routing choices stay) when the user
  recovers the account: a password change or reset (also by an administrator), the
  confirmation of an unconfirmed account by an external proof, signing out all sessions or
  the others (when there were any), deactivation. Signing out one session leaves it.
  Link tokens not used yet go with it, because a token is not bound to the session that
  minted it. The chat is also where the user's Telegram notifications go, so they stop
  until it is connected again: the activity feed gets a `telegram.link_dropped` entry
  and the card says so (`link_dropped_at`).

  The password writes and the confirmation drop the link in the transaction that rotates the
  credential, so a failed change keeps it. Signing out sessions and deactivation drop it in a
  statement of their own right after the sessions are deleted: if that one failed, the
  sessions would be gone and the link would stay.

  A managed organization (`managed_by_members`) and a service user (`api_only`) cannot link
  a chat (`linkable?/1`) and are nobody's link (`linked_user/2`); a link one of them stored
  earlier is inert, and the card lets such an account disconnect it.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.Integrations.Telegram, as: Client
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Prefs
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken

  @context "telegram_link"
  @ttl_minutes 15
  @channel "telegram"
  @warn_every_ms 60_000
  # Anything shaped like one of our tokens gets an answer when it fails; any
  # other `/start` payload is somebody else's business.
  @token_shape ~r/\A[A-Za-z0-9_-]{32,64}\z/

  @doc "How long a link stays good, in minutes."
  @spec ttl_minutes() :: pos_integer()
  def ttl_minutes, do: @ttl_minutes

  @doc """
  Mints a link token for `user` on site bot `connection_uuid`, replacing the
  user's earlier one. The caller must refuse a borrowed session (an impersonated
  one, or one whose `impersonated` is not known): a link made from it would outlive
  the borrowing as a standing credential of the user's.
  """
  @spec create_token(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_token(user, connection_uuid) when is_binary(connection_uuid) do
    if linkable?(user), do: mint_token(user, connection_uuid), else: {:error, :not_linkable}
  end

  @doc """
  Whether `user` may link a chat: not a managed organization and not a service user, who
  have no web session of their own to link from.
  """
  @spec linkable?(map()) :: boolean()
  def linkable?(user),
    do: Map.get(user, :managed_by_members) != true and Map.get(user, :api_only) != true

  defp mint_token(%{uuid: user_uuid} = user, connection_uuid) do
    {token, row} = UserToken.build_email_token(user, @context)
    repo = RepoHelper.repo()

    result =
      repo.transaction(fn ->
        repo.delete_all(
          from t in UserToken, where: t.user_uuid == ^user_uuid and t.context == @context
        )

        case repo.insert(%{row | sent_to: connection_uuid}) do
          {:ok, inserted} -> inserted
          {:error, changeset} -> repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, _} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The `t.me` link that opens the bot with `token` as its start parameter."
  @spec deep_link(String.t(), String.t()) :: String.t()
  def deep_link(bot_username, token), do: "https://t.me/#{bot_username}?start=#{token}"

  @doc "Whether `user` has a link for the bot `connection_uuid` that has been minted and not yet used or expired."
  @spec pending?(map(), String.t()) :: boolean()
  def pending?(%{uuid: user_uuid}, connection_uuid) when is_binary(connection_uuid) do
    RepoHelper.repo().exists?(
      from t in UserToken,
        where:
          t.user_uuid == ^user_uuid and t.context == @context and t.sent_to == ^connection_uuid and
            t.inserted_at > ago(^@ttl_minutes, "minute")
    )
  end

  @doc """
  Spends a token: `{:ok, %{user_uuid:, connection_uuid:}}` the first time it
  is presented while valid for bot `connection_uuid`, `:error` otherwise —
  junk, expired, spent, of another kind, or minted for another bot (which
  leaves it unspent).
  """
  @spec consume_token(term(), String.t()) ::
          {:ok, %{user_uuid: String.t(), connection_uuid: String.t()}} | :error
  def consume_token(token, connection_uuid)
      when is_binary(token) and is_binary(connection_uuid) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} when decoded != "" ->
        hashed = :crypto.hash(:sha256, decoded)

        query =
          from t in UserToken,
            where:
              t.token == ^hashed and t.context == @context and t.sent_to == ^connection_uuid and
                t.inserted_at > ago(^@ttl_minutes, "minute"),
            select: %{user_uuid: t.user_uuid, connection_uuid: t.sent_to}

        case RepoHelper.repo().delete_all(query) do
          {1, [row]} -> {:ok, row}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def consume_token(_token, _connection_uuid), do: :error

  # --- Polling ----------------------------------------------------------------

  @doc """
  Reads the site bot's pending updates and links every chat that sent a valid
  `/start <token>`. Returns `{:ok, %{linked: n}}`, `:busy` when another node is
  linking this bot's batch right now, or `{:error, reason}` when Telegram could
  not be read (nothing is lost: the updates stay queued).

  When the host runs a resident reader of the bot's updates (see "A resident
  reader" in the moduledoc) and it says it holds this bot, `poll/1` reads
  nothing and answers `{:ok, %{linked: 0}}`: a second reader would take the
  updates away from it, and the reader links the chats itself through
  `handle_updates/3`.
  """
  @spec poll(String.t()) :: {:ok, %{linked: non_neg_integer()}} | :busy | {:error, term()}
  def poll(connection_uuid) when is_binary(connection_uuid) do
    if resident_reader?(connection_uuid) do
      {:ok, %{linked: 0}}
    else
      case Client.get_updates(connection_uuid,
             offset: nil,
             timeout: 0,
             limit: 100,
             owner: :system
           ) do
        {:ok, []} ->
          {:ok, %{linked: 0}}

        {:ok, updates} when is_list(updates) ->
          handle_updates(connection_uuid, updates, confirm: &confirm(connection_uuid, &1))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Links the chats of a batch of updates already read from the bot
  `connection_uuid`: every private `/start <token>` links its chat to the
  token's owner, and the chat is answered. Other updates are passed over.

  `opts[:confirm]` is how the batch is confirmed to Telegram once the links are
  committed: a function of the updates answering `:ok` or `:error`. There is no
  default that asks Telegram: the caller is the reader of the batch and moves the
  offset itself, and a second `getUpdates` here would be a second reader (`poll/1`
  passes its own confirming function). An "expired" answer is held back when the
  confirmation failed (the batch comes round again).

  Returns `{:ok, %{linked: n}}`, or `:busy` when another node is linking this
  bot's batch right now (nothing was done; read the batch again).
  """
  @spec handle_updates(String.t(), [map()], keyword()) ::
          {:ok, %{linked: non_neg_integer()}} | :busy
  def handle_updates(connection_uuid, updates, opts \\ [])
      when is_binary(connection_uuid) and is_list(updates) do
    confirm = Keyword.get(opts, :confirm, fn _updates -> :ok end)

    case commands(connection_uuid, updates) do
      [] ->
        confirm.(updates)
        {:ok, %{linked: 0}}

      commands ->
        case link_batch(connection_uuid, commands) do
          {:ok, outcomes} ->
            confirmed? = confirm.(updates) == :ok
            Enum.each(outcomes, &announce(connection_uuid, &1, confirmed?))
            {:ok, %{linked: Enum.count(outcomes, &match?({_, {:linked, _}}, &1))}}

          :busy ->
            :busy
        end
    end
  end

  @doc """
  Whether the host's resident reader (`config :phoenix_kit,
  :telegram_updates_reader, {mod, fun, args}`, asked with the connection uuid
  appended) holds this bot. Nothing configured holds nothing. **A reader that cannot answer
  holds the bot**: it raises, exits (a timeout), answers anything but `false`, or the setting
  is not a `{mod, fun, args}` — reading then would take its updates away. The one exception
  is an exit with `:noproc` (`{:noproc, _}` too): the reader's process is down, nobody is
  reading, so the bot is free. Each case is logged as a warning at most once a minute, with a
  message of its own.

  That rule has two costs. While a crashed reader is being restarted, a page waiting for
  Start reads the bot too, and updates queued for the reader in that window are confirmed
  away. And on a multi-node host, `fun` must not exit `:noproc` for "the reader runs on
  another node" (a `GenServer.call` to a locally registered name does): it has to answer
  `true` there, or the nodes without the reader would read the bot as well.

  `fun` is asked from any node and must answer for the cluster, not only for its own
  node. Anything else that would call `getUpdates` on a bot must ask first: a second
  reader takes the updates away from the resident one.
  """
  @spec resident_reader?(String.t()) :: boolean()
  def resident_reader?(connection_uuid) do
    case Application.get_env(:phoenix_kit, :telegram_updates_reader) do
      nil ->
        false

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        ask_reader(mod, fun, args, connection_uuid)

      _malformed ->
        unanswered()
    end
  end

  defp ask_reader(mod, fun, args, connection_uuid) do
    case apply(mod, fun, args ++ [connection_uuid]) do
      false -> false
      _holds_or_unclear -> true
    end
  rescue
    _ -> unanswered()
  catch
    # A reader that is configured but not running (its process is down) holds nothing.
    :exit, :noproc -> not_running()
    :exit, {:noproc, _} -> not_running()
    _, _ -> unanswered()
  end

  defp unanswered do
    warn_now_and_then(:unanswered, "the resident reader did not answer; the bot is held")
    true
  end

  defp not_running do
    warn_now_and_then(
      :not_running,
      "the resident reader is not running; reading the bot's updates here"
    )

    false
  end

  # `poll/1` runs every few seconds per open page: say it once in a while.
  # One key per kind: a mild warning must not hide the one that blocks linking.
  defp warn_now_and_then(kind, message) do
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, :warned_at, kind}
    last = :persistent_term.get(key, nil)

    if last == nil or now - last >= @warn_every_ms do
      :persistent_term.put(key, now)
      Logger.warning("[Telegram.Linking] " <> message)
    end

    :ok
  end

  # The database half: one transaction under the lock, no Telegram in it.
  defp link_batch(connection_uuid, commands) do
    repo = RepoHelper.repo()

    result =
      repo.transaction(fn ->
        if lock?(repo, connection_uuid),
          do: link_commands(connection_uuid, commands),
          else: repo.rollback(:busy)
      end)

    case result do
      {:ok, outcomes} -> {:ok, outcomes}
      {:error, :busy} -> :busy
    end
  end

  defp lock?(repo, connection_uuid) do
    %{rows: [[locked]]} =
      repo.query!("SELECT pg_try_advisory_xact_lock(hashtext($1))", [
        "phoenix_kit_telegram_link:" <> connection_uuid
      ])

    locked
  end

  # Telegram forgets every update below `offset`. Done after the links are
  # committed; when it fails the batch is read again, which `link_one/4` turns
  # into silence for the chats that are already linked.
  defp confirm(connection_uuid, updates) do
    last =
      updates
      |> Enum.map(& &1["update_id"])
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> nil end)

    with last when is_integer(last) <- last,
         {:ok, _} <-
           Client.get_updates(connection_uuid,
             offset: last + 1,
             limit: 1,
             timeout: 0,
             owner: :system
           ) do
      :ok
    else
      nil ->
        :ok

      {:error, reason} ->
        Logger.warning("[Telegram.Linking] could not confirm updates: #{inspect(reason)}")
        :error
    end
  end

  # The batch's `/start <token>` commands, as `{chat_id, token}`, in order. The
  # bot's own name is looked up only when some command names a bot at all.
  defp commands(connection_uuid, updates) do
    parsed = Enum.flat_map(updates, &start_command/1)
    named? = Enum.any?(parsed, fn {_chat, _token, bot} -> bot != nil end)
    username = if named?, do: SiteBot.bot_username(connection_uuid)

    for {chat_id, token, bot} <- parsed, ours?(bot, username), do: {chat_id, token}
  end

  # `{chat_id, token, bot}` for a private-chat `/start <token>` (`bot` is the
  # `@name` of `/start@name`, else `nil`); nothing else counts. A group is
  # skipped before the token is read, so a stranger's group cannot burn the
  # owner's link.
  defp start_command(%{
         "message" => %{"chat" => %{"type" => "private", "id" => id}, "text" => text}
       })
       when is_binary(text) and is_integer(id) do
    with [command, token] <- String.split(String.trim(text), ~r/\s+/, parts: 2),
         {:ok, bot} <- start_word(command),
         true <- token =~ @token_shape do
      [{id, token, bot}]
    else
      _ -> []
    end
  end

  defp start_command(_update), do: []

  # `/start`, or `/start@bot` (what Telegram sends from a chat with several bots).
  defp start_word("/start"), do: {:ok, nil}

  defp start_word("/start@" <> bot),
    do: if(bot =~ ~r/\A[A-Za-z0-9_]+\z/, do: {:ok, bot}, else: :error)

  defp start_word(_), do: :error

  # `/start@other_bot` is somebody else's command. A bot name we cannot learn
  # is not held against the sender.
  defp ours?(nil, _username), do: true
  defp ours?(_bot, nil), do: true
  defp ours?(bot, username), do: String.downcase(bot) == String.downcase(username)

  # One outcome per chat, so a chat gets one answer however many times it wrote
  # (and a flood of `/start` from one chat costs one lookup, not a hundred):
  # `{:linked, user}` | `:already` | `:expired`. A link wins over a failure
  # earlier in the batch — junk first must not cost the chat its valid token.
  defp link_commands(connection_uuid, commands) do
    commands
    |> Enum.reduce(%{}, fn {chat_id, token}, outcomes ->
      case outcomes do
        %{^chat_id => {:linked, _}} -> outcomes
        _ -> link_one(connection_uuid, chat_id, token, outcomes)
      end
    end)
    |> Map.to_list()
  end

  defp link_one(connection_uuid, chat_id, token, outcomes) do
    with {:ok, %{user_uuid: user_uuid}} <- consume_token(token, connection_uuid),
         %{} = user <- Auth.get_user(user_uuid),
         {:ok, _} <- link_chat(user, connection_uuid, chat_id) do
      Map.put(outcomes, chat_id, {:linked, user})
    else
      _ -> Map.put_new_lazy(outcomes, chat_id, fn -> failure(connection_uuid, chat_id) end)
    end
  end

  defp failure(connection_uuid, chat_id),
    do: if(already_linked?(connection_uuid, chat_id), do: :already, else: :expired)

  # The chat is already someone's link to this bot: a batch read again after a
  # failed confirmation, or Start pressed twice. Nothing to say to it.
  defp already_linked?(connection_uuid, chat_id),
    do: RepoHelper.repo().exists?(holders(connection_uuid, chat_id))

  # The users whose stored link is this chat of this bot. One definition for the answer to
  # "already linked?" and for `linked_user/2`, so the two cannot drift.
  defp holders(connection_uuid, chat_id) do
    from u in User,
      where:
        fragment(
          "?->'notification_channel:telegram'->>'site_chat_id' = ?",
          u.custom_fields,
          ^to_string(chat_id)
        ) and
          fragment(
            "?->'notification_channel:telegram'->>'site_connection_uuid' = ?",
            u.custom_fields,
            ^connection_uuid
          )
  end

  # After the commit: the activity entry and the answer in the chat. An
  # "expired" answer is held back when the confirmation failed — the batch
  # comes round again and would say it twice.
  defp announce(connection_uuid, {chat_id, {:linked, user}}, _confirmed?) do
    Activity.log("notifications", "telegram.linked",
      actor_uuid: user.uuid,
      resource_type: "user",
      resource_uuid: user.uuid,
      metadata: %{"connection_uuid" => connection_uuid}
    )

    reply(connection_uuid, chat_id, linked_text())
  end

  defp announce(connection_uuid, {chat_id, :expired}, true),
    do: reply(connection_uuid, chat_id, expired_text())

  defp announce(_connection_uuid, {_chat_id, _outcome}, _confirmed?), do: :ok

  defp reply(connection_uuid, chat_id, text) do
    case Client.send_message(connection_uuid, chat_id, text, owner: :system) do
      {:ok, _} -> :ok
      other -> Logger.warning("[Telegram.Linking] reply failed: #{inspect(other)}")
    end
  end

  # Names the site, never the account: the chat belongs to whoever pressed
  # Start, and the account belongs to whoever minted the link.
  defp linked_text do
    gettext("Connected to %{site}. Your notifications will arrive in this chat.",
      site: Settings.get_project_title()
    )
  end

  defp expired_text do
    gettext(
      "This link has expired or was already used. Open your notification settings on %{site} and press Connect Telegram again.",
      site: Settings.get_project_title()
    )
  end

  # --- Storage ------------------------------------------------------------------

  @doc """
  Records the link on the user, unless they are not `linkable?/1` (`{:error, :not_linkable}`).
  The FIRST link also switches on the notification
  types the user already receives in the app; later links keep whatever the
  user chose. A channel the delivery worker had switched off because the old
  chat was dead is switched back on.
  """
  @spec link_chat(map(), String.t(), integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def link_chat(%{uuid: user_uuid}, connection_uuid, chat_id) do
    # Fresh from the database: `ChannelConfig.update/3` writes back what it read.
    user = Auth.get_user!(user_uuid)

    if linkable?(user) do
      ChannelConfig.update(user, @channel, fn config ->
        config
        |> Map.drop(["status", "disabled_reason", "link_dropped_at"])
        |> Map.put("enabled", true)
        |> Map.put("site_chat_id", to_string(chat_id))
        |> Map.put("site_connection_uuid", connection_uuid)
        |> Map.put(
          "linked_at",
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        )
        |> put_default_types(user)
      end)
    else
      {:error, :not_linkable}
    end
  end

  defp put_default_types(%{"types" => %{}} = config, _user), do: config

  defp put_default_types(config, user) do
    types =
      Types.list()
      |> Enum.flat_map(fn type -> [type.key | Enum.map(type.sub_types, & &1.key)] end)
      |> Map.new(&{&1, Prefs.user_wants_type?(user, &1)})

    Map.put(config, "types", types)
  end

  @doc """
  Removes the site-bot link. The routing choices stay: linking again should not
  make the user pick them all over.
  """
  @spec unlink(map()) :: :ok | {:error, term()}
  def unlink(%{uuid: user_uuid}) do
    user = Auth.get_user!(user_uuid)

    case ChannelConfig.update(
           user,
           @channel,
           &Map.drop(&1, ["site_chat_id", "site_connection_uuid", "linked_at", "link_dropped_at"])
         ) do
      {:ok, _} ->
        Activity.log("notifications", "telegram.unlinked",
          actor_uuid: user_uuid,
          resource_type: "user",
          resource_uuid: user_uuid
        )

        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The user whose site-bot link is chat `chat_id` of the bot `connection_uuid`, read from
  the database now, or `nil`. A chat linked by two accounts names nobody, and neither a
  service user (`api_only`) nor a managed organization (`managed_by_members`) is anybody's
  link. The user is not checked any further (active, confirmed): that is the caller's
  account gate (`PhoenixKit.Users.Auth.SessionRef.scope_for_user/2`).

  Looking it up reads `users` by two JSON paths, with no index behind them: it is meant for
  a link's own chat (one lookup per message), not for scanning.
  """
  @spec linked_user(String.t(), integer() | String.t()) :: User.t() | nil
  def linked_user(connection_uuid, chat_id)
      when is_binary(connection_uuid) and (is_binary(chat_id) or is_integer(chat_id)) do
    query =
      from u in holders(connection_uuid, chat_id),
        where: u.api_only == false and u.managed_by_members == false,
        limit: 2

    case RepoHelper.repo().all(query) do
      [user] -> user
      _none_or_ambiguous -> nil
    end
  end

  def linked_user(_connection_uuid, _chat_id), do: nil

  @doc """
  Drops the site-bot link of the user `user_uuid` (the chat, the bot and the time) and the
  link tokens they minted and have not used, in two statements that touch nothing else: the
  routing choices stay, as with `unlink/1`. The tokens go first, as in `link_batch/2`, so a
  racing link transaction and a drop take the rows in the same order. When a link was there
  it leaves a `link_dropped_at` mark for the card to explain, and a `telegram.link_dropped`
  entry in the activity feed (no chat, no bot; `:actor_uuid` names who did it, when the
  caller knows). Runs inside the caller's transaction when there is one, and logs from
  inside it: a caller that can still roll back must call it after its validating step.
  See "A link is a standing credential" in the moduledoc.
  """
  @spec drop_links(String.t(), keyword()) :: :ok
  def drop_links(user_uuid, opts \\ []) when is_binary(user_uuid) do
    repo = RepoHelper.repo()
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    # A token is not bound to the session that minted it: one kept from before the
    # recovery would link a chat again.
    repo.delete_all(
      from t in UserToken, where: t.user_uuid == ^user_uuid and t.context == @context
    )

    {dropped, _} =
      repo.update_all(
        from(u in User,
          where:
            u.uuid == ^user_uuid and
              fragment(
                "? #>> '{notification_channel:telegram,site_chat_id}' IS NOT NULL",
                u.custom_fields
              ),
          update: [
            set: [
              custom_fields:
                fragment(
                  "jsonb_set(((? #- '{notification_channel:telegram,site_chat_id}') #- '{notification_channel:telegram,site_connection_uuid}') #- '{notification_channel:telegram,linked_at}', '{notification_channel:telegram,link_dropped_at}', to_jsonb(?::text))",
                  u.custom_fields,
                  ^now
                )
            ]
          ]
        ),
        []
      )

    if dropped > 0 do
      Activity.log("notifications", "telegram.link_dropped",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "user",
        resource_uuid: user_uuid
      )
    end

    :ok
  end

  @typedoc "The private chat an update comes from: its id, as a number."
  @type chat_id :: integer()

  @doc """
  The chat of `update` (a raw update of the bot) if it is a **private** chat written to by
  that very person: a `message` whose chat is private and whose sender is that chat, or a
  `callback_query` (a button) pressed by the person whose private chat holds it. Anything
  else is `:error`: a group or channel, a sender other than the chat, an update without a
  sender, any other kind of update.

  This is the one place that says whose update it is. A host that acts for a chat builds
  its reference with `actor_ref/2`, never from a field of its own.
  """
  @spec chat_for_update(term()) :: {:ok, chat_id()} | :error
  def chat_for_update(%{
        "message" => %{"chat" => %{"type" => "private", "id" => id}, "from" => %{"id" => id}}
      })
      when is_integer(id),
      do: {:ok, id}

  def chat_for_update(%{
        "callback_query" => %{
          "from" => %{"id" => id},
          "message" => %{"chat" => %{"type" => "private", "id" => id}}
        }
      })
      when is_integer(id),
      do: {:ok, id}

  def chat_for_update(_update), do: :error

  @doc """
  The `PhoenixKit.API.Executor` reference (`{:telegram_link, user_uuid, connection_uuid,
  chat_id}`) of the chat `update` came from, for the site bot `connection_uuid`: the update
  passes `chat_for_update/1` and the chat is linked to one user now (`linked_user/2`).
  `:error` otherwise. The executor checks the link again on every call.
  """
  @spec actor_ref(String.t(), term()) ::
          {:ok, {:telegram_link, String.t(), String.t(), chat_id()}} | :error
  def actor_ref(connection_uuid, update) when is_binary(connection_uuid) do
    with {:ok, chat_id} <- chat_for_update(update),
         %User{uuid: user_uuid} <- linked_user(connection_uuid, chat_id) do
      {:ok, {:telegram_link, user_uuid, connection_uuid, chat_id}}
    else
      _ -> :error
    end
  end

  def actor_ref(_connection_uuid, _update), do: :error

  @doc "The user's site-bot link as `%{chat_id:, connection_uuid:, linked_at:}`, or `nil`."
  @spec linked(map()) ::
          %{chat_id: String.t(), connection_uuid: String.t(), linked_at: String.t() | nil} | nil
  def linked(user) do
    config = ChannelConfig.for_channel(user, @channel)

    with chat_id when is_binary(chat_id) and chat_id != "" <- config["site_chat_id"],
         uuid when is_binary(uuid) <- config["site_connection_uuid"] do
      %{chat_id: chat_id, connection_uuid: uuid, linked_at: config["linked_at"]}
    else
      _ -> nil
    end
  end
end
