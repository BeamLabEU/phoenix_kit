defmodule PhoenixKit.Integrations.Telegram do
  @moduledoc """
  Send messages via a stored Telegram bot integration, plus the one-shot
  read primitive the notification **chat-linking** flow needs.

  Telegram puts the bot token in the URL path (`/bot<token>/<method>`) rather
  than an `Authorization` header, so it can't ride the header-based
  `PhoenixKit.Integrations.authenticated_request/4`. This module resolves the
  token via `Integrations.get_credentials/2` (owner-scoped, so a connection is
  only reachable by an owner entitled to it) and calls the Bot API directly.

  Scope is deliberately narrow: **sending** (and answering a button press),
  plus a **one-shot `getUpdates`** used to discover a user's `chat_id` when they
  link their chat. A streaming receiver is not here: a host that runs one hands
  its batches to `Linking.handle_updates/3` (see `Telegram.Linking`).

      Telegram.send_message(conn_uuid, chat_id, "Deploy finished ✅")
      Telegram.send_message(conn_uuid, chat_id, "*Alert*", parse_mode: "MarkdownV2")

  `chat_id` is the numeric id of a user/group/channel, or `"@channelusername"`.
  A user must have messaged the bot first (Telegram's anti-spam rule) — which is
  exactly what the chat-link `/start` step arranges.
  """

  require Logger

  alias PhoenixKit.Integrations

  @api_base "https://api.telegram.org"
  @timeout 15_000

  # --- Send -----------------------------------------------------------------

  @doc """
  Sends a text message via a stored Telegram connection.

  Opts: `:parse_mode` (`"MarkdownV2"` / `"HTML"`), `:silent` (no notification
  sound), `:reply_markup` (inline/keyboard map), and `:owner` for the credential
  lookup (`:system` default, or `{type, id}`). Returns `{:ok, message}` (the
  sent Message object) or `{:error, reason}`.
  """
  @spec send_message(String.t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(uuid, chat_id, text, opts \\ []) when is_binary(uuid) do
    with_token(uuid, opts, &send_message_with_token(&1, chat_id, text, opts))
  end

  @doc "Like `send_message/4` but with a raw bot token instead of a connection uuid."
  @spec send_message_with_token(String.t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message_with_token(token, chat_id, text, opts \\ []) when is_binary(token) do
    %{chat_id: chat_id, text: text}
    |> maybe_put(:parse_mode, opts[:parse_mode])
    |> maybe_put(:disable_notification, opts[:silent])
    |> maybe_put(:reply_markup, opts[:reply_markup])
    |> then(&request(token, "sendMessage", &1))
  end

  @doc """
  Answers a press on an inline button (`answerCallbackQuery`), so the client
  stops showing it as pending. Opts: `:text` (a short notice shown to the user),
  `:show_alert` (as an alert instead of a toast), and `:owner` for the
  credential lookup. Returns `{:ok, true}` or `{:error, reason}`.
  """
  @spec answer_callback_query(String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def answer_callback_query(uuid, callback_query_id, opts \\ [])
      when is_binary(uuid) and is_binary(callback_query_id) do
    with_token(uuid, opts, fn token ->
      %{callback_query_id: callback_query_id}
      |> maybe_put(:text, opts[:text])
      |> maybe_put(:show_alert, opts[:show_alert])
      |> then(&request(token, "answerCallbackQuery", &1))
    end)
  end

  @doc """
  Replaces the text of a message the bot sent earlier (`editMessageText`).

  Opts: `:parse_mode` (`"MarkdownV2"` / `"HTML"`), `:reply_markup` (inline
  keyboard map; omitted, Telegram drops the old keyboard), `:disable_web_page_preview`
  (no link preview), and `:owner` for the credential lookup. Returns
  `{:ok, message}` (or `{:ok, true}`) or `{:error, reason}` — editing to the
  same text is an error (`"Bad Request: message is not modified"`).
  """
  @spec edit_message_text(
          String.t(),
          integer() | String.t(),
          integer(),
          String.t(),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def edit_message_text(uuid, chat_id, message_id, text, opts \\ [])
      when is_binary(uuid) and is_integer(message_id) and is_binary(text) do
    with_token(uuid, opts, fn token ->
      %{chat_id: chat_id, message_id: message_id, text: text}
      |> maybe_put(:parse_mode, opts[:parse_mode])
      |> maybe_put(:reply_markup, opts[:reply_markup])
      |> maybe_put_preview(opts[:disable_web_page_preview])
      |> then(&request(token, "editMessageText", &1))
    end)
  end

  @doc """
  Shows a chat action such as "typing…" (`sendChatAction`); Telegram clears it
  after ~5 seconds or when the bot sends a message. `action` defaults to
  `"typing"`. Opts: `:owner` for the credential lookup. Returns `{:ok, true}`
  or `{:error, reason}`.
  """
  @spec send_chat_action(String.t(), integer() | String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_chat_action(uuid, chat_id, action \\ "typing", opts \\ [])
      when is_binary(uuid) and is_binary(action) do
    with_token(uuid, opts, &request(&1, "sendChatAction", %{chat_id: chat_id, action: action}))
  end

  # --- Chat linking (one-shot reads; NOT a receive pipeline) ----------------

  @doc """
  Reads recent updates for the bot — the one-shot primitive the chat-linking
  flow uses to discover a user's `chat_id` after they `/start` the bot.

  Omits `offset` by default, so pending updates are read without confirming
  or discarding them. A negative offset discards older updates in Telegram;
  pass one only when that is intended. `allowed_updates` is also omitted
  unless supplied, preserving the bot's existing update subscription.
  Returns `{:ok, [update]}` or `{:error, reason}`.
  """
  @spec get_updates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_updates(uuid, opts \\ []) when is_binary(uuid) do
    with_token(uuid, opts, &get_updates_with_token(&1, opts))
  end

  @doc "Like `get_updates/2` but with a raw bot token."
  @spec get_updates_with_token(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_updates_with_token(token, opts \\ []) when is_binary(token) do
    %{}
    |> maybe_put(:offset, opts[:offset])
    |> maybe_put(:allowed_updates, opts[:allowed_updates])
    |> maybe_put(:timeout, opts[:timeout])
    |> maybe_put(:limit, opts[:limit])
    |> then(&request(token, "getUpdates", &1))
  end

  @doc "The bot itself, as `getMe` reports it (`\"username\"` among other fields)."
  @spec get_me(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_me(uuid, opts \\ []) when is_binary(uuid) do
    with_token(uuid, opts, &request(&1, "getMe", %{}))
  end

  @doc """
  The bot's webhook, as `getWebhookInfo` reports it (`"url"` is `""` when none
  is set). A bot with a webhook gets no `getUpdates`, so linking by deep link
  cannot work on it.
  """
  @spec get_webhook_info(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_webhook_info(uuid, opts \\ []) when is_binary(uuid) do
    with_token(uuid, opts, &request(&1, "getWebhookInfo", %{}))
  end

  # --- Internals ------------------------------------------------------------

  # Resolve the bot token for a stored connection (owner-scoped via `:owner`),
  # then hand it to `fun`. Shared by every uuid-taking function above.
  defp with_token(uuid, opts, fun) do
    case Integrations.get_credentials(uuid, Keyword.take(opts, [:owner])) do
      {:ok, %{"bot_token" => token}} when is_binary(token) and token != "" -> fun.(token)
      {:ok, _} -> {:error, :not_configured}
      {:error, _} = err -> err
    end
  end

  @doc false
  # Extra `Req` options for every Bot API call — tests route them through
  # `Req.Test` with `config :phoenix_kit, :telegram_req_options, plug: ...`.
  # Unset in production.
  @spec req_options() :: keyword()
  def req_options do
    :phoenix_kit |> Application.get_env(:telegram_req_options, []) |> Keyword.take([:plug])
  end

  defp request(token, method, body) do
    url = "#{@api_base}/bot#{token}/#{method}"

    case Req.post(url, [json: body, receive_timeout: @timeout] ++ req_options()) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      # Telegram returns a JSON body with a human "description" on API errors
      # (bad chat_id, bot blocked, webhook conflict, etc.) — surface it verbatim.
      {:ok, %{body: %{"description" => description}}} ->
        {:error, description}

      {:ok, %{status: status}} ->
        {:error, "Telegram error #{status}"}

      {:error, reason} ->
        Logger.warning("[Telegram] #{method} failed: #{inspect(reason)}")
        {:error, :unreachable}
    end
  end

  # `disable_web_page_preview` was superseded by `link_preview_options` in Bot API 7.0.
  defp maybe_put_preview(map, true), do: Map.put(map, :link_preview_options, %{is_disabled: true})
  defp maybe_put_preview(map, _), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
