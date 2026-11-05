defmodule PhoenixKit.API.Executor do
  @moduledoc """
  The request flow of the machine API: what happens between "this key is
  authentic" and "here is the response".

  `PhoenixKit.API.Auth` has already done steps 1 to 3 of the flow (API
  switch, refusal of a credential in the URL, authentication). `execute/4` and
  `visible/2` do the rest and return their outcome; `call/4` and `list/2` are
  thin senders over them for the REST transport:

    4. **Tool visible.** The tool exists for this audience (`404 not_found`),
       its module is enabled (`404 module_disabled`), and the key's effective
       scopes include the tool's scope (`403 forbidden`). A tool listed in
       `api_disabled_tools`, or of a module listed in `api_disabled_modules`,
       does not exist for `PhoenixKit.API.Registry`, so it is `not_found` too.
    5. **Rate limit**, cost weighted (`PhoenixKit.API.RateLimit`, `cost/2`):
       a call costs 1 unit; only a **write** tool of the admin audience (not
       read-only) costs 1 per 50 rows of its longest top-level list, counted
       up to the tool's `max_items` (or, for a tool without one, up to 1000
       rows) at most, so a request that is refused for size cannot use up
       the key's budget. Reads and public tools cost 1 however long their
       lists are. A tool that needs another price (1 per
       query of a search batch) declares it with `Tool.cost`. The public
       audience pays 1 unit of its network bucket BEFORE the tool lookup (a
       miss in `PhoenixKit.API.Registry.find/2` costs about 2 ms, so a flood of unknown
       names must end in 429 without it). The caller's client token is read
       only after the lookup, because the tool declares which input field
       holds it (`Tool.client_token`): the call then pays its full price to
       the token's bucket (when it carries a token) and the rest of it (price
       minus 1) to the network bucket. So a call that the token's bucket
       refuses has already spent 1 unit of the network's. The admin audience
       is charged once, after the scope check, because its price depends on
       the tool. A call the lookup or the scope check refuses (unknown,
       hidden, forbidden or disabled-module tool) never reaches that charge,
       so it pays one unit
       instead: a key cannot loop on invented names for free. The answer is
       the same refusal, or `429` when the key's budget is spent; the refusal
       writes no audit entry.
    6. **Validate** the input against `max_items` and against the tool's
       `input_schema` **closed by `PhoenixKit.API.Validator.close_schema/2`**
       (so a schema that forgot `additionalProperties: false` still refuses
       unknown fields, the control fields included). `list/2` shows the
       closed schema (`input_schema/1`), the one `execute/4` validates
       against. Before that, over REST the `Idempotency-Key` header of a write
       call is merged into the input (`Flow.merge_header/1`), so it is
       validated like the field; MCP takes the key from the argument only.
    9. **Run** the handler, `apply(module, function, [input, ctx])`.
   10. **Log.** A call to a write tool (`annotations.read_only` is not
       `true`) from a key writes one `api.request` Activity entry: tool, key
       prefix, row count, outcome. Calls refused before step 6 (unknown tool,
       missing scope, rate limited) write nothing, so a refused request
       costs no write; so does a replay of a stored answer. The entry's
       outcome is `ok`, `error`, `preview` (a dry run), `confirmation_required`
       (the call asked for a code) or `pending_approval` (queued for an
       approver). The module logs its own domain changes.
   11. **Shape** the response: `200` with the handler's map as JSON, or a
       problem document (`PhoenixKit.API.Problem`).

  Steps 7 and 8 are `PhoenixKit.API.Flow`:

    7. **Idempotency** (`Flow.idempotency/1`): a write call with an
       `Idempotency-Key` claims it; a finished twin is answered from the
       store, a running twin is `409`.
    8. **Danger** (`Flow.gate/1`): `dry_run` answers the preview; a dangerous
       operation answers a preview and a confirmation code, and with a valid
       code it runs; every write of a key that requires approval, dangerous or
       not, is queued for approval instead (a repeat of an operation that
       already waits gets the same approval back, marked with the replay header
       but not stored, and still audited).

  Each step is one function taking and returning the request state, chained
  in `execute/4`. A step may also end the request with `{:done, state}`: the
  body is already set (a preview, a replay) and the handler does not run.
  The executor adds the control fields `dry_run`, `confirm_token` and
  `idempotency_key` to the schema of every write tool and closes every schema
  (`PhoenixKit.API.ControlFields`; a write tool with `replay: false` gets no
  `idempotency_key`). A read tool has none of them, so a client that sends one
  gets `422 validation_failed`: a field that would change what a write does is
  refused, never silently ignored.

  ## Scopes and work per request

  `PhoenixKit.API.Keys.verify/2` (called by `PhoenixKit.API.Auth`) has
  already computed the effective scopes of this request into `actor.scopes`
  (the key's scopes filtered by the owner's permissions right now, never
  cached). The executor **trusts those scopes and does not compute them
  again**: it would only repeat the owner lookup and the scope filtering.
  What a request still scans twice is the module registry
  (`ModuleRegistry.all_api_tools/0`: once inside `verify/2` to know the
  scopes that exist, once in `PhoenixKit.API.Registry.find/2`); that is two walks over a
  handful of modules, and sharing the result would need an API change in
  `Registry`, so 1a accepts it.

  ## The handler

  A tool's handler returns `{:ok, map}`, `{:ok, map, effects}` (the effects
  list is added to the response under `"effects"`) or
  `{:error, code, message, context}` (`code` is an atom from
  `PhoenixKit.API.Problem.statuses/0`: core's own codes plus those the
  module declares in `c:PhoenixKit.Module.api_problems/0`; an undeclared
  code answers 500). Anything else, and any exception,
  exit or throw, answers `500 internal_error` with a generic message; the
  detail goes to the log, never to the client.

  The context is a map:

    * `:actor` the `PhoenixKit.API.Actor`; `:scopes` its effective scopes;
    * `:scope`, the `PhoenixKit.Users.Auth.Scope` behind those scopes, for a handler that
      filters rows by the caller's rights: the key owner's full scope
      (`Scope.for_user(owner, narrow: false)`) for a key, the session's scope for a live
      session, `nil` for a public caller (a handler answers nothing it would filter by it).
      A key's own scopes do not narrow it: rows filtered by `ctx.scope` are the ones the
      owner sees, whatever the key's scopes;
    * `:audience`, `:language`, `:currency`, `:hosts`, `:base_url` (see
      `PhoenixKit.API.RequestContext`); `:base_url` is `nil` for a live session whose
      caller passed none;
    * `:request_id`;
    * `:via`, what asks on behalf of a live session: the `:via` option of `execute_as/5` and
      `redeem_as/6` (`"session"` by default, e.g. `"agent"`), the same value as the audit
      entry's `metadata.via`, for a module's own audit of the change. `nil` for a key, a
      public caller and an approved operation;
    * `:dry_run?`, `true` while the danger gate asks for a preview (the handler
      must then write nothing and answer `{:preview, preview, fingerprint}`, where `fingerprint`
      is a hash of the current values the operation would touch: 1 to 64 bytes of UTF-8, e.g. a
      SHA-256 in hex; any other answer is a `500`);
    * `:approved_by_uuid`, the person who approved the operation (`nil` unless it
      runs from the approval queue), `:confirmation_uuid`, the confirmation code
      or approval row it runs under (`nil` for an ordinary call) and `:progress`,
      a one-argument function a long batch may call with its partial results. It also
      keeps an approved operation alive: one that runs longer than 15 minutes without
      calling it is marked `failed` (`interrupted`) by the stuck-operation sweep, so a
      long handler calls it at least every few minutes.

  ## On behalf of a live session

  `visible_for/3`, `execute_as/5` and `redeem_as/6` run the same flow in process, without
  a `Plug.Conn`, for a person's live browser session (`PhoenixKit.Users.Auth.SessionRef`,
  an `Actor` of kind `:user`). What differs from a key:

    * the scope is rebuilt from the session **on every call**
      (`SessionRef.scope_for_session/2`): a logged-out or revoked session, a blocked
      user, a user the web's account gate would stop (unconfirmed email, missing
      referral code), a session of another user, or a reference that is not a
      `{session_token_uuid, user_uuid}` pair is `401 unauthorized`, and the scope is
      narrowed to the role the session acts as;
    * the effective scopes are `PhoenixKit.API.Keys.held_scopes_of/1` of that scope, and
      the tool's own permission is checked too (`Scope.can?/2`); a tool without a
      permission (`system.*`, which describe the calling key) is not callable;
    * reads only by default: `allow: :read` refuses a write tool
      (`PhoenixKit.API.ControlFields.write_tool?/1`) before validation and before
      `Flow.gate/1`, so nothing runs, and `visible_for/3` lists none;
    * `allow: :all` opens the write tools of the modules listed in
      `api_session_write_modules` (the "Agent may act" boxes of Settings -> API, none by
      default; `PhoenixKit.API.Config.session_write_modules/0`). A write tool of another
      module is not listed and is refused with `403 module_write_disabled`, before anything
      runs or is stored. API keys never read that list;
    * a write never runs on the first call, dangerous or not: `Flow.gate/1` answers the
      preview and holds the call in a confirmation row bound to the person
      (`PhoenixKit.API.Confirm.issue_for_user/6`), `{"status": "confirmation_required",
      "confirmation_id", "preview", "expires_at", "expires_in_seconds"}`, with no code. The
      person confirms with `redeem_as/6`, which repeats the whole path of the call with the
      same tool and arguments (see there). A `confirm_token` a session sends is refused;
    * the request context comes from the `:request_context` option, not from a
      connection, and the host's `:api_request_context` hook (which expects a
      `Plug.Conn`) is not called;
    * the rate limit is the user's own bucket (`RateLimit.check_user/2`), shared by the
      user's sessions; `api_admin_enabled` does not apply (it switches the HTTP API);
    * reads are not audited, as for a key. A write call that was charged writes one
      `api.request` Activity entry with `resource_type: "user"`, the user as actor and
      resource, and `metadata` `via` (the `:via` option, `"session"` by default), `tool`,
      `request_id`, `outcome`, `code` and `confirmation_uuid` (for a refused `redeem_as/6`,
      the uuid it was asked for), plus `replaces_confirmation_uuid` when a row whose values
      changed was replaced: never the input, the preview or the result. The handler reads
      the same `via` as `ctx.via`;
    * maintenance mode is not checked on this path: the web shows the maintenance layout
      at mount, where nothing that calls the Executor is rendered.

  The `{session_token_uuid, user_uuid}` pair is not a secret, but it is an in-process
  credential: whatever code passes it to `execute_as/5` or `visible_for/3` acts as that
  session. Take it only from the signed session of the LiveView that runs in that session
  (`SessionRef.from_session/1` in its connected mount), never from params or client events.

  ## On behalf of a linked Telegram chat

  The same two functions take a second kind of reference,
  `{:telegram_link, user_uuid, connection_uuid, chat_id}`: a person writing from the
  Telegram chat they linked to the site bot `connection_uuid`
  (`PhoenixKit.Integrations.Telegram.Linking`). Everything above holds, with these
  differences, the first being the one that matters most:

    * a chat reads by default (`allow: :read`), like a session. With `allow: :all` it
      proposes writes the same way: `visible_for/3` lists them, `execute_as/5` holds them
      in a confirmation row, and `redeem_as/6` runs one once the person confirms. The row
      is **bound to the chat**: its `context` names the bot and the chat
      (`PhoenixKit.API.Confirm.origin_context/1`), and a chat redeems, reads
      (`PhoenixKit.API.Confirm.get_for_user/3`) or turns down
      (`PhoenixKit.API.Confirm.reject_for_user/3`) only the rows held for itself. A row
      made on the site, or for another chat or bot, is refused to a chat with `409
      confirm_token_invalid` and `context.reason` `other_origin` (`reject_for_user/3` and
      `get_for_user/3`: `{:error, :foreign}`), whatever its status. The person's own site
      session may confirm a row a chat held (the same person, a stronger sign-in). A
      caller can tell whether the core allows all this with `link_writes?/0`;
    * instead of the session, the **link** is checked on every call: the user is the one
      whose link is that chat of that bot now (`Linking.linked_user/2`); an unlinked or
      relinked chat, another bot, a chat two accounts linked, a malformed reference, a
      service user or a managed organization (which have no web session of their own) is
      `401 unauthorized` with `context.reason` `:unlinked`;
    * the account gate is the session's own (`SessionRef.scope_for_user/2`), so a blocked,
      unconfirmed or invite-parked user is refused with the same answer a session gets;
    * the scope is narrowed the way a session's is that never switched
      (`narrow: true`, the user's default role): a link carries no choice of scopes like a
      key does, so it gets no more than the narrowest session of the same user would; a
      user who holds several roles and wants the chat to do more switches the default,
      not the chat;
    * the actor is `kind: :user` with `source: "telegram"` and `ctx.via` is `"telegram"`
      (unless the caller passes `via:`), so a handler (and whatever it logs) tells the
      chat from a browser session.

  The link ends with account recovery; which events end it is listed in
  `PhoenixKit.Integrations.Telegram.Linking`, "A link is a standing credential".

  Only the code that read the update from the bot may build this reference, and only from
  `Linking.actor_ref/2`, which accepts a private chat written by that very person (a
  group message's sender is not the chat); never take one from a message's text or a
  button's data. A button's data names a confirmation at most; who presses is always the
  chat `Linking.actor_ref/2` returned, and the link, the account gate, the tool's rights and
  the origin of the row are checked again at the press.
  """

  import Plug.Conn

  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Flow
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.API.OutputShape
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.RateLimit
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.RequestContext
  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.Validator
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.IpAddress

  @empty_schema %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  # An admin write costs one unit per this many rows.
  @rows_per_unit 50

  # Rows charged at most for a write tool that declares no `max_items`.
  @default_max_billable_rows 1_000

  # How much of a client-chosen tool name an answer repeats.
  @clip_codepoints 100

  @typedoc """
  A linked Telegram chat as an actor: the user, the site bot's connection and the chat.
  See "On behalf of a linked Telegram chat" above.
  """
  @type telegram_link :: {:telegram_link, String.t(), String.t(), integer() | String.t()}

  @typedoc "Who `visible_for/3` and `execute_as/5` act for."
  @type actor_ref :: SessionRef.t() | telegram_link()

  @doc """
  Whether this core lets a linked Telegram chat (`t:telegram_link/0`) propose, read, turn
  down and confirm writes: `true`. A host or module that must also run against an older
  core, which refuses them, asks `function_exported?/3` first and falls back to reads only.
  """
  @spec link_writes?() :: true
  def link_writes?, do: true

  @typedoc "Response headers to send with an outcome: the rate-limit headers."
  @type headers :: [{String.t(), String.t()}]

  @typedoc """
  What `execute/4` returns: the handler's result (the decoded map and its JSON
  encoding) or the error in `PhoenixKit.API.Problem` terms, each with the
  headers of the rate limit.
  """
  @type outcome ::
          {:ok, %{result: map(), json: binary()}, headers()}
          | {:error, atom(), String.t(), map(), headers()}

  @doc """
  Runs tool `tool_name` for the actor `PhoenixKit.API.Auth` assigned, with
  `input` (the decoded request body), and sends the response.
  """
  @spec call(Plug.Conn.t(), Tool.audience(), String.t(), term()) :: Plug.Conn.t()
  def call(conn, audience, tool_name, input) do
    case execute(conn, audience, tool_name, input) do
      {:ok, %{json: json}, headers} ->
        send_json(conn, headers, json)

      {:error, code, detail, context, headers} ->
        send_problem(conn, headers, code, detail, context)
    end
  end

  @doc """
  Runs tool `tool_name` for the actor `PhoenixKit.API.Auth` assigned, with
  `input`, and **returns** the outcome instead of sending it. This is what
  `call/4` does, minus the HTTP response, and what the MCP transport uses.

  Returns `{:ok, %{result: map, json: binary}, headers}` or
  `{:error, code, detail, context, headers}` (`code` is an atom of
  `PhoenixKit.API.Problem.statuses/0`; `context` is the map the problem
  document carries). `headers` are the rate-limit headers when the request got
  as far as the limiter, else `[]`. The `api.request` audit entry of a write
  call is written here, before returning.

  The option `:resolve_name` is a function from the name as the caller gave it
  to the name of the tool to look up. It runs after the public charge, in the
  lookup step, so a name that costs registry walks to resolve is not resolved
  for a caller the limiter has already refused.

  The option `:idempotency_header` (default `true`) says whether the
  `Idempotency-Key` HTTP header is read. The REST transport reads it; MCP
  passes `false`, because an MCP client sends the key as the `idempotency_key`
  argument and a header on the transport request is not part of the call.
  """
  @spec execute(Plug.Conn.t(), Tool.audience(), String.t(), term(), keyword()) :: outcome()
  def execute(conn, audience, tool_name, input, opts \\ []) do
    state = new_state(conn, audience, tool_name, input, opts)

    with {:ok, state} <- require_actor(state),
         {:ok, state} <- charge_before_lookup(state),
         {:ok, state} <- find_tool(state),
         {:ok, state} <- take_scopes(state),
         {:ok, state} <- check_scope(state),
         {:ok, state} <- bind_client_token(state),
         {:ok, state} <- charge_after_lookup(state),
         {:ok, state} <- Flow.merge_header(state),
         {:ok, state} <- validate(state),
         {:ok, state} <- Flow.split_control(state),
         {:ok, state} <- Flow.idempotency(state),
         {:ok, state} <- resolve_request_context(state),
         {:ok, state} <- Flow.gate(state),
         {:ok, state} <- run(state) do
      complete(state)
    else
      {:done, state} -> complete(state)
      {:error, code, detail, context, state} -> refused(state, code, detail, context)
    end
  end

  @doc """
  Sends the list of tools the actor may call: name, title, description,
  scope, schemas and annotations. For the admin audience the list is
  filtered by the key's effective scopes.
  """
  @spec list(Plug.Conn.t(), Tool.audience()) :: Plug.Conn.t()
  def list(conn, audience) do
    case visible(conn, audience) do
      {:ok, tools, headers} ->
        body = encode(%{"tools" => Enum.map(tools, &describe/1), "count" => length(tools)})
        send_json(conn, headers, body)

      {:error, code, detail, context, headers} ->
        send_problem(conn, headers, code, detail, context)
    end
  end

  @doc """
  The tools the actor may call, as `list/2` shows them, **returned** instead
  of sent. For the admin audience: the tools whose scope the key effectively
  holds, plus the scope-less ones (`system.*`); for the public audience: every
  public tool. Costs one rate-limit unit, like `list/2`.
  """
  @spec visible(Plug.Conn.t(), Tool.audience()) ::
          {:ok, [Tool.t()], headers()} | {:error, atom(), String.t(), map(), headers()}
  def visible(conn, audience) do
    state = new_state(conn, audience, nil, %{}, [])

    with {:ok, state} <- require_actor(state),
         {:ok, state} <- take_scopes(state),
         {:ok, state} <- rate_limit(state) do
      {:ok, Registry.visible_tools(audience, visible_scopes(state)), state.headers}
    else
      {:error, code, detail, context, state} -> {:error, code, detail, context, state.headers}
    end
  end

  @doc """
  The tools the live session `session_ref` (`{session_token_uuid, user_uuid}`, see
  `PhoenixKit.Users.Auth.SessionRef`) may call, for the admin audience: the read tools
  whose scope the session's scope holds (`PhoenixKit.API.Keys.held_scopes_of/1`) and whose
  permission it holds. No `system.*` tool. Costs one unit of the user's rate-limit bucket.

  Options: `:allow`, `:read` (the default: no write tool) or `:all` (also the write tools
  the session's rights reach, of the modules in `api_session_write_modules`); any other
  value raises `ArgumentError`.

  A linked Telegram chat (`t:telegram_link/0`) is listed the same tools a session of the
  same user is.

  Returns `{:ok, tools, headers}`, or `{:error, code, detail, context, headers}`
  (`:unauthorized` with `context.reason` from `t:SessionRef.refusal/0`, or `:unlinked`
  for a chat, when the actor cannot act; `:rate_limited`).
  """
  @spec visible_for(actor_ref(), :admin, keyword()) ::
          {:ok, [Tool.t()], headers()} | {:error, atom(), String.t(), map(), headers()}
  def visible_for(session_ref, :admin, opts \\ []) do
    state = session_state(session_ref, nil, %{}, opts)

    with {:ok, state} <- session_actor(state),
         {:ok, state} <- take_scopes(state),
         {:ok, state} <- rate_limit(state) do
      writes = session_write_modules(state)

      tools =
        :admin
        |> Registry.visible_tools(state.scopes)
        |> Enum.filter(&session_may_call?(state.actor.scope, &1, writes))

      {:ok, tools, state.headers}
    else
      {:error, code, detail, context, state} -> {:error, code, detail, context, state.headers}
    end
  end

  @doc """
  Runs tool `tool_name` with `input` on behalf of the live session `session_ref`
  (`{session_token_uuid, user_uuid}`), in process, and returns the outcome as
  `execute/5` does. The session's scope is rebuilt for this call; see "On behalf of a
  live session" above for what differs from a key. `session_ref` may also be a linked
  Telegram chat (`t:telegram_link/0`, see "On behalf of a linked Telegram chat").

  Options:

    * `:allow` - `:read` (the default): a write tool is refused with `403 forbidden` before
      anything runs. `:all`: a write tool of a module in `api_session_write_modules` is
      held for the person's confirmation (the answer has `"status":
      "confirmation_required"` and the `"confirmation_id"` to pass to `redeem_as/6`); one
      of another module is refused with `403 module_write_disabled`. Any other value
      raises `ArgumentError`. For a linked Telegram chat the held row is bound to the chat
      (see "On behalf of a linked Telegram chat").
    * `:request_context` - keyword list: `:language`, `:base_url`, `:hosts`, `:currency`
      (the handler context, `PhoenixKit.API.RequestContext.from_options/1`),
      `:request_id` (the context's `:request_id`) and `:ip` (the actor's `ip`).
    * `:via` - what asks, for the audit entry of a write (`metadata.via`) and the handler's
      `ctx.via`: a non-empty string of at most 64 bytes, `"session"` by default (`"telegram"` for a
      linked chat). Anything else raises `ArgumentError`.

  The core does not tell an impersonated session from the person's own: a caller that
  passes `allow: :all` must refuse a session that
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1` marks, before it calls, so an
  administrator acting as somebody else cannot propose writes in their name.
  """
  @spec execute_as(actor_ref(), :admin, String.t(), term(), keyword()) :: outcome()
  def execute_as(session_ref, :admin, tool_name, input, opts \\ []) do
    state = session_state(session_ref, tool_name, input, opts)

    with {:ok, state} <- session_actor(state),
         {:ok, state} <- find_tool(state),
         {:ok, state} <- take_scopes(state),
         {:ok, state} <- check_scope(state),
         {:ok, state} <- check_permission(state),
         {:ok, state} <- session_writes(state),
         {:ok, state} <- charge_after_lookup(state),
         {:ok, state} <- validate(state),
         {:ok, state} <- Flow.split_control(state),
         {:ok, state} <- Flow.idempotency(state),
         {:ok, state} <- Flow.gate(state),
         {:ok, state} <- run(state) do
      complete(state)
    else
      {:done, state} -> complete(state)
      {:error, code, detail, context, state} -> refused(state, code, detail, context)
    end
  end

  @doc """
  The person confirms the write their session's `execute_as/5` call was held for
  (`confirmation_uuid`, the `"confirmation_id"` of that answer). The caller brings the
  same `tool_name` and `input` again (without control fields: a `dry_run`,
  `confirm_token` or `idempotency_key` is refused with `422`); the core keeps only their
  hash.

  The call passes the whole path again, with the rights of the session that confirms
  **now**: the session must still act (`401`), the tool exist and its module be on
  (`api_disabled_modules`, `api_disabled_tools`), the module be in
  `api_session_write_modules` (`403 module_write_disabled`), the session hold the tool's
  scope and permission (`403 forbidden`), the rate limit allow it, the input validate.
  Then `PhoenixKit.API.Flow.redeem_for_session/2`: the row must be this person's, for the
  same tool and arguments, still waiting; a fresh dry run must give the fingerprint of the
  preview; the row is spent atomically, so a second confirmation of the same row is
  refused (`used`). Only then the handler runs, with `ctx.confirmation_uuid` set.

  Returns `outcome()` as `execute_as/5` does: the handler's result; the prompt of a new
  row when the values changed since the preview (`"reason": "changed"`, the old row is
  expired); or a refusal, `409 confirm_token_invalid` with `context.reason` one of
  `invalid` (unknown, or somebody else's: the same answer), `other_arguments`, `used`,
  `rejected`, `expired`. A refusal before the row is spent leaves it waiting.

  Options: `:request_context` and `:via`, as for `execute_as/5`.

  `session_ref` may be a linked Telegram chat (`t:telegram_link/0`): the link and the
  account gate are checked now, and the row must have been held for that very chat. A row
  of the site or of another chat or bot is `409 confirm_token_invalid` with
  `context.reason` `other_origin`, and stays as it was.

  As with `execute_as/5` and `allow: :all`, the caller must refuse an impersonated session
  (`PhoenixKitWeb.Users.MultiSession.impersonated?/1`) before it calls: the core cannot tell
  it from the person's own.
  """
  @spec redeem_as(actor_ref(), :admin, term(), String.t(), term(), keyword()) :: outcome()
  def redeem_as(session_ref, :admin, confirmation_uuid, tool_name, input, opts \\ []) do
    state =
      session_ref
      |> session_state(tool_name, input, Keyword.put(opts, :allow, :all))
      |> Map.put(:requested_confirmation_uuid, cast_uuid(confirmation_uuid))

    with {:ok, state} <- session_actor(state),
         {:ok, state} <- find_tool(state),
         {:ok, state} <- take_scopes(state),
         {:ok, state} <- check_scope(state),
         {:ok, state} <- check_permission(state),
         {:ok, state} <- writes_only(state),
         {:ok, state} <- session_writes(state),
         {:ok, state} <- charge_after_lookup(state),
         {:ok, state} <- validate(state),
         {:ok, state} <- Flow.split_control(state),
         {:ok, state} <- no_control(state),
         {:ok, state} <- Flow.redeem_for_session(state, confirmation_uuid),
         {:ok, state} <- run(state) do
      complete(state)
    else
      {:done, state} -> complete(state)
      {:error, code, detail, context, state} -> refused(state, code, detail, context)
    end
  end

  @typedoc "Why `tool_availability/1` shows a tool closed to a live session."
  @type closed_reason ::
          :module_disabled | :api_off | :tool_hidden | :agent_writes_off | :no_permission

  @typedoc "One admin tool as `tool_availability/1` shows it."
  @type availability :: %{
          module_key: String.t() | nil,
          module_name: String.t(),
          name: String.t(),
          kind: :read | :write,
          permission: String.t(),
          scope: String.t(),
          danger: nil | :always | {module(), atom()},
          status: :available | {:closed, [closed_reason(), ...]}
        }

  @closed_reasons [:module_disabled, :api_off, :tool_hidden, :agent_writes_off, :no_permission]

  @doc """
  Every admin tool of every registered module, switched on or off, with whether a person's
  live session may call it (`visible_for/3` and `execute_as/5` with `allow: :all`) and, if
  not, why. Read-only: nothing is charged or written (no audit entry). API keys are not
  affected (they never read `api_session_write_modules`).

  Each entry is `%{module_key, module_name, name, kind, permission, scope, danger, status}`:
  `kind` is `:read` or `:write` (`PhoenixKit.API.ControlFields.write_tool?/1`), `danger` the
  tool's own, `status` `:available` or `{:closed, reasons}`, the reasons in this order:

    * `:module_disabled` - the module is switched off;
    * `:api_off` - the module's API is switched off (`api_disabled_modules`). When
      `api_disabled_tools` or `api_disabled_modules` cannot be read every tool is closed as
      `:api_off`, since the registry then serves nothing;
    * `:tool_hidden` - the tool is listed in `api_disabled_tools`;
    * `:agent_writes_off` - a write tool whose module is not in `api_session_write_modules`
      (the "Agent may act" boxes of Settings -> API; a list that cannot be read is empty);
    * `:no_permission` - only when `scope` (a `PhoenixKit.Users.Auth.Scope`) is given. For a
      tool the settings leave open: the scope fails the checks of `visible_for/3`, its
      permission (`PhoenixKit.Users.Auth.Scope.can?/2`) or its scope
      (`PhoenixKit.API.Keys.held_scopes_of/1`). For a tool the settings close: the scope's
      roles do not grant the tool's permission, whether or not the module behind it is on.
      The scope rule is not applied to a closed tool, so opening it may still leave it
      closed as `:no_permission`, when another tool on its scope needs a permission the
      scope lacks.

  The scope is taken as given, account checks included: a session's own is
  `SessionRef.scope_for_session/2` (which refuses an inactive or unconfirmed account),
  narrowed to the role it acts as; a scope built otherwise is the caller's to vouch for.

  Without `scope` the reasons are the install's settings alone. With the scope of a live
  session, the `:available` tools are exactly what `visible_for/3` lists for it with
  `allow: :all`. `api_admin_enabled` switches the HTTP API and does not apply to a session,
  so it is not a reason here. Core's `system.*` tools (never callable by a session) and
  public tools are not listed; neither is a tool the registry ignores because another module
  declared its name first. Sorted by module name, then by tool name.

  The list names every admin tool whatever `scope` is given, so gate who may see it. It
  walks every module's tools and reads the settings on each call: call it once per page
  (mount or params), not per render.
  """
  @spec tool_availability(Scope.t() | nil) :: [availability()]
  def tool_availability(scope \\ nil)

  def tool_availability(scope) when is_nil(scope) or is_struct(scope, Scope) do
    settings = availability_settings()
    held = if scope, do: Keys.held_scopes_of(scope), else: []

    ModuleRegistry.api_module_tools()
    |> Enum.flat_map(fn module -> Enum.map(module.tools, &{module, &1}) end)
    |> Enum.filter(fn {_module, tool} -> tool.audience == :admin end)
    |> Enum.reject(&shadowed?(&1, settings))
    |> Enum.uniq_by(fn {module, tool} -> {module.module, tool.name} end)
    |> Enum.map(fn {module, tool} -> availability(module, tool, settings, scope, held) end)
    |> Enum.sort_by(&{String.downcase(&1.module_name), &1.name})
  end

  # The settings the registry and a session's writes read, once per call. `served` is the
  # module tools the registry keeps (enabled modules, API on), as `{module, name}` pairs.
  defp availability_settings do
    writes = Config.session_write_modules()

    with {:ok, hidden_tools} <- Config.fetch_disabled_tools(),
         {:ok, hidden_modules} <- Config.fetch_disabled_modules() do
      served =
        hidden_modules
        |> ModuleRegistry.all_api_tools()
        |> MapSet.new(&{&1.module, &1.name})

      %{
        readable?: true,
        hidden_tools: hidden_tools,
        hidden_modules: hidden_modules,
        served: served,
        writes: writes
      }
    else
      :unreadable ->
        %{readable?: false, hidden_tools: [], hidden_modules: [], served: nil, writes: writes}
    end
  end

  # A tool of a module that is on, with its API on, that the registry dropped anyway: its
  # name was taken by a module registered before it.
  defp shadowed?({module, tool}, %{readable?: true} = settings) do
    module.enabled? and module.key not in settings.hidden_modules and
      not MapSet.member?(settings.served, {module.module, tool.name})
  end

  defp shadowed?(_module_tool, _settings), do: false

  defp availability(module, tool, settings, scope, held) do
    configured? =
      module.enabled? and settings.readable? and module.key not in settings.hidden_modules and
        tool.name not in settings.hidden_tools

    reasons = %{
      module_disabled: not module.enabled?,
      api_off: not settings.readable? or module.key in settings.hidden_modules,
      tool_hidden: tool.name in settings.hidden_tools,
      agent_writes_off: write?(tool) and module.key not in settings.writes,
      no_permission: scope != nil and not session_reaches?(scope, tool, held, configured?)
    }

    %{
      module_key: module.key,
      module_name: module.name,
      name: tool.name,
      kind: if(write?(tool), do: :write, else: :read),
      permission: tool.permission,
      scope: tool.scope,
      danger: tool.danger,
      status:
        case Enum.filter(@closed_reasons, &Map.fetch!(reasons, &1)) do
          [] -> :available
          closed -> {:closed, closed}
        end
    }
  end

  # The checks of `visible_for/3` for a tool the settings leave open. For a closed tool,
  # whether its role grants the tool's permission at all: `Scope.can?/2` also asks the
  # module behind the key to be on, so a switched-off module's own key would read as
  # missing; and a closed tool's scope is never held (`Keys.held_scopes_of/1` counts the
  # callable tools only).
  defp session_reaches?(scope, tool, held, true = _configured?),
    do: tool.scope in held and session_may_hold?(scope, tool)

  defp session_reaches?(scope, %Tool{permission: permission}, _held, false = _configured?),
    do: permission_granted?(scope, permission)

  defp permission_granted?(scope, permission) when is_binary(permission) do
    Scope.has_module_access?(scope, permission) and
      case Permissions.parent_key(permission) do
        nil -> true
        base -> Scope.has_module_access?(scope, base)
      end
  end

  defp permission_granted?(_scope, _permission), do: false

  defp allow!(opts) do
    case Keyword.get(opts, :allow, :read) do
      allow when allow in [:read, :all] ->
        allow

      other ->
        raise ArgumentError,
              "allow: #{inspect(other)} is not supported: a session may read (allow: :read) or also write with confirmation (allow: :all)"
    end
  end

  defp default_via({:telegram_link, _user_uuid, _connection_uuid, _chat_id}), do: "telegram"
  defp default_via(_session_ref), do: "session"

  defp via!(opts, default) do
    case Keyword.get(opts, :via, default) do
      via when is_binary(via) and byte_size(via) in 1..64 ->
        via

      other ->
        raise ArgumentError,
              "via: #{inspect(other)} is not supported: give a non-empty string of at most 64 bytes"
    end
  end

  # --- state ----------------------------------------------------------------

  defp new_state(conn, audience, tool_name, input, opts) do
    audience
    |> base_state(tool_name, input, opts)
    |> Map.merge(%{conn: conn, actor: actor_for(conn, audience)})
  end

  # A call on behalf of a live session: no connection, so the request context is taken
  # from the options (never from the host hook, which expects a `Plug.Conn`) and the
  # actor is resolved from the session by `session_actor/1`.
  # A reference that is not a `{session_token_uuid, user_uuid}` pair names no session:
  # `session_actor/1` refuses it as gone.
  defp session_state(session_ref, tool_name, input, opts) do
    request = request_options(Keyword.get(opts, :request_context, []))

    allow = allow!(opts)

    :admin
    |> base_state(tool_name, input, idempotency_header: false)
    |> Map.merge(%{
      allow: allow,
      via: via!(opts, default_via(session_ref)),
      session_ref: session_pair(session_ref),
      client_ip: binary_option(request, :ip),
      request_id: binary_option(request, :request_id),
      request_context: RequestContext.from_options(request)
    })
  end

  defp session_pair({_token_uuid, _user_uuid} = session_ref), do: session_ref

  defp session_pair({:telegram_link, user_uuid, connection_uuid, chat_id} = link)
       when is_binary(user_uuid) and is_binary(connection_uuid) and
              (is_binary(chat_id) or is_integer(chat_id)),
       do: link

  defp session_pair({:telegram_link, _user_uuid, _connection_uuid, _chat_id}),
    do: :malformed_link

  defp session_pair(_other), do: nil

  # The confirmation a `redeem_as/6` asks for, for its audit entry: only a uuid is written
  # down, whatever else the caller passed.
  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast_uuid(_value), do: nil

  # Only `{atom, value}` pairs count: anything else in the list (or a list that is not a
  # keyword list at all) is dropped, so a malformed context gets the defaults.
  defp request_options(options) when is_list(options) or is_map(options),
    do: Enum.filter(options, &match?({key, _value} when is_atom(key), &1))

  defp request_options(_other), do: []

  defp binary_option(options, key) do
    case Keyword.get(options, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp base_state(audience, tool_name, input, opts) do
    %{
      conn: nil,
      session_ref: nil,
      allow: :read,
      via: nil,
      client_ip: nil,
      request_id: nil,
      audience: audience,
      name: tool_name,
      resolve_name: Keyword.get(opts, :resolve_name),
      idempotency_header?: Keyword.get(opts, :idempotency_header, true),
      input: input,
      rows: rows(input),
      actor: nil,
      tool: nil,
      scopes: [],
      headers: [],
      charged?: false,
      body: nil,
      control: %{},
      dry_run?: false,
      input_hash: nil,
      claim: nil,
      replayed?: false,
      held_again?: false,
      store?: true,
      outcome: nil,
      confirmation: nil,
      requested_confirmation_uuid: nil,
      replaces_confirmation_uuid: nil,
      preview: nil,
      result: nil,
      request_context: nil
    }
  end

  defp actor_for(conn, :public) do
    case conn.assigns[:phoenix_kit_api_actor] do
      %Actor{} = actor -> actor
      _none -> %Actor{kind: :anonymous, ip: IpAddress.client_address(conn)}
    end
  end

  defp actor_for(conn, :admin), do: conn.assigns[:phoenix_kit_api_actor]

  # A public tool names the input field that holds its anonymous caller's token
  # (`Tool.client_token`), so the token can only be read once the tool is known. The raw
  # token is a credential: only its hash is kept on the actor, for rate limiting, the
  # scope of an idempotency key and the binding of a confirmation code.
  defp bind_client_token(
         %{audience: :public, tool: %Tool{client_token: field}, input: input, actor: actor} =
           state
       )
       when is_binary(field) do
    {:ok, %{state | actor: %{actor | client_token_hash: client_token_hash(input, field)}}}
  end

  defp bind_client_token(state), do: {:ok, state}

  defp client_token_hash(%{} = input, field) do
    case Map.get(input, field) do
      token when is_binary(token) and token != "" ->
        :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

      _no_token ->
        nil
    end
  end

  defp client_token_hash(_input, _field), do: nil

  # --- steps ----------------------------------------------------------------

  defp require_actor(%{actor: %Actor{kind: :key}} = state), do: {:ok, state}
  defp require_actor(%{audience: :public, actor: %Actor{}} = state), do: {:ok, state}

  defp require_actor(state),
    do: {:error, :unauthorized, "Authentication is required.", %{}, state}

  # The scope of a live session, rebuilt for this call: the session must still be alive,
  # belong to the user named in the reference, and its user be active and pass the
  # account gate of the web (`SessionRef.scope_for_session/2`).
  defp session_actor(%{session_ref: {token_uuid, user_uuid}} = state) do
    case SessionRef.scope_for_session(token_uuid, user_uuid) do
      {:ok, %Scope{} = scope} -> {:ok, %{state | actor: user_actor(state, scope, nil)}}
      {:error, reason} -> session_refused(state, reason)
    end
  end

  # A linked Telegram chat: the chat must be linked to that very user now, and the user
  # pass the same account gate as a session, narrowed like a session that never switched.
  defp session_actor(
         %{session_ref: {:telegram_link, user_uuid, connection_uuid, chat_id}} = state
       ) do
    case link_scope(user_uuid, connection_uuid, chat_id) do
      {:ok, %Scope{} = scope} -> {:ok, %{state | actor: user_actor(state, scope, "telegram")}}
      {:error, reason} -> session_refused(state, reason)
    end
  end

  defp session_actor(%{session_ref: :malformed_link} = state),
    do: session_refused(state, :unlinked)

  defp session_actor(state), do: session_refused(state, :session_gone)

  @doc false
  # The scope of a linked Telegram chat as it stands now: the chat must be linked to that very
  # user (`:unlinked` otherwise, also for a malformed reference) and the user pass the
  # account gate of a session (`SessionRef.scope_for_user/2`), narrowed like a session that
  # never switched. The one place that rule lives: `session_actor/1` and
  # `PhoenixKit.API.Confirm` both use it.
  @spec link_scope(term(), term(), term()) :: {:ok, Scope.t()} | {:error, atom()}
  def link_scope(user_uuid, connection_uuid, chat_id) do
    with %User{uuid: ^user_uuid} = user <-
           Linking.linked_user(connection_uuid, chat_id),
         {:ok, %Scope{} = scope} <- SessionRef.scope_for_user(user, narrow: true) do
      {:ok, scope}
    else
      {:error, reason} -> {:error, reason}
      _not_linked -> {:error, :unlinked}
    end
  end

  defp user_actor(state, %Scope{} = scope, source) do
    %Actor{
      kind: :user,
      source: source,
      user_uuid: scope.user.uuid,
      scopes: Keys.held_scopes_of(scope),
      scope: scope,
      ip: state.client_ip
    }
  end

  defp session_refused(state, reason),
    do: {:error, :unauthorized, session_refusal(reason), %{reason: reason}, state}

  defp session_refusal(:session_gone), do: "The session has ended."
  defp session_refusal(:mismatch), do: "The session belongs to another user."
  defp session_refusal(:inactive), do: "The user is blocked."
  defp session_refusal(:unconfirmed), do: "The user's email is not confirmed."
  defp session_refusal(:referral_required), do: "The user has not entered a referral code."
  defp session_refusal(:unlinked), do: "The chat is not linked to this user."
  # Only a linked chat reaches the two below (`SessionRef.scope_for_user/2`), and
  # `Linking.linked_user/2` filters both first: they are the second layer, not a dead end.
  defp session_refusal(:service_user), do: "A service user has no session."

  defp session_refusal(:managed_organization),
    do: "A managed organization has no session of its own."

  defp find_tool(%{name: name} = state) when not is_binary(name),
    do: {:error, :not_found, "Unknown tool.", %{}, state}

  defp find_tool(%{audience: audience, name: name, resolve_name: resolve_name} = state) do
    name = if is_function(resolve_name, 1), do: resolve_name.(name), else: name

    case Registry.find(name, audience) do
      {:ok, %Tool{} = tool} ->
        {:ok, %{state | tool: tool}}

      {:error, :not_found} ->
        clipped = clip(name)
        {:error, :not_found, "Unknown tool #{inspect(clipped)}.", %{tool: clipped}, state}

      {:error, :module_disabled} ->
        clipped = clip(name)

        {:error, :module_disabled, "The module that provides #{clipped} is disabled.",
         %{tool: clipped}, state}
    end
  end

  # The effective scopes are already on the actor and are not computed again. For a
  # `:key`, `Keys.verify/2` filtered the key's scopes by its owner's permissions for this
  # very request (never cached: blocking the owner or removing a role takes effect on the
  # next call). For a `:user`, `session_actor/1` took `Keys.held_scopes_of/1` of the
  # session's scope on this call.
  defp take_scopes(%{actor: %Actor{kind: kind, scopes: scopes}} = state)
       when kind in [:key, :user],
       do: {:ok, %{state | scopes: scopes}}

  defp take_scopes(state), do: {:ok, state}

  defp check_scope(%{tool: %Tool{scope: nil}} = state), do: {:ok, state}

  defp check_scope(%{tool: %Tool{scope: scope}, scopes: scopes} = state) do
    if scope in scopes do
      {:ok, state}
    else
      {:error, :forbidden, "#{holder(state)} lacks #{scope}.", %{required_scope: scope}, state}
    end
  end

  defp holder(%{actor: %Actor{kind: :user, source: "telegram"}}), do: "This chat"
  defp holder(%{actor: %Actor{kind: :user}}), do: "This session"
  defp holder(_state), do: "This key"

  # A session's own check of the tool's permission, besides the scope: the scope rule
  # already demands every permission behind a scope, this keeps the tool called by name
  # to its own. A tool without a permission (`system.*`) describes the calling key and is
  # not for a session.
  defp check_permission(%{actor: %Actor{scope: scope}, tool: %Tool{} = tool} = state) do
    if session_may_hold?(scope, tool) do
      {:ok, state}
    else
      {:error, :forbidden, "This session may not call #{tool.name}.", %{tool: tool.name}, state}
    end
  end

  defp session_may_hold?(scope, %Tool{scope: tool_scope, permission: permission})
       when is_binary(tool_scope) and is_binary(permission),
       do: Scope.can?(scope, permission)

  defp session_may_hold?(_scope, _tool), do: false

  @doc false
  # Whether the live session's `scope` may still write with `tool_name`, by the checks
  # `redeem_as/6` makes before it runs: the tool is callable (`Registry.find/2`: its module
  # on, the module's API on, the tool not hidden) and writes, the scope holds its scope and
  # its permission, and its module is in `api_session_write_modules`.
  # `PhoenixKit.API.Confirm.get_for_user/3` reads a preview only then.
  @spec session_may_write?(Scope.t(), String.t()) :: boolean()
  def session_may_write?(%Scope{} = scope, tool_name) when is_binary(tool_name) do
    case Registry.find(tool_name, :admin) do
      {:ok, %Tool{} = tool} ->
        write?(tool) and tool.scope in Keys.held_scopes_of(scope) and
          session_may_hold?(scope, tool) and
          module_writes?(tool, Config.session_write_modules())

      {:error, _reason} ->
        false
    end
  end

  # `writes` is the list of modules whose writes the call may see (`[]` for `allow: :read`).
  defp session_may_call?(scope, %Tool{} = tool, writes),
    do: session_may_hold?(scope, tool) and (not write?(tool) or module_writes?(tool, writes))

  defp session_write_modules(%{allow: :all}), do: Config.session_write_modules()
  defp session_write_modules(_state), do: []

  defp module_writes?(%Tool{module: module}, writes),
    do: ModuleRegistry.api_module_key(module) in writes

  # A write tool of a session, before validation and `Flow.gate/1`: refused under
  # `allow: :read`; under `allow: :all` refused unless its module is in
  # `api_session_write_modules`, so a module nobody opened neither runs nor stores a
  # confirmation.
  defp session_writes(%{tool: %Tool{} = tool, allow: allow} = state) do
    cond do
      not write?(tool) ->
        {:ok, state}

      allow != :all ->
        {:error, :forbidden, "#{tool.name} writes; this call allows reads only.",
         %{tool: tool.name}, state}

      module_writes?(tool, session_write_modules(state)) ->
        {:ok, state}

      true ->
        {:error, :module_write_disabled,
         "The module that provides #{tool.name} does not let a session write.",
         %{tool: tool.name}, state}
    end
  end

  # `redeem_as/6`: only a write was held for confirmation.
  defp writes_only(%{tool: %Tool{} = tool} = state) do
    if write?(tool) do
      {:ok, state}
    else
      {:error, :forbidden, "#{tool.name} does not write: there is nothing to confirm.",
       %{tool: tool.name}, state}
    end
  end

  # `redeem_as/6` repeats the held call; a control field would change what it does (a
  # `dry_run` would spend the confirmation without running), so none is accepted.
  defp no_control(%{control: control} = state) when map_size(control) == 0, do: {:ok, state}

  defp no_control(%{control: control} = state) do
    errors =
      for name <- control |> Map.keys() |> Enum.sort(),
          do: %{path: name, message: "is not accepted when confirming", limit: nil, allowed: nil}

    {:error, :validation_failed, "The input does not match the schema of #{state.tool.name}.",
     %{errors: errors}, state}
  end

  # `Registry.find/2` costs about 2 ms on a miss (it asks the switched-off
  # modules), so the public audience, whose callers need no key, is charged
  # BEFORE the lookup: a flood of unknown tool names ends in 429 without the
  # lookup. What it pays there is 1 unit of the network bucket only: the client
  # token is not known before the tool is. The admin audience is charged after
  # the lookup, because its price depends on the tool and its caller is
  # authenticated.
  defp charge_before_lookup(%{audience: :public} = state), do: rate_limit(state)
  defp charge_before_lookup(state), do: {:ok, state}

  defp charge_after_lookup(%{audience: :admin} = state), do: rate_limit(state)

  # The public audience paid 1 unit of the network bucket before the lookup. Now the
  # tool and its client token are known: the token's bucket is charged the full price and
  # the network's the rest. A call with no token and a price of 1 has nothing left to pay.
  defp charge_after_lookup(
         %{audience: :public, tool: %Tool{} = tool, input: input, actor: actor} = state
       ) do
    case {actor.client_token_hash, cost(tool, input)} do
      {nil, 1} ->
        {:ok, state}

      {hash, cost} ->
        (actor.ip || "unknown")
        |> RateLimit.check_public(hash, cost, cost - 1)
        |> limited(state)
    end
  end

  defp rate_limit(%{audience: :admin, actor: %Actor{kind: :user, user_uuid: user_uuid}} = state) do
    user_uuid
    |> RateLimit.check_user(cost(state.tool, state.input))
    |> limited(state)
  end

  defp rate_limit(%{audience: :admin, actor: actor} = state) do
    actor.key_uuid
    |> RateLimit.check_admin(cost(state.tool, state.input))
    |> limited(state)
  end

  # Before the lookup, and for the list of tools: the network bucket, 1 unit.
  defp rate_limit(%{audience: :public, actor: actor} = state) do
    (actor.ip || "unknown")
    |> RateLimit.check_public(nil, 1)
    |> limited(state)
  end

  defp limited({:ok, headers}, state),
    do: {:ok, %{state | headers: headers, charged?: true}}

  defp limited({:error, retry_after, headers}, state) do
    {:error, :rate_limited, "Too many requests.", %{retry_after: retry_after},
     %{state | headers: headers}}
  end

  defp validate(%{tool: tool, input: input} = state) when is_map(input) do
    case validate_input(tool, input) do
      {:ok, valid} -> {:ok, %{state | input: valid}}
      {:error, errors} -> invalid(state, errors)
    end
  end

  defp validate(state) do
    invalid(state, [%{path: "", message: "must be a JSON object", limit: nil, allowed: nil}])
  end

  # Every root schema is closed here: an unknown top-level field is a
  # validation error. A write tool also gets the control fields
  # (`PhoenixKit.API.ControlFields`).
  @doc """
  The input schema the executor enforces for `tool`: the tool's own schema,
  closed at the root with `additionalProperties: false`, with string keys, and for a write
  tool with the control fields (`dry_run`, `confirm_token`, `idempotency_key`).
  MCP's `inputSchema` and OpenAPI's request body are built from it, so a client
  is told exactly what the validator will accept.
  Nested objects retain the module's policy; declare `additionalProperties: false`
  on each nested object that must reject unknown fields.
  """
  @spec input_schema(Tool.t()) :: map()
  def input_schema(%Tool{input_schema: schema} = tool),
    do: Validator.close_schema(schema || @empty_schema, ControlFields.properties(tool))

  defp invalid(state, errors) do
    {:error, :validation_failed, "The input does not match the schema of #{state.tool.name}.",
     %{errors: errors}, state}
  end

  @doc false
  # The `max_items` check and the closed-schema validation of a request, as one function.
  # `validate/1` calls it; an approval calls it again at decision time.
  @spec validate_input(Tool.t(), map()) :: {:ok, map()} | {:error, [map()]}
  def validate_input(%Tool{} = tool, input) when is_map(input) do
    with :ok <- check_max_items(tool, input) do
      Validator.validate(input_schema(tool), input)
    end
  end

  @doc false
  # The tool lookup and scope check of a request (`find_tool/1`, `check_scope/1`), for code
  # that has no request: `{:ok, tool}` or the code, detail and context of the refusal.
  @spec authorize_tool(String.t(), :admin | :public, [String.t()]) ::
          {:ok, Tool.t()} | {:error, atom(), String.t(), map()}
  def authorize_tool(name, audience, scopes) when is_binary(name) do
    state = %{audience: audience, name: name, resolve_name: nil, scopes: scopes, tool: nil}

    with {:ok, state} <- find_tool(state),
         {:ok, state} <- check_scope(state) do
      {:ok, state.tool}
    else
      {:error, code, detail, context, _state} -> {:error, code, detail, context}
    end
  end

  @doc false
  # The one definition of the handler context's shape. Every key is always present; a
  # field that is not given gets its safe default; a field that is not a context key is
  # dropped. A request and an approved operation both build their context here.
  @spec context_from(map()) :: map()
  def context_from(%{} = fields) do
    actor = Map.get(fields, :actor)

    %{
      actor: actor,
      scopes: Map.get(fields, :scopes) || (actor && actor.scopes) || [],
      scope: Map.get(fields, :scope) || actor_scope(actor),
      audience: Map.get(fields, :audience) || :admin,
      language: Map.get(fields, :language),
      currency: Map.get(fields, :currency),
      hosts: Map.get(fields, :hosts) || [],
      base_url: Map.get(fields, :base_url),
      request_id: Map.get(fields, :request_id),
      dry_run?: Map.get(fields, :dry_run?) == true,
      approved_by_uuid: Map.get(fields, :approved_by_uuid),
      confirmation_uuid: Map.get(fields, :confirmation_uuid),
      via: Map.get(fields, :via),
      progress: Map.get(fields, :progress) || fn _partial -> :ok end
    }
  end

  defp actor_scope(%Actor{scope: scope}), do: scope
  defp actor_scope(_actor), do: nil

  @doc false
  @spec context_keys() :: [atom()]
  def context_keys, do: %{} |> context_from() |> Map.keys()

  defp check_max_items(%Tool{max_items: max}, input) when is_integer(max) do
    case largest_list(input) do
      {field, count} when count > max ->
        {:error,
         [
           %{
             path: field,
             message: "must have at most #{max} items",
             limit: max,
             allowed: nil
           }
         ]}

      _within_limit ->
        :ok
    end
  end

  defp check_max_items(_tool, _input), do: :ok

  # A dry run: the handler answers a preview and writes nothing.
  defp run(%{dry_run?: true} = state), do: run_preview(state)

  # The handler runs under a rescue: whatever it does, the client gets a
  # problem document and the key keeps working. What the log learns, never the
  # values the handler worked on:
  #
  #   * a bad result: its shape (`LogSafe.shape/1`);
  #   * a throw or an exit: the kind and the shape of the reason;
  #   * an exception: its module always, its message only for the exceptions
  #     with a fixed message (`ArithmeticError`, `FunctionClauseError`; see
  #     `LogSafe`), and the stacktrace with the frames' arguments replaced by
  #     their count (`exception_report/2`).
  defp run(%{tool: %Tool{handler: {module, function}}, input: input} = state) do
    case apply(module, function, [input, build_ctx(state)]) do
      {:ok, result} when is_map(result) ->
        {:ok, %{state | body: encode(result), result: result}}

      {:ok, result, effects} when is_map(result) and is_list(effects) ->
        result = Map.put(result, "effects", effects)
        {:ok, %{state | body: encode(result), result: result}}

      {:error, code, message, context}
      when is_atom(code) and is_binary(message) and is_map(context) ->
        error_result(state, code, message, context)

      other ->
        crashed(state, "returned #{LogSafe.shape(other)}")
    end
  rescue
    error -> crashed(state, exception_report(error, __STACKTRACE__))
  catch
    kind, reason -> crashed(state, "#{kind}: #{LogSafe.shape(reason)}")
  end

  # A message that is not valid UTF-8 cannot be encoded as JSON; it is a broken
  # handler like any other bad result.
  defp error_result(state, code, message, context) do
    if String.valid?(message),
      do: {:error, code, message, context, state},
      else: crashed(state, "returned an error whose message is not valid UTF-8")
  end

  # What the log learns about an exception: `LogSafe.exception_label/1` (its
  # module, its message only for the fixed-message kinds) and the stacktrace with the
  # frames' argument values replaced by their count (a `FunctionClauseError`
  # frame carries the arguments) and without the frame of an undefined call.
  @doc false
  def exception_report(error, stacktrace) do
    frames = stacktrace |> without_undefined_call(error) |> Enum.map(&without_arguments/1)
    LogSafe.exception_label(error) <> "\n" <> Exception.format_stacktrace(frames)
  end

  # The frame of an undefined call names the module the code tried to call,
  # and a handler can build that name from a request value
  # (`Module.concat([value])`). The frame below it still names the handler and
  # the line.
  defp without_undefined_call(
         [{module, function, _arguments, _location} | rest],
         %UndefinedFunctionError{module: module, function: function}
       ),
       do: rest

  defp without_undefined_call(stacktrace, _error), do: stacktrace

  # A stacktrace frame with its arguments replaced by their count: the
  # `{module, function, arguments, location}` of a call and the
  # `{fun, arguments, location}` of an anonymous function. Public only for
  # its test: the second form does not occur in a stacktrace the BEAM builds
  # today.
  @doc false
  def without_arguments({module, function, arguments, location}) when is_list(arguments),
    do: {module, function, length(arguments), location}

  def without_arguments({fun, arguments, location}) when is_list(arguments),
    do: {fun, length(arguments), location}

  def without_arguments(frame), do: frame

  defp crashed(state, what) do
    Logger.error(
      "[PhoenixKit.API] tool #{state.tool.name} failed (request #{request_id(state)}): #{what}"
    )

    {:error, :internal_error, "The tool failed unexpectedly.", %{}, state}
  end

  # --- outcomes -------------------------------------------------------------

  # A request that ended with an answer: the handler's, or one a `Flow` step
  # ended (a preview, a confirmation prompt, a replay). The audit entry is
  # written here and the idempotency claim is finished; the answer of a replay
  # carries the `idempotent-replayed` header, and so does the held answer of a
  # call that an approval already waits for (`held_again?`).
  defp complete(%{body: body, result: result} = state) do
    log_write(state, state.outcome || "ok", nil)
    Flow.finish(state)

    {:ok, %{result: result, json: body}, replay_headers(state)}
  end

  # The limiter's own refusal has already been charged; it is answered as it
  # stands, not charged again.
  defp refused(state, :rate_limited, detail, context),
    do: failed(state, :rate_limited, detail, context)

  # An admin call the lookup or the scope check refused never met the limiter
  # (`charged?` is still false and the caller is a key or a live session; nothing
  # else can end an admin request there). It pays one unit, as a `ping` does, so
  # unknown names are not free; an empty budget turns the refusal into `429`.
  # `charged?` stays false: a refusal writes no audit entry. A session that could
  # not act at all (gone, blocked) has no actor and pays nothing.
  defp refused(
         %{audience: :admin, charged?: false, actor: %Actor{kind: :key, key_uuid: key_uuid}} =
           state,
         code,
         detail,
         context
       ),
       do: key_uuid |> RateLimit.check_admin(1) |> refusal_charged(state, code, detail, context)

  defp refused(
         %{audience: :admin, charged?: false, actor: %Actor{kind: :user, user_uuid: user_uuid}} =
           state,
         code,
         detail,
         context
       ),
       do: user_uuid |> RateLimit.check_user(1) |> refusal_charged(state, code, detail, context)

  defp refused(state, code, detail, context), do: failed(state, code, detail, context)

  defp refusal_charged(charge, state, code, detail, context) do
    case charge do
      {:ok, headers} ->
        failed(%{state | headers: headers}, code, detail, context)

      {:error, retry_after, headers} ->
        failed(
          %{state | headers: headers},
          :rate_limited,
          "Too many requests.",
          %{retry_after: retry_after}
        )
    end
  end

  # A refused or failed request releases its idempotency claim, so the same
  # key can be retried.
  defp failed(state, code, detail, context) do
    Flow.release(state)
    log_write(state, "error", code)

    {:error, code, detail, context, state.headers}
  end

  defp replay_headers(%{replayed?: true, headers: headers}),
    do: headers ++ [{"idempotent-replayed", "true"}]

  defp replay_headers(%{held_again?: true, headers: headers}),
    do: headers ++ [{"idempotent-replayed", "true"}]

  defp replay_headers(%{headers: headers}), do: headers

  # --- responses ------------------------------------------------------------

  defp send_json(conn, headers, body) do
    conn
    |> put_headers(headers)
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, body)
  end

  defp send_problem(conn, headers, code, detail, context) do
    conn
    |> put_headers(headers)
    |> Problem.send(code, detail, context)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_resp_header(acc, String.downcase(name), to_string(value))
    end)
  end

  defp encode(map), do: JSON.encode!(map)

  # --- the audit entry ------------------------------------------------------

  # Only calls that were charged (`charged?` is set once rights and rate limit
  # have passed; for the public audience the charge comes before the lookup,
  # so the tool may still be unknown), and only for a key or a live session: an
  # anonymous public write belongs to the module that owns it and must not fill the
  # activity table.
  defp audit?(%{replayed?: true}), do: false

  defp audit?(%{charged?: true, tool: %Tool{} = tool, actor: %Actor{kind: kind}})
       when kind in [:key, :user],
       do: write?(tool)

  defp audit?(_state), do: false

  defp write?(%Tool{} = tool), do: ControlFields.write_tool?(tool)

  defp log_write(%{tool: tool, actor: actor} = state, outcome, code) do
    if audit?(state), do: write_entry(state, tool, actor, outcome, code)

    :ok
  end

  # A session's entry: who, through what, which tool and how it ended. Never the input, the
  # preview or the result, which hold the data the person works on. `confirmation_uuid` is
  # the row the call held, spent or was answered with; for a `redeem_as/6` refused before
  # (or without) a claim, the uuid it asked for. An answer that replaced a row whose values
  # changed also names the old one, `replaces_confirmation_uuid`.
  defp write_entry(state, tool, %Actor{kind: :user} = actor, outcome, code) do
    metadata = %{
      "via" => state.via,
      "tool" => tool.name,
      "request_id" => request_id(state),
      "outcome" => outcome,
      "code" => code && Atom.to_string(code),
      "confirmation_uuid" =>
        (state.confirmation && state.confirmation.uuid) || state.requested_confirmation_uuid
    }

    metadata =
      case state.replaces_confirmation_uuid do
        nil -> metadata
        old_uuid -> Map.put(metadata, "replaces_confirmation_uuid", old_uuid)
      end

    Activity.log("api", "api.request",
      actor_uuid: actor.user_uuid,
      mode: "auto",
      resource_type: "user",
      resource_uuid: actor.user_uuid,
      metadata: metadata
    )
  end

  defp write_entry(state, tool, actor, outcome, code) do
    Activity.log("api", "api.request",
      actor_uuid: actor.user_uuid,
      mode: "auto",
      resource_type: "api_key",
      resource_uuid: actor.key_uuid,
      metadata: %{
        "via" => "api",
        "tool" => tool.name,
        "key_prefix" => actor.key_prefix,
        "request_id" => request_id(state),
        "rows" => state.rows,
        "outcome" => outcome,
        "code" => code && Atom.to_string(code)
      }
    )
  end

  # --- helpers --------------------------------------------------------------

  # The host's `:api_request_context` hook is host code (in a multi-domain install, maybe a
  # database read), and a dangerous call builds its handler context up to three times: ask once.
  defp resolve_request_context(state),
    do: {:ok, %{state | request_context: RequestContext.resolve(state.conn)}}

  defp build_ctx(state) do
    context = Map.get(state, :request_context) || RequestContext.resolve(state.conn)

    context_from(%{
      actor: state.actor,
      scopes: state.scopes,
      audience: state.audience,
      language: context.language,
      currency: context.currency,
      hosts: context.hosts,
      base_url: context.base_url,
      request_id: request_id(state),
      dry_run?: state.dry_run?,
      confirmation_uuid: state.confirmation && state.confirmation.uuid,
      via: Map.get(state, :via)
    })
  end

  defp request_id(%{conn: %Plug.Conn{} = conn}), do: conn.assigns[:phoenix_kit_api_request_id]
  defp request_id(state), do: Map.get(state, :request_id)

  defp visible_scopes(%{audience: :admin, scopes: scopes}), do: scopes
  defp visible_scopes(%{audience: :public}), do: :all

  defp describe(%Tool{} = tool) do
    %{
      "name" => tool.name,
      "title" => tool.title,
      "description" => tool.description,
      "scope" => tool.scope,
      "input_schema" => input_schema(tool),
      "output_schema" => OutputShape.for_tool(tool),
      "annotations" => tool.annotations
    }
  end

  @doc """
  Rate-limit units one call of `tool` with `input` costs (the cost
  is clamped).

  1 for everything, except a tool of the admin audience that is not
  read-only: it costs `max(1, ceil(rows / 50))`, where `rows` is the length
  of the longest top-level list in the input, clamped:

    * a tool with `max_items`: `rows` counts up to `max_items` at most, so
      the price is at most `ceil(max_items / 50)`. A list above `max_items`
      is refused with 422, and a refused request must not use up the key's
      budget, so it is charged as a full batch, not as its real size;
    * a tool without `max_items`: `rows` counts up to 1000 at most, so the
      price is at most 20 units, for the same reason (the 2 MB limit of
      `PhoenixKit.API.BodyGuard` bounds the work of such a request).

  So an admin read with a long `fields` list costs 1, a public call with a
  50-line list costs 1 and an admin write of 120 rows costs 3. `nil` (the
  discovery list) and an input that is not a map cost 1.

  A tool that declares `cost:` (`PhoenixKit.API.Tool`) is priced by it
  instead.
  """
  @spec cost(Tool.t() | nil, term()) :: pos_integer()
  def cost(%Tool{cost: declared} = tool, input) when not is_nil(declared) do
    case declared_cost(declared, input) do
      {:ok, units} -> units
      :error -> default_cost(tool, input)
    end
  end

  def cost(tool, input), do: default_cost(tool, input)

  @max_cost 1000

  # The price a tool declares. A function is called with the raw input; one
  # that raises, throws or answers with anything but a positive integer is the
  # tool author's bug, so it is logged and the default rule applies instead of
  # the call being refused. Only the kind of the failure is logged, never a
  # value derived from the request.
  defp declared_cost(units, _input) when is_integer(units) and units > 0,
    do: {:ok, min(units, @max_cost)}

  defp declared_cost({module, function}, input) when is_atom(module) and is_atom(function) do
    case apply(module, function, [input]) do
      units when is_integer(units) and units > 0 ->
        {:ok, min(units, @max_cost)}

      other ->
        bad_cost(module, function, "returned #{LogSafe.shape(other)}")
    end
  rescue
    error -> bad_cost(module, function, "raised #{LogSafe.exception_label(error)}")
  catch
    kind, reason -> bad_cost(module, function, "#{kind}: #{LogSafe.shape(reason)}")
  end

  defp declared_cost(_other, _input), do: :error

  defp bad_cost(module, function, what) do
    Logger.warning(
      "[PhoenixKit.API] cost function #{inspect(module)}.#{function}/1 #{what}; using the default cost rule"
    )

    :error
  end

  defp default_cost(%Tool{audience: :admin} = tool, input) when is_map(input) do
    if write?(tool), do: max(1, ceil(billable_rows(tool, input) / @rows_per_unit)), else: 1
  end

  defp default_cost(_tool, _input), do: 1

  # A list longer than the tool's `max_items` is refused with 422 anyway, so it
  # is charged as a list of `max_items` rows: one oversized request cannot use
  # up the key's budget and turn its next valid call into a 429. A tool with
  # no `max_items` is capped at `@default_max_billable_rows` for the same
  # reason.
  defp billable_rows(%Tool{max_items: max}, input) when is_integer(max),
    do: min(rows(input), max)

  defp billable_rows(_tool, input), do: min(rows(input), @default_max_billable_rows)

  # Rows a call touches: the length of the longest list in the input, and 1
  # for an input without a list.
  defp rows(input) when is_map(input) do
    case largest_list(input) do
      {_field, count} -> max(count, 1)
      nil -> 1
    end
  end

  defp rows(_input), do: 1

  defp largest_list(input) do
    input
    |> Enum.flat_map(fn
      {field, value} when is_binary(field) and is_list(value) -> [{field, length(value)}]
      _other -> []
    end)
    |> Enum.max_by(&elem(&1, 1), fn -> nil end)
  end

  @doc false
  # Runs the handler as a dry run (used by `PhoenixKit.API.Flow`): `{:ok, state}` with
  # `state.preview` set to `%{data: map, fingerprint: binary}`, or the usual error tuple.
  @spec preview(map()) :: {:ok, map()} | {:error, atom(), String.t(), map(), map()}
  def preview(state), do: run(%{state | dry_run?: true})

  @doc false
  # The handler context of this request, with `overrides` merged over it.
  @spec context(map(), keyword()) :: map()
  def context(state, overrides \\ []),
    do: state |> build_ctx() |> Map.merge(Map.new(overrides)) |> context_from()

  defp run_preview(%{tool: %Tool{handler: {module, function}}, input: input} = state) do
    case apply(module, function, [input, build_ctx(state)]) do
      {:preview, preview, fingerprint} when is_map(preview) and is_binary(fingerprint) ->
        preview_result(state, preview, fingerprint)

      {:error, code, message, context}
      when is_atom(code) and is_binary(message) and is_map(context) ->
        error_result(state, code, message, context)

      other ->
        crashed(
          state,
          "answered a dry run with #{LogSafe.shape(other)} " <>
            "(a tool must answer a dry run with {:preview, preview, fingerprint} and write nothing)"
        )
    end
  rescue
    error -> crashed(state, exception_report(error, __STACKTRACE__))
  catch
    kind, reason -> crashed(state, "#{kind}: #{LogSafe.shape(reason)}")
  end

  # The fingerprint is kept in a confirmation code or an approval, so one the row cannot hold
  # is a failed handler here, not an exception (or a refused row) further on.
  defp preview_result(state, preview, fingerprint) do
    if Confirmation.fingerprint_valid?(fingerprint) do
      {:ok, %{state | preview: %{data: json_safe!(preview), fingerprint: fingerprint}}}
    else
      crashed(
        state,
        "answered a dry run with a fingerprint the store cannot hold " <>
          "(#{byte_size(fingerprint)} bytes; it must be 1 to #{Confirmation.fingerprint_max()} bytes of UTF-8)"
      )
    end
  end

  # The preview as the client will read it: encoded and decoded again under the rescue of
  # `run_preview/1`, so a value JSON cannot hold (a tuple, a struct without an encoder, a
  # binary that is not UTF-8) is a failed handler, not an exception out of `execute/4`.
  defp json_safe!(preview), do: preview |> JSON.encode!() |> JSON.decode!()

  # The first `@clip_codepoints` code points, not graphemes: a single grapheme
  # can carry any number of combining marks. The work is bounded by the output,
  # not by the name: the client chooses how long the name is.
  defp clip(name), do: LogSafe.take_codepoints(name, @clip_codepoints)
end
