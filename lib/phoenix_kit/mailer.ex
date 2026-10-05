defmodule PhoenixKit.Mailer do
  @moduledoc """
  Mailer module for PhoenixKit emails.

  This module handles sending emails such as
  confirmation emails, password reset emails, magic link emails, etc.

  It can work in two modes:
  1. **Built-in mode**: Uses PhoenixKit's own Swoosh mailer (default)
  2. **Delegation mode**: Uses the parent application's mailer when configured

  ## Configuration

  To use your application's mailer instead of PhoenixKit's built-in one:

      config :phoenix_kit,
        mailer: MyApp.Mailer

  When delegation is configured, all emails will be sent through your application's
  mailer, allowing you to use a single mailer configuration across your entire application.
  """

  use Swoosh.Mailer, otp_app: :phoenix_kit
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Swoosh.Email

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Integrations
  alias PhoenixKit.Mailer.SmtpTransport
  alias PhoenixKit.Users.Auth.User

  require Logger

  # Soft dependency: the optional `emails` package (not a dependency of
  # core) owns the recipient blocklist (hard bounces, spam complaints,
  # manual blocks). Referencing it as a bare module name costs nothing at
  # compile time; `check_recipient_allowed/1` below guards every call with
  # `Code.ensure_loaded?/1`, so this file has no hard dependency on the
  # optional package and every recipient is implicitly allowed when it
  # isn't installed.
  #
  # We deliberately call `check_blocklist/1`, NOT `check_limits/1`:
  # `check_limits/1` additionally enforces the emails module's per-recipient
  # (100/h) and GLOBAL (10_000/h) send caps, which are not gated by any
  # enable flag. Wiring those in here would silently throttle every outbound
  # email app-wide (auth mail included) and would cap bulk newsletter
  # broadcasts at 10k/hour. Send pacing/quotas belong to the newsletters
  # send-profile limits (roadmap Phase 5, per-profile atomic caps) — one
  # limiter, not two competing ones.
  @emails_rate_limiter PhoenixKit.Modules.Emails.RateLimiter

  @doc """
  Gets the mailer module to use for sending emails.

  Returns the configured parent application mailer if set,
  otherwise returns the built-in PhoenixKit.Mailer.

  ## Examples

      iex> PhoenixKit.Mailer.get_mailer()
      MyApp.Mailer  # if configured

      iex> PhoenixKit.Mailer.get_mailer()
      PhoenixKit.Mailer  # default
  """
  def get_mailer do
    PhoenixKit.Config.get(:mailer, __MODULE__)
  end

  @doc """
  Where an outgoing message will actually be sent, resolved the same way
  `deliver_email/2` resolves it: the operator's default send integration wins,
  then the delegated host mailer (`config :phoenix_kit, :mailer`), then the
  built-in one. The adapter element is `nil` when the resolved mailer has no
  adapter configured.

  `PhoenixKit.Config.mailer_local?/0` derives from this — anything that needs
  to know "does mail land in the local dev mailbox?" must go through one of
  the two, never through a raw config read (issue #687: the raw read answered
  for a mailer that may not be the one sending, in both directions).

  For a delegated mailer the adapter is read from
  `PhoenixKit.Config.get_parent_app/0`'s env, which assumes that app matches
  the mailer's own `:otp_app` — the same assumption the SES detection in
  delivery has always made. Set `:parent_app_name` explicitly if they differ.
  """
  @spec resolved_send_path() :: {:integration, String.t()} | {:mailer, module(), module() | nil}
  def resolved_send_path do
    case default_send_integration_uuid() do
      {:ok, uuid} ->
        {:integration, uuid}

      :error ->
        mailer = get_mailer()
        {:mailer, mailer, configured_adapter(mailer)}
    end
  end

  defp configured_adapter(__MODULE__), do: PhoenixKit.Config.get(__MODULE__, [])[:adapter]

  defp configured_adapter(mailer),
    do: PhoenixKit.Config.get_parent_app_config(mailer, [])[:adapter]

  @doc """
  Sends an email using a template from the database.

  This is the main function for sending emails using PhoenixKit's template system.
  Content is resolved through `PhoenixKit.Email.Content`, so a name is answered
  by the first of: an active database template, a host override file for the
  recipient's locale, or the caller's own `:defaults`. Usage is tracked when a
  database template supplied the content; the send is logged either way.

  Supplying `:defaults` is what lets a caller keep working once the templates
  table is retired — until then the database still wins, so adding them changes
  nothing for an install that has a row.

  ## Parameters

  - `template_name` - Name of the template in the database (e.g., "welcome_email")
  - `recipient` - Email address (string) or {name, email} tuple
  - `variables` - Map of variables to substitute in the template
  - `opts` - Additional options:
    - `:user_uuid` - Associate email with a user (for tracking)
    - `:campaign_id` - Campaign identifier (for analytics)
    - `:from` - Override from address (default: configured from_email)
    - `:reply_to` - Reply-to address
    - `:metadata` - Additional metadata map for tracking
    - `:locale` - Render in this locale instead of the one resolved from the
      recipient (a bare address carries no preference, so that resolution falls
      through to the site's content language)
    - `:paths` - Host override roots to search, overriding the configured ones
    - `:defaults` - Content to fall back to when neither a database template nor
      a host override file answers the name: a map of
      `%{subject:, text:, html:, markdown:, layout:}` (every key optional), or
      a zero-arity function returning one.
      Prefer the function for anything built with `gettext/1` — it is evaluated
      inside the recipient's locale, where a map has already been evaluated in
      whatever locale the caller happened to be in
    - `:layout` - `false` sends the content without the shared HTML layout
      (`PhoenixKit.Email.Layout`). Default `true`: content from a file or
      `:defaults` is wrapped, and text-only content gets an HTML body built
      from its text. A group name (`"billing"`) wraps it in that group's
      layout, header and footer instead, over the email's own `layout.txt`.
      A database template is never wrapped

  ## Returns

  - `{:ok, email}` - Email sent successfully
  - `{:error, :template_not_found}` - nothing answered the name: no active
    database template, no override file, no `:defaults`
  - `{:error, reason}` - Other error

  `{:error, :template_inactive}` is no longer returned, and never was: the
  provider's `get_active_template_by_name/1` already filters on
  `status == "active"`, so the branch that returned it was unreachable.

  ## Examples

      # Simple welcome email
      PhoenixKit.Mailer.send_from_template(
        "welcome_email",
        "user@example.com",
        %{"user_name" => "John", "url" => "https://app.com"}
      )

      # With user tracking
      PhoenixKit.Mailer.send_from_template(
        "password_reset",
        {"Jane Doe", "jane@example.com"},
        %{"reset_url" => "https://app.com/reset/token123"},
        user_uuid: user.uuid,
        campaign_id: "password_recovery"
      )

      # With content of its own, so the name resolves with no database row
      PhoenixKit.Mailer.send_from_template(
        "billing_invoice",
        customer.email,
        %{"invoice_number" => "INV-1"},
        defaults: fn ->
          %{subject: gettext("Your invoice"), text: gettext("Invoice {{invoice_number}}")}
        end
      )

      # With metadata
      PhoenixKit.Mailer.send_from_template(
        "order_confirmation",
        customer.email,
        %{"order_id" => "12345", "total" => "$99.99"},
        user_uuid: customer.uuid,
        campaign_id: "orders",
        metadata: %{order_id: order.id, amount: order.total}
      )
  """
  def send_from_template(template_name, recipient, variables \\ %{}, opts \\ [])
      when is_binary(template_name) do
    content =
      Content.resolve(
        template_name,
        recipient,
        variables,
        defaults_fun(Keyword.get(opts, :defaults, %{})),
        locale: Keyword.get(opts, :locale),
        paths: Keyword.get(opts, :paths),
        layout: Keyword.get(opts, :layout, true)
      )

    case content do
      %{subject: nil, text: nil, html: nil} ->
        {:error, :template_not_found}

      _resolved ->
        email =
          new()
          |> to(recipient)
          |> from(Keyword.get(opts, :from, {get_from_name(), get_from_email()}))
          |> subject(content.subject)
          |> html_body(content.html)
          |> text_body(content.text)
          |> maybe_reply_to(Keyword.get(opts, :reply_to))

        if content.db_template, do: Provider.current().track_usage(content.db_template)

        deliver_email(email, delivery_opts(template_name, content, opts))
    end
  end

  defp maybe_reply_to(email, nil), do: email
  defp maybe_reply_to(email, address), do: reply_to(email, address)

  # `:defaults` may be a map or a zero-arity function. A function is preferred
  # for anything built with `gettext/1`: `Content.resolve/5` evaluates it inside
  # the recipient's locale, and a map has already been evaluated in whatever
  # locale the caller happened to be in.
  defp defaults_fun(fun) when is_function(fun, 0), do: fun
  defp defaults_fun(map) when is_map(map), do: fn -> map end

  # Only a database template carries a uuid, a category and a source module.
  # When the content came from a file or the caller's defaults there is nothing
  # to take them from, so they are left to the caller's own opts rather than
  # invented.
  defp delivery_opts(template_name, content, opts) do
    opts
    |> Keyword.drop([:defaults, :paths, :layout])
    |> Keyword.put(:template_name, template_name)
    |> Keyword.put(:provider, detect_provider())
    |> put_db_template_opts(content.db_template)
  end

  defp put_db_template_opts(opts, nil), do: opts

  defp put_db_template_opts(opts, template) do
    opts
    |> Keyword.put(:template_uuid, template.uuid)
    |> Keyword.put_new(:campaign_id, template.category)
    |> Keyword.put(:category, template.category)
    |> Keyword.put_new(:source_module, Provider.current().get_source_module(template))
  end

  @doc """
  Delivers an email using the appropriate mailer.

  If Settings key `"default_email_integration_uuid"` is set and resolves to
  an Integrations connection with valid credentials, delivery is routed
  through that connection via `deliver_via_integration/3` (set on the core
  Emails Transactional settings page). Otherwise, if a parent application mailer is
  configured, delegates to it; failing that, uses the built-in PhoenixKit
  mailer. The setting being absent, blank, or pointing at a
  deleted/unconfigured connection is a no-op — behavior is unchanged from
  before this routing existed.

  This function also integrates with the email tracking system to log
  outgoing emails when tracking is enabled. Recipients blocklisted by the
  emails module (hard bounces, complaints, manual blocks — in `to`, `cc` or
  `bcc`) are rejected before any tracking or delivery is attempted; see
  `check_recipient_allowed/1`. Send-rate limits are deliberately NOT enforced
  here — see the soft-dependency note at the top of this module.

  ## Return shape

  Normally the adapter's own `{:ok, metadata}` (metadata shape is adapter
  specific — `%{id: message_id}` for most). When an email provider takes the
  message over for later delivery (`maybe_enqueue/2`), the result is instead
  `{:ok, %{id: ref, queued: true}}`, where `ref` identifies the queued message,
  not a message id from a relay that has not seen it yet. Callers that only
  match `{:ok, _}` are unaffected; a caller that needs the message sent on this
  process can pass `skip_queue: true`.

  When the resolved transport is the local dev mailbox and the
  `dev_mailbox_enabled` setting is off (its default — see issue #687), the
  message is written to the server log instead of being handed to any adapter,
  and the result is `{:ok, %{id: "dev-mailbox-suppressed", suppressed: true}}`.
  It reads as success on purpose — auth flows must not error over a dev-only
  transport — but no mail was sent and nothing was recorded by tracking.
  """
  def deliver_email(email, opts \\ []) do
    case default_send_integration_uuid() do
      {:ok, uuid} -> deliver_via_integration(email, uuid, opts)
      :error -> deliver_via_configured_mailer(email, opts)
    end
  end

  defp deliver_via_configured_mailer(email, opts) do
    mailer = get_mailer()

    if configured_adapter(mailer) == Swoosh.Adapters.Local and not dev_mailbox_enabled?() do
      # The local mailbox's /dev/mailbox page is unauthenticated by design and
      # this mail carries single-use tokens that exist nowhere else — delivery
      # is opt-in (issue #687). Returns before the tracking pipeline: a message
      # that was never handed to an adapter must not be recorded as sent. This
      # also short-circuits `check_recipient_allowed/1`; harmless, since nothing
      # is delivered, but it means the blocklist is not exercised with the gate
      # off against the Local adapter.
      log_suppressed_local_delivery(email)
      {:ok, %{id: "dev-mailbox-suppressed", suppressed: true}}
    else
      do_deliver_via_configured_mailer(email, opts, mailer)
    end
  end

  # Guarded like its sibling `PhoenixKit.Config.mailer_local?/0`, and for the
  # reason AGENTS.md gives: a settings read is ETS-cached, so on a cache MISS it
  # touches the database, and an unreachable one raises on an unowned checkout
  # but *exits* on a dead pool — `rescue` alone does not cover it. This read is
  # new to the delivery path, so before it nothing here could fail that way.
  #
  # `false` on failure is the fail-CLOSED direction: it suppresses the send and
  # logs the token rather than handing a message full of single-use links to an
  # unauthenticated mailbox because a pool blipped. Only reachable on a
  # Local-adapter install — `and` short-circuits, so a production adapter never
  # evaluates this at all.
  defp dev_mailbox_enabled? do
    PhoenixKit.Settings.get_boolean_setting("dev_mailbox_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp log_suppressed_local_delivery(email) do
    # This log line is the developer's ONLY way to recover the single-use
    # token while the mailbox is off — fall back to the HTML body for hosts
    # whose overridden UserNotifier sends HTML-only mail.
    body = email.text_body || email.html_body || ""

    Logger.warning("""
    PhoenixKit: outgoing email was NOT delivered — the local dev mailbox is disabled by default \
    (its /dev/mailbox page is unauthenticated; see BeamLabEU/phoenix_kit#687).
    To: #{inspect(email.to)} · Subject: #{email.subject}
    #{body}
    Enable the mailbox for this closed environment at /admin/settings/email-sending, \
    or configure a send integration there.
    """)
  end

  defp do_deliver_via_configured_mailer(email, opts, mailer) do
    with :ok <- check_recipient_allowed(email),
         {:continue, tracked_email} <- intercept_and_offer_queue(email, opts) do
      result =
        if mailer == __MODULE__ do
          # Use built-in mailer with runtime config for AWS
          deliver_with_runtime_config(tracked_email, mailer)
        else
          # Check if parent mailer also uses AWS SES
          app = PhoenixKit.Config.get_parent_app()
          config = Application.get_env(app, mailer, [])

          if config[:adapter] == Swoosh.Adapters.AmazonSES do
            # Parent mailer uses AWS SES, provide runtime config
            deliver_with_runtime_config(tracked_email, mailer, app)
          else
            # Non-AWS mailer, use standard delivery
            mailer.deliver(tracked_email)
          end
        end

      # Handle post-send tracking updates
      Provider.current().handle_after_send(tracked_email, result)
      log_delivery(tracked_email, result, configured_adapter(mailer) || mailer)

      result
    end
  end

  # One line per message handed to an adapter: what it was, who it went to
  # and what the adapter answered. The email log table belongs to the optional
  # `phoenix_kit_emails` package; without it this is the only trace a send
  # leaves, and without THIS an operator asking "did that reset email go?"
  # had nothing to read — a send that failed inside the adapter returned
  # `{:error, _}` to a caller that, for auth mail, deliberately shows the same
  # page either way.
  #
  # The recipient's local part is masked: the log says which mailbox provider
  # and enough of the address to recognise it, not the address itself. Never
  # the body — it carries single-use tokens.
  defp log_delivery(email, {:ok, _} = _result, via) do
    Logger.info(
      "[PhoenixKit.Mailer] sent #{inspect(email.subject)} to #{masked_recipients(email)} via #{delivery_label(via)}"
    )
  end

  defp log_delivery(email, {:error, reason}, via) do
    Logger.error(
      "[PhoenixKit.Mailer] FAILED #{inspect(email.subject)} to #{masked_recipients(email)} via #{delivery_label(via)}: " <>
        inspect(redact_delivery_error(reason), limit: 20, printable_limit: 500)
    )
  end

  defp log_delivery(_email, _other, _via), do: :ok

  # Adapters can echo addresses inside nested error bodies. Redact before
  # inspection truncates a string, or a long local part can survive unmasked.
  defp redact_delivery_error(text) when is_binary(text) do
    Regex.replace(~r/[\w.!\#$%&'*+\/=?^`{|}~-]+@[^\s<>"(),;:\[\]\\]+/, text, fn address ->
      mask_address(address)
    end)
  end

  defp redact_delivery_error(list) when is_list(list),
    do:
      if(list != [] and List.ascii_printable?(list),
        do: list |> List.to_string() |> redact_delivery_error(),
        else: Enum.map(list, &redact_delivery_error/1)
      )

  defp redact_delivery_error(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact_delivery_error() |> List.to_tuple()

  defp redact_delivery_error(map) when is_map(map),
    do:
      Map.new(map, fn {key, value} ->
        {redact_delivery_error(key), redact_delivery_error(value)}
      end)

  defp redact_delivery_error(other), do: other

  defp delivery_label(via) when is_atom(via), do: inspect(via)
  defp delivery_label(via) when is_binary(via), do: via
  defp delivery_label(_via), do: "unknown"

  defp masked_recipients(%Swoosh.Email{to: to}) do
    to
    |> List.wrap()
    |> Enum.map_join(", ", fn
      {_name, address} -> mask_address(address)
      address -> mask_address(address)
    end)
  end

  @doc false
  # "max@don.ee" -> "m***@don.ee". Anything that is not an address is not
  # echoed at all.
  def mask_address(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        String.first(local) <> "***@" <> domain

      _ ->
        "(unparseable address)"
    end
  end

  def mask_address(_address), do: "(unparseable address)"

  # Resolves the operator-chosen default send integration, if any. Only
  # returns `{:ok, uuid}` when the setting is a non-blank uuid that actually
  # resolves to a connection with valid credentials — a stale or deleted
  # uuid falls back to the built-in/parent-mailer path (`:error`) rather
  # than failing the send outright. NOT used by `deliver_via_integration/3`
  # itself (which takes an explicit uuid), so there is no recursion risk
  # here: this function never calls `deliver_email/2`.
  #
  # Why credentials-present (`connected?/1`) is the gate and a status check
  # would be wrong (review question, settled 2026-07-16): `disconnect/2`
  # WIPES stored credentials, so "disconnected must not send" already holds —
  # `connected?/1` is false without creds. The remaining case is status
  # "error" (a failed Test Connection) with credentials still stored: that
  # one deliberately still routes, because a stale or false-negative test
  # silently rerouting ALL mail to the built-in path is the worse surprise —
  # a genuinely broken integration fails the send loudly instead.
  @spec default_send_integration_uuid() :: {:ok, String.t()} | :error
  defp default_send_integration_uuid do
    with uuid when is_binary(uuid) and uuid != "" <-
           PhoenixKit.Settings.get_setting("default_email_integration_uuid"),
         true <- Integrations.connected?(uuid) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  # Deliver email with runtime configuration for AWS SES
  defp deliver_with_runtime_config(email, mailer, app \\ :phoenix_kit) do
    config =
      if app == :phoenix_kit do
        # Use PhoenixKit config for built-in mailer
        PhoenixKit.Config.get(mailer, [])
      else
        # Use parent app config for parent mailer
        PhoenixKit.Config.get_parent_app_config(mailer, [])
      end

    # If using AWS SES, override with runtime settings from DB
    runtime_config =
      if config[:adapter] == Swoosh.Adapters.AmazonSES do
        if Provider.current().aws_configured?() do
          config
          |> Keyword.put(:region, Provider.current().get_aws_region())
          |> Keyword.put(:access_key, Provider.current().get_aws_access_key())
          |> Keyword.put(:secret, Provider.current().get_aws_secret_key())
        else
          config
        end
      else
        config
      end

    # Use Swoosh.Mailer.deliver with runtime config
    Swoosh.Mailer.deliver(email, runtime_config)
  end

  @doc """
  Delivers an email via a specific Integrations connection (AWS SES,
  universal SMTP, or Brevo API), selected by the connection's `uuid`.

  Unlike `deliver_email/2`, this does **not** go through
  `deliver_with_runtime_config/2` — that path is hardcoded to AWS SES
  (`config[:adapter] == Swoosh.Adapters.AmazonSES`, credentials only from
  `Provider.current().get_aws_*`), so a Brevo or SMTP send routed through
  it would be misrouted or ignored. This function resolves the Swoosh
  adapter and config directly from the chosen integration's stored
  credentials instead, while preserving the same interception seam
  `deliver_email/2` uses so tracking keeps working.

  ## Returns

  - `{:ok, term()}` — delivered
  - `{:error, {:blocked, atom()}}` — a recipient (`to`/`cc`/`bcc`) is
    blocklisted by the emails module (checked before the integration is even
    resolved). Send-rate limits are NOT enforced here — see the module's
    soft-dependency note.
  - `{:error, :not_configured | :deleted}` — the integration uuid didn't resolve
  - `{:error, {:incomplete_credentials, [String.t()]}}` — the connection's
    `status` says connected, but a required field (e.g. SMTP `host`, SES
    `aws_region`) is blank — most likely edited after the last successful
    validation. Listed field names are the credential keys, never values.
  - `{:error, {:unsupported_provider, String.t()} | :unsupported_provider}` —
    the integration's provider has no known Swoosh adapter mapping (the bare
    atom when the credentials carry no provider key at all)
  - `{:error, {:invalid_smtp_port, term()}}` — the SMTP connection's port is
    not a number
  - `{:error, {:invalid_security | :invalid_verify_cert | :invalid_auth |
    :invalid_timeout, term()}}` / `{:error, :invalid_ca_cert}` — SMTP only: one
    of the operator's transport settings does not parse. Unknown values are
    refused rather than coerced back to the default, so a typo can't silently
    downgrade the connection's encryption
  - `{:error, :no_ca_store}` — SMTP only, and a **behaviour change**: there is no
    system CA bundle, so the relay's certificate cannot be verified and the
    password would go out to an unauthenticated server. Sending stops. It used to
    proceed with `verify: :verify_none`, which is why slim images (distroless,
    scratch, some Alpine builds) never noticed they had no CA store. Install one
    (e.g. `ca-certificates`) to restore sending. A relay with no credentials to
    protect still degrades rather than failing.
  """
  @spec deliver_via_integration(Swoosh.Email.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def deliver_via_integration(email, integration_uuid, opts \\ [])
      when is_binary(integration_uuid) do
    with :ok <- check_recipient_allowed(email),
         {:ok, creds} <- Integrations.get_credentials(integration_uuid),
         {:ok, {adapter, config}} <- swoosh_config_for(creds) do
      # Tell the tracking interceptor which provider actually sent this. Without
      # it, `detect_provider/2` falls back to the host app's static mailer
      # adapter (e.g. SES) and mis-attributes SMTP/Brevo integration sends
      # (plus a "no provider data" warning per send). `put_new` lets an explicit
      # caller override win.
      tracked_opts = Keyword.put_new(opts, :provider, creds["provider"])

      with {:continue, tracked_email} <- intercept_and_offer_queue(email, tracked_opts) do
        result = Swoosh.Mailer.deliver(tracked_email, [adapter: adapter] ++ config)
        Provider.current().handle_after_send(tracked_email, result)
        log_delivery(tracked_email, result, "integration #{creds["provider"] || "unknown"}")
        result
      end
    end
  end

  # Runs the tracking interceptor, then offers the message to the provider's
  # queue. Returns `{:continue, email}` to send on this process, or the queued
  # `{:ok, …}` result to hand straight back to the caller.
  #
  # The offer sits here, after interception and before *both* delivery paths, so
  # that queueing covers every outgoing message — including the ones the host app
  # sends through its own statically configured mailer, which never touch the
  # package's API. `skip_queue: true` is how the queue worker asks for the real
  # send without being handed back its own job.
  defp intercept_and_offer_queue(email, opts) do
    provider = Provider.current()

    # `already_intercepted: true` says this message has been through
    # `intercept_before_send/2` once already — it is a queue worker re-sending
    # what it dequeued, and the tracking headers added the first time travelled
    # with it. Interception is not required to be idempotent, so core must not
    # run it twice and hope.
    already_intercepted = Keyword.get(opts, :already_intercepted, false)

    tracked_email =
      if already_intercepted do
        email
      else
        provider.intercept_before_send(email, opts)
      end

    # `already_intercepted: true` can only mean "a worker is re-sending what it
    # dequeued", so it implies `skip_queue`. Left independent, a worker that
    # sets one opt and forgets the other offers its own job straight back to the
    # queue that handed it over — an enqueue loop out of a contract it is
    # possible to get half right.
    if already_intercepted or Keyword.get(opts, :skip_queue, false) do
      {:continue, tracked_email}
    else
      case offer_to_queue(provider, tracked_email, opts) do
        {:queued, ref} ->
          {:ok, %{id: ref, queued: true}}

        :continue ->
          {:continue, tracked_email}

        other ->
          # Outside the callback's contract. Send it — a provider bug must not
          # eat the message — but do not let the bug stay invisible.
          Logger.warning(
            "[PhoenixKit.Mailer] #{inspect(provider)}.maybe_enqueue/2 returned #{inspect(other)}; sending inline"
          )

          {:continue, tracked_email}
      end
    end
  end

  # `maybe_enqueue/2` is an optional callback: a package built against an older
  # core does not export it, and the DefaultProvider answers `:continue`.
  defp offer_to_queue(provider, email, opts) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :maybe_enqueue, 2) do
      provider.maybe_enqueue(email, opts)
    else
      :continue
    end
  end

  @doc false
  # Maps an Integrations connection's decrypted credentials to a Swoosh
  # `{adapter, config}` pair. Not `defp` so `deliver_via_integration/3`'s
  # provider selection can be unit-tested without triggering real
  # delivery — `@doc false` because it's an internal seam, not part of
  # the public API. The returned config carries DECRYPTED secrets — callers
  # must never log or `inspect` it.
  @spec swoosh_config_for(map()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def swoosh_config_for(%{"provider" => "aws_ses"} = creds) do
    with :ok <- require_fields(creds, ~w(aws_region access_key secret_key)) do
      {:ok,
       {Swoosh.Adapters.AmazonSES,
        [
          region: creds["aws_region"],
          access_key: creds["access_key"],
          secret: creds["secret_key"]
        ]}}
    end
  end

  def swoosh_config_for(%{"provider" => "smtp"} = creds) do
    # `SmtpTransport.config/2` is a pure function of the credentials and
    # deliberately builds valid TLS options even with a blank host (it is
    # also used by the "Test Connection" probe path) — it is not the layer
    # that decides whether a connection is ready to actually send. That
    # check belongs here, before the (secret-bearing) config reaches
    # `Swoosh.Mailer.deliver/2`. See `require_fields/2`.
    with :ok <- require_fields(creds, ~w(host)),
         {:ok, options} <- SmtpTransport.config(creds) do
      {:ok, {Swoosh.Adapters.SMTP, options}}
    end
  end

  def swoosh_config_for(%{"provider" => "brevo_api"} = creds) do
    with :ok <- require_fields(creds, ~w(api_key)) do
      {:ok, {Swoosh.Adapters.Brevo, [api_key: creds["api_key"]]}}
    end
  end

  def swoosh_config_for(%{"provider" => provider}),
    do: {:error, {:unsupported_provider, provider}}

  def swoosh_config_for(_creds), do: {:error, :unsupported_provider}

  # A stored connection's `status` can say "connected" while an individual
  # required field is blank (e.g. edited after the last successful
  # validation) -- `Integrations.has_credentials?/1` trusts that status
  # flag, not per-field presence. Without this check, a blank field reaches
  # `Swoosh.Mailer.deliver/2`, which calls the adapter's `validate_config/1`
  # and raises `ArgumentError` with `inspect(config)` -- the FULL config,
  # secrets included -- in the (uncaught) exception message. Fail closed
  # here instead, before any secret-bearing config is built.
  @spec require_fields(map(), [String.t()]) ::
          :ok | {:error, {:incomplete_credentials, [String.t()]}}
  defp require_fields(creds, keys) do
    case Enum.filter(keys, &blank?(creds[&1])) do
      [] -> :ok
      missing -> {:error, {:incomplete_credentials, missing}}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp check_recipient_allowed(%Swoosh.Email{} = email) do
    # cc/bcc too, not just to: a suppression list with a hole in it is a
    # compliance problem, and this Mailer carries all app mail, not only
    # newsletters (which only ever populate `to`).
    (email.to ++ (email.cc || []) ++ (email.bcc || []))
    |> Enum.reduce_while(:ok, fn {_name, address}, :ok ->
      case check_blocklisted(address) do
        :ok -> {:cont, :ok}
        {:blocked, reason} -> {:halt, {:error, {:blocked, reason}}}
      end
    end)
  end

  defp check_blocklisted(address) do
    if Code.ensure_loaded?(@emails_rate_limiter) and
         function_exported?(@emails_rate_limiter, :check_blocklist, 1) do
      # apply/3 intentionally, to avoid compile-time module resolution --
      # a direct call would fail `--warnings-as-errors` when the optional
      # emails package isn't a dependency (the compiler can prove the module
      # is undefined).
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(@emails_rate_limiter, :check_blocklist, [address])
    else
      :ok
    end
  rescue
    error ->
      # Fail open: this gate sits in front of ALL outbound mail (auth
      # included), so a transient DB hiccup must not take delivery down.
      Logger.error("Recipient blocklist check failed, allowing send: #{inspect(error)}")
      :ok
  end

  @doc """
  Sends a magic link email to the user.

  Uses the 'magic_link' template from the database if available,
  falls back to hardcoded template if not found.

  ## Examples

      iex> PhoenixKit.Mailer.send_magic_link_email(user, "https://app.com/magic/token123")
      {:ok, %Swoosh.Email{}}
  """
  def send_magic_link_email(%User{} = user, magic_link_url) when is_binary(magic_link_url) do
    content =
      Content.resolve(
        "magic_link",
        user,
        %{"user_email" => user.email, "magic_link_url" => magic_link_url},
        &CoreTemplates.magic_link_defaults/0
      )

    email =
      new()
      |> to({user.email, user.email})
      |> from({get_from_name(), get_from_email()})
      |> subject(content.subject)
      |> html_body(content.html)
      |> text_body(content.text)

    # Track template usage if a database template supplied the content
    if content.db_template, do: Provider.current().track_usage(content.db_template)

    deliver_email(email,
      user_uuid: user.uuid,
      template_name: "magic_link",
      campaign_id: "authentication",
      category: "system",
      source_module: "users",
      provider: detect_provider()
    )
  end

  # Detect current email provider from configuration
  defp detect_provider do
    mailer = get_mailer()

    if mailer == __MODULE__ do
      detect_builtin_provider()
    else
      detect_parent_app_provider(mailer)
    end
  end

  # Detect provider for built-in PhoenixKit mailer
  defp detect_builtin_provider do
    config = PhoenixKit.Config.get(PhoenixKit.Mailer, [])
    adapter = Keyword.get(config, :adapter)
    Provider.current().adapter_to_provider_name(adapter, "phoenix_kit_builtin")
  end

  # Detect provider for parent application mailer
  defp detect_parent_app_provider(mailer) when is_atom(mailer) do
    config = PhoenixKit.Config.get_parent_app_config(mailer, [])
    adapter = Keyword.get(config, :adapter)
    Provider.current().adapter_to_provider_name(adapter, "parent_app_mailer")
  end

  defp detect_parent_app_provider(_mailer), do: "unknown"

  @doc """
  Gets the effective "from" email address.

  Priority: Settings Database (runtime) > Config file (compile-time) >
  built-in default (`"noreply@localhost"`). Public so the Emails Transactional
  settings page can display the value that's actually in effect, even
  when no Settings override is set.
  """
  @spec get_from_email() :: String.t()
  def get_from_email do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_email") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_email) do
          {:ok, email} -> email
          # Priority 3: Default
          _ -> "noreply@localhost"
        end

      email ->
        email
    end
  end

  @doc """
  Gets the effective "from" name.

  Priority: Settings Database (runtime) > Config file (compile-time) >
  built-in default (`"PhoenixKit"`). Public so the Emails Transactional settings
  page can display the value that's actually in effect, even when no
  Settings override is set.
  """
  @spec get_from_name() :: String.t()
  def get_from_name do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_name") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_name) do
          {:ok, name} -> name
          # Priority 3: Default
          _ -> "PhoenixKit"
        end

      name ->
        name
    end
  end
end
