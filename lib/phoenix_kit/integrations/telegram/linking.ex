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

  The stored link is `custom_fields["notification_channel:telegram"]`
  (`"site_chat_id"`, `"site_connection_uuid"`, `"linked_at"`), next to the
  routing the notification channel already keeps there.
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
  alias PhoenixKit.Users.Auth.UserToken

  @context "telegram_link"
  @ttl_minutes 15
  @channel "telegram"
  # Anything shaped like one of our tokens gets an answer when it fails; any
  # other `/start` payload is somebody else's business.
  @token_shape ~r/\A[A-Za-z0-9_-]{32,64}\z/

  @doc "How long a link stays good, in minutes."
  @spec ttl_minutes() :: pos_integer()
  def ttl_minutes, do: @ttl_minutes

  @doc """
  Mints a link token for `user` on site bot `connection_uuid`, replacing the
  user's earlier one.
  """
  @spec create_token(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_token(%{uuid: user_uuid} = user, connection_uuid) when is_binary(connection_uuid) do
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
        {:ok, []} -> {:ok, %{linked: 0}}
        {:ok, updates} when is_list(updates) -> handle_updates(connection_uuid, updates)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Links the chats of a batch of updates already read from the bot
  `connection_uuid`: every private `/start <token>` links its chat to the
  token's owner, and the chat is answered. Other updates are passed over.

  `opts[:confirm]` is how the batch is confirmed to Telegram once the links are
  committed: a function of the updates answering `:ok` or `:error`. The default
  confirms by `getUpdates` with the next offset, as `poll/1` needs; a resident
  reader that moves the offset itself passes `fn _updates -> :ok end`. An
  "expired" answer is held back when the confirmation failed (the batch comes
  round again).

  Returns `{:ok, %{linked: n}}`, or `:busy` when another node is linking this
  bot's batch right now (nothing was done; read the batch again).
  """
  @spec handle_updates(String.t(), [map()], keyword()) ::
          {:ok, %{linked: non_neg_integer()}} | :busy
  def handle_updates(connection_uuid, updates, opts \\ [])
      when is_binary(connection_uuid) and is_list(updates) do
    confirm = Keyword.get(opts, :confirm, &confirm(connection_uuid, &1))

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
  appended) holds this bot. A reader that cannot answer does not hold it.

  Anything else that would call `getUpdates` on a bot must ask first: a second
  reader takes the updates away from the resident one.
  """
  @spec resident_reader?(String.t()) :: boolean()
  def resident_reader?(connection_uuid) do
    case Application.get_env(:phoenix_kit, :telegram_updates_reader) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        apply(mod, fun, args ++ [connection_uuid]) == true

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
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
  defp already_linked?(connection_uuid, chat_id) do
    RepoHelper.repo().exists?(
      from u in PhoenixKit.Users.Auth.User,
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
  Records the link on the user. The FIRST link also switches on the notification
  types the user already receives in the app; later links keep whatever the
  user chose. A channel the delivery worker had switched off because the old
  chat was dead is switched back on.
  """
  @spec link_chat(map(), String.t(), integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def link_chat(%{uuid: user_uuid}, connection_uuid, chat_id) do
    # Fresh from the database: `ChannelConfig.update/3` writes back what it read.
    user = Auth.get_user!(user_uuid)

    ChannelConfig.update(user, @channel, fn config ->
      config
      |> Map.drop(["status", "disabled_reason"])
      |> Map.put("enabled", true)
      |> Map.put("site_chat_id", to_string(chat_id))
      |> Map.put("site_connection_uuid", connection_uuid)
      |> Map.put(
        "linked_at",
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )
      |> put_default_types(user)
    end)
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
           &Map.drop(&1, ["site_chat_id", "site_connection_uuid", "linked_at"])
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
  the database now, or `nil`. A chat linked by two accounts names nobody, and a service
  user (`api_only`) is nobody's link. The user is not checked any further (active,
  confirmed): that is the caller's account gate.
  """
  @spec linked_user(String.t(), integer() | String.t()) :: PhoenixKit.Users.Auth.User.t() | nil
  def linked_user(connection_uuid, chat_id)
      when is_binary(connection_uuid) and (is_binary(chat_id) or is_integer(chat_id)) do
    query =
      from u in PhoenixKit.Users.Auth.User,
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
            ) and u.api_only == false,
        limit: 2

    case RepoHelper.repo().all(query) do
      [user] -> user
      _none_or_ambiguous -> nil
    end
  end

  def linked_user(_connection_uuid, _chat_id), do: nil

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
