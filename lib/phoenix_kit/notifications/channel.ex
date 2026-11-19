defmodule PhoenixKit.Notifications.Channel do
  @moduledoc """
  Behaviour for a notification **delivery channel** — an external destination a
  user can route their notifications to (Telegram, email, …), on top of the
  in-app inbox.

  Channels are pluggable: core ships some, feature modules contribute more via
  `PhoenixKit.Module`'s `notification_channels/0`, and
  `PhoenixKit.Notifications.Channels.list/0` merges them. Adding a channel is
  "implement this behaviour + register it" — the notifications core, the routing
  layer, the delivery worker, and the settings UI all work off the behaviour, so
  none of them change.

  ## Contract shape (why it's built this way)

  - **`deliver/2` takes an `t:envelope/0`, not a raw notification.** The envelope
    is a channel-neutral, already-rendered payload with an **absolute** URL — so a
    channel never reaches into the notification/activity schema and every channel
    gets the same well-formed input. Channels that need more structure (email
    wants subject + HTML) read the extra envelope fields; simple ones use `:text`.
    The recipient's locale rides along in `:locale` for channels that localize,
    but the core's built-in rendering is English today (i18n of the rendered
    strings is not wired yet) — so treat `:locale` as a hint, not a guarantee
    the `:text` is already translated.
  - **Results carry a permanent/transient taxonomy.** `deliver/2` returns
    `t:result/0` so the delivery worker can decide retry-vs-give-up generically,
    instead of every channel leaking its own retry policy (e.g. "bot blocked" is
    permanent, a 429/timeout is transient with an optional `retry_after`).
  - **`configured?/2` and `validate_config/1` keep per-user setup out of the
    core.** The router asks `configured?/2` before enqueuing; the settings page
    asks `validate_config/1` before saving.

  The per-user config map (`t:config/0`) is opaque to the core — its shape is the
  channel's business — except that the core stores it under
  `custom_fields["notification_channel:<key>"]` and reads the reserved
  `"enabled"` / `"types"` keys for routing (see
  `PhoenixKit.Notifications.ChannelConfig`).
  """

  @typedoc "A channel's opaque per-user configuration map (string keys, JSONB-safe)."
  @type config :: %{optional(String.t()) => term()}

  @typedoc """
  A channel-neutral, fully-rendered notification ready to deliver.

  `:url` is absolute (or `nil`). `:title` is set for channels that have a
  subject line (email); text-only channels ignore it. `:type_key` /
  `:notification_uuid` are for logging/idempotency, not display.
  `:reason` is the line that sent it ("You get this because “Projects ›
  Comments” is on.") and `:reason_url` the absolute link where the
  recipient changes it — both optional (nil when no line owns the
  notification); a channel shows them under the message. `:quote` is the
  message the notification carries (`Render.quote/1`), as plain text with
  its writer's name ("Anna Kask: “…”"), nil when there is none; a channel
  shows it under `:text`.
  """
  @type envelope :: %{
          optional(:reason) => String.t() | nil,
          optional(:quote) => String.t() | nil,
          optional(:reason_url) => String.t() | nil,
          recipient_uuid: String.t(),
          type_key: String.t() | nil,
          notification_uuid: String.t() | nil,
          locale: String.t() | nil,
          icon: String.t(),
          title: String.t() | nil,
          text: String.t(),
          url: String.t() | nil
        }

  @typedoc """
  Delivery outcome.

  - `:ok` — delivered.
  - `{:error, {:permanent, reason}}` — do not retry (bad chat_id, bot blocked,
    revoked connection). The worker gives up and should surface a soft-disable.
  - `{:error, {:transient, reason}}` — retry (network, 5xx, rate limit). The
    optional `retry_after` (ms) hints the backoff.
  """
  @type result ::
          :ok
          | {:error, {:permanent, term()}}
          | {:error, {:transient, term()}}
          | {:error, {:transient, term()}, retry_after :: non_neg_integer()}

  @doc "Stable string key identifying the channel (e.g. `\"telegram\"`)."
  @callback key() :: String.t()

  @doc "Human-readable label for the settings UI (e.g. `\"Telegram\"`)."
  @callback label() :: String.t()

  @doc "Heroicon name for the settings UI (e.g. `\"hero-paper-airplane\"`)."
  @callback icon() :: String.t()

  @doc """
  Whether `user_uuid` is fully set up to receive on this channel with `config`
  (e.g. a connection is selected AND a chat_id has been linked). The router
  checks this before enqueuing a delivery.
  """
  @callback configured?(user_uuid :: String.t(), config()) :: boolean()

  @doc """
  Delivers a rendered `t:envelope/0` for `config`. Runs inside the delivery
  worker (async), so a blocking network call here is fine. MUST resolve any
  credential owner-scoped to `envelope.recipient_uuid` — never trust an owner
  stored in `config`.
  """
  @callback deliver(envelope(), config()) :: result()

  @doc """
  Validates / normalizes a user-submitted config map before it's persisted
  (settings save). Returns the cleaned map or an error. Optional — defaults to
  accepting the map unchanged.
  """
  @callback validate_config(config()) :: {:ok, config()} | {:error, term()}

  @doc """
  Where a user connects this channel (a kit path, `Routes.path/1`-built),
  or nil when it cannot be connected now (Telegram with no site bot
  chosen). The settings table puts a **Connect** link in the header of an
  unconnected channel that answers a path, and leaves out one that
  answers nil. Optional — a channel without it is never offered unconnected.
  """
  @callback connect_path() :: String.t() | nil

  @optional_callbacks [validate_config: 1, connect_path: 0]
end
