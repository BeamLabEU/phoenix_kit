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
  # How long past a long poll's own `timeout` (seconds) we wait for the answer.
  @poll_margin_ms 10_000
  # The Bot API's own cap on a file a bot may download (`getFile`).
  @default_max_bytes 20 * 1024 * 1024
  @download_timeout 60_000
  # The whole file GET, not one wait for the next chunk: a server that trickles
  # bytes keeps `receive_timeout` from ever firing.
  @download_deadline_ms 120_000
  @max_file_id_bytes 1024

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
  Sets the bot's reaction to a message (`setMessageReaction`); it replaces the
  set the bot had put there. `emoji` is one emoji; `nil` or `""` clears the
  bot's reactions. Telegram accepts only its own list of reaction emoji for
  bots (👀, 👍, 🤷 are on it; ❗ is not). Opts: `:owner` for the credential lookup. Returns
  `{:ok, true}` or `{:error, reason}` — Telegram's description when it refuses
  (a message that is gone is one such refusal).
  """
  @spec set_message_reaction(
          String.t(),
          integer() | String.t(),
          integer(),
          String.t() | nil,
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def set_message_reaction(uuid, chat_id, message_id, emoji, opts \\ [])
      when is_binary(uuid) and is_integer(message_id) and (is_binary(emoji) or is_nil(emoji)) do
    body = %{chat_id: chat_id, message_id: message_id, reaction: reaction(emoji)}

    with_token(uuid, opts, &request(&1, "setMessageReaction", body))
  end

  defp reaction(emoji) when emoji in [nil, ""], do: []
  defp reaction(emoji), do: [%{type: "emoji", emoji: emoji}]

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

  # --- Files ----------------------------------------------------------------

  @doc """
  Downloads a file a user sent to the bot (a voice message, a document) and
  returns its bytes, so the caller never holds the bot token.

  Calls `getFile` for the file's path and size, then fetches the file. The
  size is checked twice: from `getFile` before anything is downloaded, and
  again while the body streams in, so a server that lies about the size cannot
  make this read more than the limit.

  Opts: `:max_bytes` (a positive integer; default 20 MB, the Bot API's own cap),
  `:deadline_ms` (a positive integer; the limit on the whole file download,
  default 120 s) and `:owner` for the credential lookup. Returns
  `{:ok, binary}` or `{:error, reason}`, where `reason` is

    * `:invalid_file_id` — not a non-empty valid UTF-8 string of sane length
    * `:invalid_max_bytes` — `:max_bytes` given and not a positive integer
    * `:timeout` — the download took longer than `:deadline_ms`
    * `{:file_too_large, size, max}` — over the limit (`size` is what `getFile`
      reported, or, when the body streamed past the limit, how much had been
      read by then)
    * `:no_file_path` / `:invalid_file_path` — `getFile` gave no usable path
    * Telegram's description when it refuses `getFile`, `"Telegram error <status>"`
      for an HTTP error of the download, `:unreachable` for a transport failure
    * `:not_configured` or the credential lookup's error

  The token is in no error term, log line or exception message.
  """
  @spec download_file(String.t(), term(), keyword()) ::
          {:ok, binary()}
          | {:error,
             :invalid_file_id
             | :invalid_max_bytes
             | :no_file_path
             | :invalid_file_path
             | :not_configured
             | :deleted
             | :unreachable
             | :timeout
             | {:file_too_large, non_neg_integer(), pos_integer()}
             | String.t()}
  def download_file(uuid, file_id, opts \\ []) when is_binary(uuid) do
    with :ok <- validate_file_id(file_id),
         {:ok, max} <- max_bytes(opts[:max_bytes]) do
      deadline_ms = positive_or(opts[:deadline_ms], @download_deadline_ms)
      with_token(uuid, opts, &download_with_token(&1, file_id, max, deadline_ms))
    end
  end

  defp validate_file_id(file_id) when is_binary(file_id) do
    if byte_size(file_id) in 1..@max_file_id_bytes and String.valid?(file_id),
      do: :ok,
      else: {:error, :invalid_file_id}
  end

  defp validate_file_id(_), do: {:error, :invalid_file_id}

  defp max_bytes(nil), do: {:ok, @default_max_bytes}
  defp max_bytes(max) when is_integer(max) and max > 0, do: {:ok, max}
  defp max_bytes(_), do: {:error, :invalid_max_bytes}

  defp positive_or(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_or(_, default), do: default

  defp download_with_token(token, file_id, max, deadline_ms) do
    with {:ok, file} <- request(token, "getFile", %{file_id: file_id}),
         {:ok, path} <- file_path(file),
         :ok <- check_size(file, max) do
      fetch_file(token, path, max, deadline_ms)
    end
  end

  defp file_path(%{"file_path" => path}) do
    # Telegram's paths are like `voice/file_7.oga`; anything else is not put
    # into the URL the token is in.
    if is_binary(path) and path =~ ~r/\A[A-Za-z0-9_.\/-]+\z/ and not String.contains?(path, "..") and
         not String.starts_with?(path, "/") do
      {:ok, path}
    else
      {:error, :invalid_file_path}
    end
  end

  defp file_path(_), do: {:error, :no_file_path}

  defp check_size(%{"file_size" => size}, max) when is_integer(size) and size > max,
    do: {:error, {:file_too_large, size, max}}

  defp check_size(_, _), do: :ok

  defp fetch_file(token, path, max, deadline_ms) do
    url = "#{@api_base}/file/bot#{token}/#{path}"

    # No redirects (the URL carries the token), no retries, and a body
    # collector that stops reading once it is past `max` or past the deadline.
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    options =
      [
        into: collector(max, deadline),
        receive_timeout: @download_timeout,
        retry: false,
        redirect: false
      ] ++ req_options()

    case Req.get(url, options) do
      {:ok, %{status: 200} = response} ->
        read_body(response, max)

      {:ok, %{status: status}} ->
        {:error, "Telegram error #{status}"}

      {:error, reason} ->
        Logger.warning("[Telegram] downloadFile failed: #{failure_reason(reason)}")
        {:error, :unreachable}
    end
  end

  # Collects the body of a 200 as an iolist in the response's private data and
  # halts the stream at the first chunk that takes it past `max`, or that
  # arrives after `deadline` (a monotonic time in ms). The body of any other
  # status is dropped unread.
  defp collector(max, deadline) do
    fn {:data, data}, {request, response} ->
      cond do
        response.status != 200 ->
          {:halt, {request, response}}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, {request, Req.Response.put_private(response, :timed_out, true)}}

        true ->
          size = Req.Response.get_private(response, :size, 0) + byte_size(data)
          chunks = Req.Response.get_private(response, :chunks, [])

          response =
            response
            |> Req.Response.put_private(:size, size)
            |> Req.Response.put_private(:chunks, [data | chunks])

          {if(size > max, do: :halt, else: :cont), {request, response}}
      end
    end
  end

  defp read_body(response, max) do
    size = Req.Response.get_private(response, :size, 0)

    cond do
      Req.Response.get_private(response, :timed_out, false) ->
        {:error, :timeout}

      size > max ->
        {:error, {:file_too_large, size, max}}

      true ->
        {:ok,
         response
         |> Req.Response.get_private(:chunks, [])
         |> Enum.reverse()
         |> IO.iodata_to_binary()}
    end
  end

  # What a failed request is logged as: the kind of failure only. A request
  # error can carry the URL (and so the token), so it is never `inspect`ed.
  defp failure_reason(%{__exception__: true, reason: reason, __struct__: module})
       when is_atom(reason),
       do: "#{inspect(module)} #{reason}"

  defp failure_reason(%{__exception__: true, __struct__: module}), do: inspect(module)

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
    |> then(&request(token, "getUpdates", &1, receive_timeout(opts[:timeout])))
  end

  @doc false
  # How long to wait for a `getUpdates` answer: a long poll (`timeout` seconds)
  # is answered up to that long after it was sent, so the wait is that plus a
  # margin. A short or absent `timeout` keeps the default wait.
  @spec receive_timeout(integer() | nil) :: pos_integer()
  def receive_timeout(timeout) when is_integer(timeout),
    do: max(@timeout, timeout * 1000 + @poll_margin_ms)

  def receive_timeout(_), do: @timeout

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

  defp request(token, method, body, receive_timeout \\ @timeout) do
    url = "#{@api_base}/bot#{token}/#{method}"

    case Req.post(url, [json: body, receive_timeout: receive_timeout] ++ req_options()) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      # Telegram returns a JSON body with a human "description" on API errors
      # (bad chat_id, bot blocked, webhook conflict, etc.) — surface it verbatim.
      {:ok, %{body: %{"description" => description}}} ->
        {:error, description}

      {:ok, %{status: status}} ->
        {:error, "Telegram error #{status}"}

      {:error, reason} ->
        Logger.warning("[Telegram] #{method} failed: #{failure_reason(reason)}")
        {:error, :unreachable}
    end
  end

  # `disable_web_page_preview` was superseded by `link_preview_options` in Bot API 7.0.
  defp maybe_put_preview(map, true), do: Map.put(map, :link_preview_options, %{is_disabled: true})
  defp maybe_put_preview(map, _), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
