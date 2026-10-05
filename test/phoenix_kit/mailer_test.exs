defmodule PhoenixKit.MailerTest.FakeBrevoApiClient do
  @moduledoc false
  # Stands in for `Swoosh.ApiClient` (`config :swoosh, :api_client, ...`)
  # so the real `Swoosh.Adapters.Brevo` code path can be exercised without
  # any real HTTP call — `post/4` runs synchronously in the calling
  # (test) process, so messaging `self()` is safe.
  @behaviour Swoosh.ApiClient

  @impl true
  def post(url, headers, body, _email) do
    send(self(), {:fake_brevo_post, url, headers, body})

    Process.get(
      :fake_brevo_response,
      {:ok, 201, [], Jason.encode!(%{"messageId" => "test-message-id"})}
    )
  end
end

defmodule PhoenixKit.Modules.Emails.RateLimiter do
  @moduledoc false
  # Stands in for the optional `emails` package's real RateLimiter (core has
  # no dependency on `phoenix_kit_emails` — confirmed absent from
  # `mix.exs`), so `Mailer.check_recipient_allowed/1`'s soft-call
  # (`Code.ensure_loaded?/1` + `function_exported?/3` + `apply/3`) can be
  # exercised for real instead of only the "module absent" branch — the
  # same reason `FakeBrevoApiClient`/`TrackingProvider` below stand in for
  # other optional/external behaviour. Mirrors the real
  # `check_blocklist/1` contract: `:ok | {:blocked, reason}`, deterministic on
  # the recipient address so no shared mutable state is needed.
  #
  # The Mailer deliberately calls `check_blocklist/1`, NOT `check_limits/1` —
  # the latter also enforces per-recipient/global send caps, which must not
  # gate app-wide mail or cap bulk broadcasts (see the Mailer's note).
  def check_blocklist("blocked@example.com"), do: {:blocked, :blocklist}
  def check_blocklist(_address), do: :ok
end

defmodule PhoenixKit.MailerTest.TrackingProvider do
  @moduledoc false
  # A `PhoenixKit.Email.Provider` implementation that notifies the test
  # process on intercept/after-send, to prove `deliver_via_integration/3`
  # preserves the same tracking seam `deliver_email/2` uses. All other
  # callbacks mirror `PhoenixKit.Email.DefaultProvider`'s no-ops.
  @behaviour PhoenixKit.Email.Provider

  @impl true
  def intercept_before_send(email, opts) do
    send(self(), {:intercept_before_send_called, opts})
    email
  end

  @impl true
  def handle_after_send(_email, result) do
    send(self(), {:handle_after_send_called, result})
    :ok
  end

  @impl true
  def get_active_template_by_name(_name), do: nil
  @impl true
  def render_template(_t, _v), do: %{subject: "", html_body: "", text_body: ""}
  @impl true
  def render_template(_t, _v, _l), do: %{subject: "", html_body: "", text_body: ""}
  @impl true
  def track_usage(_template), do: :ok
  @impl true
  def get_source_module(_template), do: nil
  @impl true
  def get_aws_region, do: ""
  @impl true
  def get_aws_access_key, do: ""
  @impl true
  def get_aws_secret_key, do: ""
  @impl true
  def aws_configured?, do: false
  @impl true
  def send_test_tracking_email(_recipient_email, _user_uuid), do: {:error, :not_supported}
  @impl true
  def adapter_to_provider_name(_adapter, default), do: default
end

defmodule PhoenixKit.MailerTest.QueuingProvider do
  @moduledoc false
  # Implements the OPTIONAL `maybe_enqueue/2` callback, to prove the queue seam:
  # the offer short-circuits the send, the caller gets the queued shape back, and
  # a worker re-sending with `skip_queue: true` / `already_intercepted: true`
  # reaches the adapter without being offered (or intercepted) a second time.
  @behaviour PhoenixKit.Email.Provider

  @impl true
  def intercept_before_send(email, opts) do
    send(self(), {:intercept_before_send_called, opts})
    email
  end

  @impl true
  def maybe_enqueue(_email, opts) do
    send(self(), {:maybe_enqueue_called, opts})
    {:queued, "queue-ref-1"}
  end

  @impl true
  def handle_after_send(_email, result) do
    send(self(), {:handle_after_send_called, result})
    :ok
  end

  @impl true
  def get_active_template_by_name(_name), do: nil
  @impl true
  def render_template(_t, _v), do: %{subject: "", html_body: "", text_body: ""}
  @impl true
  def render_template(_t, _v, _l), do: %{subject: "", html_body: "", text_body: ""}
  @impl true
  def track_usage(_template), do: :ok
  @impl true
  def get_source_module(_template), do: nil
  @impl true
  def get_aws_region, do: ""
  @impl true
  def get_aws_access_key, do: ""
  @impl true
  def get_aws_secret_key, do: ""
  @impl true
  def aws_configured?, do: false
  @impl true
  def send_test_tracking_email(_recipient_email, _user_uuid), do: {:error, :not_supported}
  @impl true
  def adapter_to_provider_name(_adapter, default), do: default
end

defmodule PhoenixKit.MailerTest do
  # async: false — one test swaps the global `:swoosh, :api_client` and
  # `:phoenix_kit, :email_provider` app env, which `Mailer.deliver_email/2`
  # and other adapters read too; keep it from racing concurrently-running
  # async test files.
  use PhoenixKit.DataCase, async: false

  import Swoosh.Email

  alias PhoenixKit.Integrations
  alias PhoenixKit.Mailer
  alias PhoenixKit.MailerTest.FakeBrevoApiClient
  alias PhoenixKit.MailerTest.TrackingProvider
  alias PhoenixKit.Settings

  describe "swoosh_config_for/1" do
    test "aws_ses credentials build an AmazonSES adapter config" do
      creds = %{
        "provider" => "aws_ses",
        "access_key" => "AKIA_T",
        "secret_key" => "S",
        "aws_region" => "eu-central-1"
      }

      assert {:ok, {Swoosh.Adapters.AmazonSES, config}} = Mailer.swoosh_config_for(creds)
      assert config[:region] == "eu-central-1"
      assert config[:access_key] == "AKIA_T"
      assert config[:secret] == "S"
    end

    test "smtp credentials build an SMTP adapter config, port as string" do
      creds = %{
        "provider" => "smtp",
        "host" => "smtp-relay.brevo.com",
        "port" => "587",
        "username" => "sub1@smtp-brevo.com",
        "password" => "not-a-real-smtp-secret"
      }

      assert {:ok, {Swoosh.Adapters.SMTP, config}} = Mailer.swoosh_config_for(creds)
      assert config[:relay] == "smtp-relay.brevo.com"
      assert config[:port] == 587
      assert config[:username] == "sub1@smtp-brevo.com"
      assert config[:password] == "not-a-real-smtp-secret"
      # 587 = mandatory STARTTLS, fail-closed (no plaintext downgrade)
      assert config[:tls] == :always
      refute Keyword.has_key?(config, :ssl)

      # TLS options are load-bearing: gen_smtp supplies none, and OTP's :ssl
      # defaults to verify_peer with no CA store, so the handshake dies without
      # them. Verified against a real relay.
      assert config[:tls_options][:verify] == :verify_peer
      assert config[:tls_options][:cacerts] != nil
      assert config[:tls_options][:server_name_indication] == ~c"smtp-relay.brevo.com"
      assert config[:tls_options][:customize_hostname_check] != nil
    end

    test "smtp credentials on port 465 use implicit TLS (ssl: true), not STARTTLS" do
      creds = %{
        "provider" => "smtp",
        "host" => "smtp.example.com",
        "port" => 465,
        "username" => "user",
        "password" => "pw"
      }

      assert {:ok, {Swoosh.Adapters.SMTP, config}} = Mailer.swoosh_config_for(creds)
      assert config[:port] == 465
      # gen_smtp opens an SSL socket only when `ssl: true`; `tls:` is STARTTLS-only
      assert config[:ssl] == true
      refute Keyword.has_key?(config, :tls)

      # For the ssl protocol gen_smtp hands `sockopts` straight to :ssl.connect,
      # so the verification options must ride there — without them the connect
      # fails outright with {:options, :incompatible, [verify: :verify_peer,
      # cacerts: :undefined]}.
      assert config[:sockopts][:verify] == :verify_peer
      assert config[:sockopts][:cacerts] != nil
      assert config[:sockopts][:server_name_indication] == ~c"smtp.example.com"
    end

    test "an smtp relay with no credentials allows opportunistic STARTTLS" do
      # e.g. a local dev relay (MailHog:1025) or an internal plaintext
      # smarthost — nothing on the wire to protect, so mandatory STARTTLS
      # would only break it.
      creds = %{"provider" => "smtp", "host" => "localhost", "port" => 1025}

      assert {:ok, {Swoosh.Adapters.SMTP, config}} = Mailer.swoosh_config_for(creds)
      assert config[:port] == 1025
      assert config[:tls] == :if_available
      # still offered verified TLS if the relay happens to support it
      assert config[:tls_options][:verify] == :verify_peer
    end

    test "smtp credentials with an unparseable port are rejected" do
      creds = %{
        "provider" => "smtp",
        "host" => "smtp.example.com",
        "port" => "not-a-port",
        "username" => "user",
        "password" => "pw"
      }

      assert {:error, {:invalid_smtp_port, "not-a-port"}} = Mailer.swoosh_config_for(creds)
    end

    test "brevo_api credentials build a Brevo adapter config" do
      creds = %{"provider" => "brevo_api", "api_key" => "xkeysib-test"}

      assert {:ok, {Swoosh.Adapters.Brevo, config}} = Mailer.swoosh_config_for(creds)
      assert config[:api_key] == "xkeysib-test"
    end

    test "unknown provider is rejected" do
      assert {:error, {:unsupported_provider, "openrouter"}} =
               Mailer.swoosh_config_for(%{"provider" => "openrouter"})
    end

    test "missing provider key is rejected" do
      assert {:error, :unsupported_provider} = Mailer.swoosh_config_for(%{})
    end

    test "aws_ses credentials missing a required field are rejected, not raised" do
      creds = %{
        "provider" => "aws_ses",
        "access_key" => "AKIA_T",
        "secret_key" => "S",
        "aws_region" => nil
      }

      assert {:error, {:incomplete_credentials, ["aws_region"]}} =
               Mailer.swoosh_config_for(creds)
    end

    test "smtp credentials with a blank host are rejected, not raised" do
      # A stored connection's `status` can say "connected" while `host` was
      # blanked out after the last successful validation. Regression for a
      # bug where this reached Swoosh.Mailer.deliver/2 and raised an
      # ArgumentError with the full config — password included — inlined in
      # the (uncaught) exception message.
      creds = %{
        "provider" => "smtp",
        "host" => "",
        "port" => "587",
        "username" => "sub1@smtp-brevo.com",
        "password" => "not-a-real-smtp-secret"
      }

      assert {:error, {:incomplete_credentials, ["host"]}} = Mailer.swoosh_config_for(creds)
    end

    test "brevo_api credentials with a blank api_key are rejected, not raised" do
      assert {:error, {:incomplete_credentials, ["api_key"]}} =
               Mailer.swoosh_config_for(%{"provider" => "brevo_api", "api_key" => ""})
    end
  end

  describe "deliver_email/2 — recipient blocklist enforcement (E2)" do
    test "a blocklisted recipient is rejected without attempting delivery" do
      email =
        new()
        |> to("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
      refute_received {:email, _}
    end

    test "a normal recipient still delivers" do
      email =
        new() |> to("ok@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:ok, _} = Mailer.deliver_email(email)
      assert_received {:email, _}
    end

    test "a blocklisted address in cc is rejected (suppression cannot be bypassed)" do
      email =
        new()
        |> to("ok@example.com")
        |> Swoosh.Email.cc("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
      refute_received {:email, _}
    end

    test "a blocklisted address in bcc is rejected (suppression cannot be bypassed)" do
      email =
        new()
        |> to("ok@example.com")
        |> Swoosh.Email.bcc("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
      refute_received {:email, _}
    end
  end

  # Without the optional emails package there is no email log, and a send
  # used to leave no trace at all: an operator asking "did that reset email
  # go?" had nothing to read.
  describe "deliver_email/2 — the delivery log line" do
    # The suite runs at :warning; this line is :info.
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "a send is logged with its subject, the adapter, and the recipient masked" do
      email =
        new()
        |> to({"Max Example", "max.example@example.com"})
        |> Swoosh.Email.from("from@example.com")
        |> subject("Reset your password")
        |> text_body("https://example.com/reset/SECRET-TOKEN")

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:ok, _} = Mailer.deliver_email(email)
        end)

      assert log =~ "[PhoenixKit.Mailer] sent"
      assert log =~ "Reset your password"
      assert log =~ "Swoosh.Adapters.Test"
      assert log =~ "m***@example.com"
      # never the address itself, the name, or the body with its token
      refute log =~ "max.example@example.com"
      refute log =~ "SECRET-TOKEN"
    end

    test "a blocked recipient is not logged as sent" do
      email =
        new()
        |> to("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
        end)

      refute log =~ "[PhoenixKit.Mailer] sent"
    end

    test "mask_address/1 keeps the first letter and the domain, and echoes nothing else" do
      assert Mailer.mask_address("max@don.ee") == "m***@don.ee"
      assert Mailer.mask_address("a@b.c") == "a***@b.c"
      assert Mailer.mask_address("not an address") == "(unparseable address)"
      assert Mailer.mask_address("@nolocal.example") == "(unparseable address)"
      assert Mailer.mask_address(nil) == "(unparseable address)"
    end

    test "failed adapter responses mask nested addresses before the log is truncated" do
      original_api_client = Application.get_env(:swoosh, :api_client)
      Application.put_env(:swoosh, :api_client, FakeBrevoApiClient)
      on_exit(fn -> Application.put_env(:swoosh, :api_client, original_api_client) end)

      {:ok, %{uuid: uuid}} = Integrations.add_connection("brevo_api", "failure-log")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "xkeysib-test"})

      long_local = String.duplicate("private-recipient", 40)
      address = long_local <> "@example.com"
      error = %{"message" => "invalid recipient #{address}", "cc" => ["other.person@example.org"]}
      Process.put(:fake_brevo_response, {:ok, 400, [], Jason.encode!(error)})

      email =
        new()
        |> to(address)
        |> Swoosh.Email.from("from@example.com")
        |> subject("Delivery failure")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {400, ^error}} = Mailer.deliver_via_integration(email, uuid)
        end)

      assert log =~ "[PhoenixKit.Mailer] FAILED"
      assert log =~ "invalid recipient p***@example.com"
      assert log =~ "o***@example.org"
      refute log =~ "private-recipient"
      refute log =~ "other.person"

      # SMTP errors commonly carry an Erlang charlist instead of a binary.
      Process.put(
        :fake_brevo_response,
        {:error, {:permanent_failure, ~c"550 other.person@example.org rejected"}}
      )

      smtp_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:permanent_failure, _}} = Mailer.deliver_via_integration(email, uuid)
        end)

      assert smtp_log =~ "550 o***@example.org rejected"
      refute smtp_log =~ "other.person"

      # An adapter may return bytes which are not UTF-8; logging must not
      # replace the delivery error with a regex exception.
      Process.put(:fake_brevo_response, {:error, {502, <<255>>}})

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {502, <<255>>}} = Mailer.deliver_via_integration(email, uuid)
      end)
    end
  end

  describe "deliver_via_integration/3" do
    test "returns an error when the integration uuid doesn't resolve" do
      email =
        new() |> to("to@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:error, :deleted} =
               Mailer.deliver_via_integration(email, Ecto.UUID.generate())
    end

    test "a blocklisted recipient is rejected before the integration is even resolved (E2)" do
      email =
        new()
        |> to("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      # A bogus uuid would normally surface as {:error, :deleted} (see test
      # above) -- getting {:blocked, ...} instead proves the recipient check
      # runs first, ahead of Integrations.get_credentials/1.
      assert {:error, {:blocked, :blocklist}} =
               Mailer.deliver_via_integration(email, Ecto.UUID.generate())
    end

    test "returns an unsupported-provider error without attempting delivery" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "test")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "sk-test"})

      email =
        new() |> to("to@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:error, {:unsupported_provider, "openrouter"}} =
               Mailer.deliver_via_integration(email, uuid)
    end

    test "delivers via brevo_api, capturing the request and firing tracking hooks" do
      original_api_client = Application.get_env(:swoosh, :api_client)
      original_provider = Application.get_env(:phoenix_kit, :email_provider)

      Application.put_env(:swoosh, :api_client, FakeBrevoApiClient)
      Application.put_env(:phoenix_kit, :email_provider, TrackingProvider)

      on_exit(fn ->
        if original_api_client,
          do: Application.put_env(:swoosh, :api_client, original_api_client),
          else: Application.delete_env(:swoosh, :api_client)

        if original_provider,
          do: Application.put_env(:phoenix_kit, :email_provider, original_provider),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)

      {:ok, %{uuid: uuid}} = Integrations.add_connection("brevo_api", "test")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "xkeysib-test"})

      email =
        new()
        |> to("to@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hello via Brevo")
        |> text_body("Hi there")

      assert {:ok, %{id: "test-message-id"}} = Mailer.deliver_via_integration(email, uuid)

      assert_received {:fake_brevo_post, url, headers, _body}
      assert IO.iodata_to_binary(url) == "https://api.brevo.com/v3/smtp/email"
      assert Enum.any?(headers, fn {k, v} -> k == "Api-Key" and v == "xkeysib-test" end)

      assert_received {:intercept_before_send_called, intercept_opts}
      # provider is injected so the tracking interceptor attributes the send to
      # the integration's provider, not the host app's static mailer adapter.
      assert intercept_opts[:provider] == "brevo_api"
      assert_received {:handle_after_send_called, {:ok, %{id: "test-message-id"}}}
    end
  end

  describe "deliver_email/2 — default send integration routing" do
    test "no \"default_email_integration_uuid\" setting delivers via the built-in path unchanged" do
      email =
        new() |> to("ok@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:ok, _} = Mailer.deliver_email(email)
      assert_received {:email, _}
    end

    test "a blank \"default_email_integration_uuid\" setting is treated as absent" do
      {:ok, _} = Settings.update_setting("default_email_integration_uuid", "")

      email =
        new() |> to("ok@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:ok, _} = Mailer.deliver_email(email)
      assert_received {:email, _}
    end

    test "a setting pointing at a deleted/unknown integration falls back to the built-in path" do
      {:ok, _} =
        Settings.update_setting("default_email_integration_uuid", Ecto.UUID.generate())

      email =
        new() |> to("ok@example.com") |> Swoosh.Email.from("from@example.com") |> subject("Hi")

      assert {:ok, _} = Mailer.deliver_email(email)
      assert_received {:email, _}
    end

    test "a setting resolving to a configured connection routes through that integration, bypassing the built-in mailer" do
      original_api_client = Application.get_env(:swoosh, :api_client)
      original_provider = Application.get_env(:phoenix_kit, :email_provider)

      Application.put_env(:swoosh, :api_client, FakeBrevoApiClient)
      Application.put_env(:phoenix_kit, :email_provider, TrackingProvider)

      on_exit(fn ->
        if original_api_client,
          do: Application.put_env(:swoosh, :api_client, original_api_client),
          else: Application.delete_env(:swoosh, :api_client)

        if original_provider,
          do: Application.put_env(:phoenix_kit, :email_provider, original_provider),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)

      {:ok, %{uuid: uuid}} = Integrations.add_connection("brevo_api", "default sender")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "xkeysib-test"})
      {:ok, _} = Settings.update_setting("default_email_integration_uuid", uuid)

      email =
        new()
        |> to("to@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Routed via default integration")

      assert {:ok, %{id: "test-message-id"}} = Mailer.deliver_email(email)

      # Delivered via the Brevo integration's own HTTP path, not the
      # built-in Swoosh.Adapters.Test mailer configured for `PhoenixKit.Mailer`.
      assert_received {:fake_brevo_post, _url, _headers, _body}
      refute_received {:email, _}

      assert_received {:intercept_before_send_called, intercept_opts}
      assert intercept_opts[:provider] == "brevo_api"
    end

    test "recipient blocklist is still enforced when routed through a default integration" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("brevo_api", "default sender")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "xkeysib-test"})
      {:ok, _} = Settings.update_setting("default_email_integration_uuid", uuid)

      email =
        new()
        |> to("blocked@example.com")
        |> Swoosh.Email.from("from@example.com")
        |> subject("Hi")

      assert {:error, {:blocked, :blocklist}} = Mailer.deliver_email(email)
      refute_received {:email, _}
    end
  end

  describe "deliver_email/2 — provider queue seam" do
    setup do
      previous = Application.get_env(:phoenix_kit, :email_provider)
      Application.put_env(:phoenix_kit, :email_provider, PhoenixKit.MailerTest.QueuingProvider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :email_provider, previous),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)

      :ok
    end

    defp queue_test_email do
      new()
      |> to("queued@example.com")
      |> Swoosh.Email.from("from@example.com")
      |> subject("Hi")
    end

    test "a provider that queues short-circuits the send and reports the queue ref" do
      assert {:ok, %{id: "queue-ref-1", queued: true}} = Mailer.deliver_email(queue_test_email())

      assert_received {:intercept_before_send_called, _opts}
      assert_received {:maybe_enqueue_called, _opts}
      # Neither the adapter nor the after-send hook runs for a queued message.
      refute_received {:email, _}
      refute_received {:handle_after_send_called, _}
    end

    test "skip_queue sends on this process instead of offering the message" do
      assert {:ok, _metadata} = Mailer.deliver_email(queue_test_email(), skip_queue: true)

      assert_received {:intercept_before_send_called, _opts}
      refute_received {:maybe_enqueue_called, _opts}
      assert_received {:handle_after_send_called, {:ok, _}}
    end

    test "already_intercepted skips interception, so a worker's re-send is not tracked twice" do
      assert {:ok, _metadata} =
               Mailer.deliver_email(queue_test_email(),
                 skip_queue: true,
                 already_intercepted: true
               )

      refute_received {:intercept_before_send_called, _opts}
      refute_received {:maybe_enqueue_called, _opts}
      # The after-send hook still runs — that is what closes out the log row the
      # message already carries.
      assert_received {:handle_after_send_called, {:ok, _}}
    end

    test "already_intercepted alone still skips the queue, so a worker cannot loop" do
      # `already_intercepted: true` can only be a worker re-sending what it
      # dequeued. If it did not imply `skip_queue`, a worker that set one opt and
      # forgot the other would hand its own job straight back to the queue.
      assert {:ok, _metadata} =
               Mailer.deliver_email(queue_test_email(), already_intercepted: true)

      refute_received {:intercept_before_send_called, _opts}
      refute_received {:maybe_enqueue_called, _opts}
      assert_received {:handle_after_send_called, {:ok, _}}
    end
  end
end
