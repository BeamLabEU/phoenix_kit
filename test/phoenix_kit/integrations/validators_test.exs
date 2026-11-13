defmodule PhoenixKit.Integrations.ValidatorsTest do
  # async: false — one test swaps the global check deadline.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Integrations.Validators

  describe "aws_ses/1 refuses to guess" do
    test "a blank region is an error, not a silent probe of us-east-1" do
      # ExAws defaults a missing region to us-east-1, so without this guard the
      # check would pass against the wrong account/region while the send path
      # (which interpolates the region into the hostname) raises at send time.
      creds = %{"access_key" => "AKIA_T", "secret_key" => "S", "aws_region" => ""}
      assert {:error, message} = Validators.aws_ses(creds)
      assert message =~ "Region"
    end

    test "missing keys are reported without a network round trip" do
      assert {:error, _} = Validators.aws_ses(%{"aws_region" => "eu-central-1"})
    end
  end

  # AWS briefly answers a *correct* request with SignatureDoesNotMatch right after it
  # has rejected a bad signature from the same key — which is exactly what an operator
  # produces by pasting a wrong key, fixing it, and pressing Test again. Telling them
  # their good keys are invalid sends them off to reissue credentials that were never
  # the problem, so a verdict of "invalid" is confirmed before it is delivered.
  describe "the invalid-credentials verdict is confirmed before it is delivered" do
    test "a key that fails once and then succeeds is NOT called invalid" do
      requester = stub([{:invalid, "SignatureDoesNotMatch"}, :ok])

      assert :ok == Validators.request_send_quota("eu-central-1", %{}, requester)
    end

    test "a key that fails twice is called invalid" do
      requester = stub([{:invalid, "SignatureDoesNotMatch"}, {:invalid, "SignatureDoesNotMatch"}])

      assert {:error, message} = Validators.request_send_quota("eu-central-1", %{}, requester)
      assert message =~ "Invalid credentials"
    end

    test "a key that works is not retried" do
      requester = stub([:ok, {:invalid, "should never be asked for"}])

      assert :ok == Validators.request_send_quota("eu-central-1", %{}, requester)
    end

    test "a non-credential error is returned as-is, without a retry" do
      requester = stub([{:error, "AWS SES is busy"}, :ok])

      assert {:error, "AWS SES is busy"} =
               Validators.request_send_quota("eu-central-1", %{}, requester)
    end
  end

  describe "interpret_ses_error/1" do
    test "signature and token failures mean the credentials are wrong" do
      for code <- ~w(SignatureDoesNotMatch InvalidClientTokenId UnrecognizedClientException
                     InvalidAccessKeyId ExpiredToken TokenRefreshRequired) do
        assert {:invalid, ^code} = Validators.interpret_ses_error(aws_error(code))
      end
    end

    test "AccessDenied passes, but says what it could not verify" do
      # AWS's own least-privilege guidance grants only ses:SendEmail, which cannot call
      # GetSendQuota — so a red cross here would sit permanently on a correctly
      # configured integration and teach operators to ignore the check. But it is not
      # proof that the key can send: a signature valid for the WRONG AWS account lands
      # here too. So it passes with the caveat attached, and the caveat reaches the
      # operator rather than the log.
      # A standing fact about these credentials, so it is stored with them.
      assert {:ok, %{fact: note}} = Validators.interpret_ses_error(aws_error("AccessDenied"))
      assert note =~ "not authorised"
      assert note =~ "sending was not verified"

      assert {:ok, _} = Validators.interpret_ses_error(aws_error("AccessDeniedException"))
    end

    test "throttling says so instead of blaming the credentials" do
      assert {:error, message} = Validators.interpret_ses_error(aws_error("Throttling"))
      assert message =~ "busy"
    end

    test "an unrecognised code is surfaced verbatim rather than guessed at" do
      assert {:error, message} = Validators.interpret_ses_error(aws_error("MessageRejected"))
      assert message =~ "MessageRejected"
    end

    test "a body with no code, and anything that is not an HTTP error, are transport failures" do
      assert {:error, message} =
               Validators.interpret_ses_error({:http_error, 500, %{body: "<html>502</html>"}})

      assert message =~ "Could not reach"
      assert {:error, _} = Validators.interpret_ses_error(:timeout)
    end
  end

  describe "format_quota_note/1" do
    test "reports sent/max/rate from a real GetSendQuota body" do
      body = quota_body(max: "50000.0", sent: "127.0", rate: "14.0")

      assert note = Validators.format_quota_note(body)
      assert note =~ "127"
      assert note =~ "50,000"
      assert note =~ "14"
    end

    test "large numbers get thousand separators" do
      body = quota_body(max: "1000000.0", sent: "1234.0", rate: "50.0")

      note = Validators.format_quota_note(body)
      assert note =~ "1,234"
      assert note =~ "1,000,000"
    end

    # AWS's own convention: -1 means the account has no daily cap, rather than
    # a cap of negative-one messages.
    test "a Max24HourSend of -1 reads as unlimited, not -1" do
      body = quota_body(max: "-1.0", sent: "42.0", rate: "14.0")

      note = Validators.format_quota_note(body)
      assert note =~ "unlimited"
      refute note =~ "-1"
    end

    test "a body missing one of the three fields yields no note" do
      body = """
      <GetSendQuotaResponse><GetSendQuotaResult>
        <Max24HourSend>50000.0</Max24HourSend>
        <MaxSendRate>14.0</MaxSendRate>
      </GetSendQuotaResult></GetSendQuotaResponse>
      """

      assert Validators.format_quota_note(body) == nil
    end

    test "not a string at all yields no note rather than a crash" do
      assert Validators.format_quota_note(%{}) == nil
      assert Validators.format_quota_note(nil) == nil
    end

    defp quota_body(opts) do
      max = Keyword.fetch!(opts, :max)
      sent = Keyword.fetch!(opts, :sent)
      rate = Keyword.fetch!(opts, :rate)

      """
      <GetSendQuotaResponse xmlns="http://ses.amazonaws.com/doc/2010-12-01/">
        <GetSendQuotaResult>
          <Max24HourSend>#{max}</Max24HourSend>
          <MaxSendRate>#{rate}</MaxSendRate>
          <SentLast24Hours>#{sent}</SentLast24Hours>
        </GetSendQuotaResult>
        <ResponseMetadata><RequestId>abc</RequestId></ResponseMetadata>
      </GetSendQuotaResponse>
      """
    end
  end

  describe "format_credits_note/1" do
    test "a single subscription plan reports its type and credits" do
      body = %{
        "plan" => [%{"type" => "subscription", "creditsType" => "sendLimit", "credits" => 8500}]
      }

      assert note = Validators.format_credits_note(body)
      assert note =~ "subscription"
      assert note =~ "8,500 credits left"
    end

    test "multiple plan entries are all reported" do
      body = %{
        "plan" => [
          %{"type" => "subscription", "creditsType" => "sendLimit", "credits" => 8500},
          %{"type" => "payAsYouGo", "creditsType" => "sendLimit", "credits" => 120}
        ]
      }

      note = Validators.format_credits_note(body)
      assert note =~ "subscription"
      assert note =~ "8,500"
      assert note =~ "payAsYouGo"
      assert note =~ "120"
    end

    test "a plan entry with no credits key still names the plan type" do
      body = %{"plan" => [%{"type" => "free", "creditsType" => "sendLimit"}]}

      assert note = Validators.format_credits_note(body)
      assert note =~ "free"
      refute note =~ "credits left"
    end

    test "an endDate is surfaced as a reset date" do
      # Brevo's REAL wire shape: endDate is an ISO-8601 string, not a unix
      # integer (verified against the official reference and Postman
      # collection). The integer variant below is the belt-and-braces path.
      body = %{
        "plan" => [
          %{
            "type" => "subscription",
            "creditsType" => "sendLimit",
            "credits" => 8500,
            "endDate" => "2026-08-01T00:00:00.000Z"
          }
        ]
      }

      assert note = Validators.format_credits_note(body)
      assert note =~ "2026-08-01"
    end

    test "a unix-integer endDate is also accepted (defensive)" do
      # 2026-08-01T00:00:00Z
      body = %{
        "plan" => [
          %{
            "type" => "subscription",
            "credits" => 8500,
            "endDate" => 1_785_542_400
          }
        ]
      }

      assert note = Validators.format_credits_note(body)
      assert note =~ "2026-08-01"
    end

    test "an unparseable endDate is dropped, not crashed on" do
      body = %{
        "plan" => [
          %{"type" => "subscription", "credits" => 8500, "endDate" => "soon"}
        ]
      }

      assert note = Validators.format_credits_note(body)
      refute note =~ "resets"
    end

    test "no endDate means no reset date is claimed" do
      body = %{
        "plan" => [%{"type" => "subscription", "creditsType" => "sendLimit", "credits" => 8500}]
      }

      note = Validators.format_credits_note(body)
      refute note =~ "resets"
    end

    test "an empty or missing plan yields no note" do
      assert Validators.format_credits_note(%{"plan" => []}) == nil
      assert Validators.format_credits_note(%{}) == nil
      assert Validators.format_credits_note(%{"plan" => "not a list"}) == nil
    end
  end

  describe "smtp/1" do
    test "an unreachable relay is rejected" do
      # Nothing listens on port 1 — fails immediately, no outside network needed.
      creds = %{"host" => "127.0.0.1", "port" => "1", "username" => "u", "password" => "p"}
      assert {:error, _reason} = Validators.smtp(creds)
    end

    test "a malformed setting is reported instead of raising out of the LiveView" do
      # These translations sit OUTSIDE Probe.run and its rescue, so an unmatched
      # reason would surface as a CaseClauseError in the caller's callback.
      base = %{"host" => "127.0.0.1", "port" => "587", "username" => "u", "password" => "p"}

      assert {:error, security} = Validators.smtp(Map.put(base, "security", "tls-please"))
      assert security =~ "security"

      assert {:error, verify} = Validators.smtp(Map.put(base, "verify_cert", "sometimes"))
      assert verify =~ "verify_cert"

      assert {:error, auth} = Validators.smtp(Map.put(base, "auth", "maybe"))
      assert auth =~ "auth"

      assert {:error, timeout} = Validators.smtp(Map.put(base, "timeout", "soon"))
      assert timeout =~ "timeout" or timeout =~ "Timeout"

      assert {:error, ca} = Validators.smtp(Map.put(base, "ca_cert", "not a certificate"))
      assert ca =~ "PEM" or ca =~ "certificate"
    end

    test "an unparseable port is reported as such" do
      creds = %{"host" => "127.0.0.1", "port" => "nope", "username" => "u", "password" => "p"}
      assert {:error, message} = Validators.smtp(creds)
      assert message =~ "port"
    end

    test "a relay that advertises no AUTH verb passes" do
      # An internal smarthost that authenticates by IP. Sending works there, so a red
      # cross would be a lie about a working relay — and the operator could not avoid
      # it, since username/password are required fields. `auth: :always` is what makes
      # a *wrong password* fail closed, so the no-AUTH case is carved out rather than
      # weakening it.
      port = relay_without_auth()

      creds = %{"host" => "127.0.0.1", "port" => port, "username" => "", "password" => ""}

      assert :ok == Validators.smtp(creds)
    end

    test "a tarpit relay is cut off at the deadline instead of hanging the caller" do
      # gen_smtp bounds only the TCP connect; every read after it waits on a
      # hard-coded 20-minute timeout, in the CALLING process. Both call sites are
      # LiveView callbacks, so without an outer deadline one silent relay parks a
      # LiveView process for twenty minutes.
      port = silent_relay()

      Application.put_env(:phoenix_kit, :integration_check_deadline, 300)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :integration_check_deadline) end)

      creds = %{"host" => "127.0.0.1", "port" => port, "username" => "u", "password" => "p"}

      {elapsed_us, result} = :timer.tc(fn -> Validators.smtp(creds) end)

      assert {:error, message} = result
      assert message =~ "did not respond"
      # Comfortably under gen_smtp's own 20-minute read timeout.
      assert elapsed_us < 5_000_000
    end
  end

  describe "smtp/2 with the personal SMTP policy on" do
    setup do
      Application.put_env(:phoenix_kit, :personal_smtp_policy, :restricted)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :personal_smtp_policy) end)
    end

    defp relay_creds(port),
      do: %{"host" => "127.0.0.1", "port" => port, "username" => "", "password" => ""}

    test "a personal connection to a local relay is refused before any socket opens" do
      port = relay_without_auth(self())

      assert {:error, _message} = Validators.smtp(relay_creds(port), owner: {:user, "u-1"})
      refute_receive :relay_accepted, 200
    end

    test "a personal connection to an internal address on a mail port is refused" do
      assert {:error, message} = Validators.smtp(relay_creds(587), owner: {:user, "u-1"})
      assert message =~ "public address"
    end

    test "a personal connection on a non-mail port is refused" do
      creds = %{"host" => "8.8.8.8", "port" => "5432", "username" => "u", "password" => "p"}

      assert {:error, message} = Validators.smtp(creds, owner: {:user, "u-1"})
      assert message =~ "25, 465, 587"
    end

    test "a personal connection to an internal name is refused" do
      creds = %{"host" => "pgbouncer", "port" => "587", "username" => "u", "password" => "p"}

      assert {:error, message} = Validators.smtp(creds, owner: {:user, "u-1"})
      assert message =~ "public address"
    end

    test "no owner means the strict policy" do
      port = relay_without_auth(self())

      assert {:error, _} = Validators.smtp(relay_creds(port))
      refute_receive :relay_accepted, 200
    end

    test "a system connection is not affected" do
      port = relay_without_auth(self())

      assert :ok == Validators.smtp(relay_creds(port), owner: :system)
      assert_receive :relay_accepted
    end
  end

  describe "smtp/2 with the personal SMTP policy off (the default)" do
    test "a personal connection still reaches an internal relay, as before" do
      port = relay_without_auth(self())
      creds = %{"host" => "127.0.0.1", "port" => port, "username" => "", "password" => ""}

      assert :ok == Validators.smtp(creds, owner: {:user, "u-1"})
      assert_receive :relay_accepted
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Answers the given results in order. A plain closure beats a mocking library here:
  # the thing under test is "how many times is AWS asked, and what is done with each
  # answer", which is exactly what a queue makes visible.

  describe "amazon_bedrock/1 refuses to guess" do
    test "missing key and missing region are reported without a network round trip" do
      assert {:error, _} = Validators.amazon_bedrock(%{"aws_region" => "eu-central-1"})
      assert {:error, message} = Validators.amazon_bedrock(%{"api_key" => "ABSK_T"})
      assert message =~ "Region"
    end

    test "a malformed region is rejected before it becomes a hostname" do
      for bad <- ["eu central", "EU-CENTRAL-1", "bedrock.evil.example/", "eu-central-"] do
        creds = %{"api_key" => "ABSK_T", "aws_region" => bad}
        assert {:error, message} = Validators.amazon_bedrock(creds)
        assert message =~ "region format"
      end
    end

    test "real region shapes pass the format guard, including 4-letter sovereign prefixes" do
      for good <- [
            "us-east-1",
            "ap-southeast-3",
            "il-central-1",
            "us-gov-west-1",
            "eusc-de-east-1"
          ] do
        assert Validators.valid_aws_region?(good), good
      end

      for bad <- ["", "eu central", "EU-CENTRAL-1", "bedrock.evil.example/", "eu-central-", nil] do
        refute Validators.valid_aws_region?(bad), inspect(bad)
      end
    end
  end

  # The identity and the granted APIs are FACTS — they stay true until the
  # credentials change — so they are what gets stored. The send quota is a
  # reading and travels separately; see the note type on
  # `PhoenixKit.Integrations.Probe`.
  describe "aws_note/2 assembles the standing fact additively" do
    test "lists only GRANTED management APIs — a send-only key shows no denied dashes" do
      perms = %{
        ses: %{"ListConfigurationSets" => :denied},
        sqs: %{"ListQueues" => :denied},
        sns: %{"ListTopics" => :denied}
      }

      assert Validators.aws_note("Account 1", perms) == "Account 1"
    end

    test "grants surface by service name" do
      perms = %{
        ses: %{"ListConfigurationSets" => :granted},
        sqs: %{"ListQueues" => :granted},
        sns: %{"ListTopics" => :denied}
      }

      fact = Validators.aws_note("Account 1", perms)
      assert fact =~ "Account 1"
      assert fact =~ "SES, SQS"
      refute fact =~ "SNS"
    end

    test "nothing to say means nil, so the verdict stays a bare :ok" do
      assert Validators.aws_note(nil, nil) == nil
    end

    test "a missing permissions sweep keeps the identity" do
      assert Validators.aws_note("Account 1", nil) == "Account 1"
    end

    test "a partial permissions map is read, not crashed on" do
      assert Validators.aws_note(nil, %{ses: %{"ListConfigurationSets" => :granted}}) =~ "SES"
    end
  end

  describe "bedrock_host/1 follows the partition" do
    test "the China partition gets its own suffix" do
      assert Validators.bedrock_host("cn-north-1") =~ ".amazonaws.com.cn"
      assert Validators.bedrock_host("eu-central-1") =~ ".amazonaws.com"
      refute Validators.bedrock_host("eu-central-1") =~ ".cn"
    end
  end

  describe "object_storage/1 refuses to guess" do
    test "missing keys are reported without a network round trip" do
      assert {:error, _} = Validators.object_storage(%{})
      assert {:error, _} = Validators.object_storage(%{"access_key" => "AKIA_T"})
      assert {:error, _} = Validators.object_storage(%{"secret_key" => "S"})
    end

    test "region and endpoint stay optional -- only credentials gate the network call" do
      # No region: still attempts a real request (the default region is filled
      # in behind the scenes) rather than being rejected up front.
      creds = %{"access_key" => "AKIA_T", "secret_key" => "S", "endpoint" => "127.0.0.1"}
      assert {:error, message} = Validators.object_storage(creds, owner: :system)
      assert message =~ "reach"
    end
  end

  describe "object_storage/2 refuses an endpoint the server must not connect to" do
    @creds %{"access_key" => "AKIA_T", "secret_key" => "S"}

    test "a personal connection may not use a local or private address, or plain http" do
      for endpoint <- ["127.0.0.1", "https://10.0.0.5", "http://8.8.8.8", "https://[::1]"] do
        creds = Map.put(@creds, "endpoint", endpoint)

        assert {:error, message} = Validators.object_storage(creds, owner: {:user, "u"})
        refute message =~ "reach", endpoint
        assert message =~ "endpoint", endpoint
      end
    end

    test "no owner given is read as personal, the strict default" do
      creds = Map.put(@creds, "endpoint", "127.0.0.1")

      assert {:error, message} = Validators.object_storage(creds)
      assert message =~ "local, private or metadata"
    end

    test "a system connection may use a local endpoint, but nobody a metadata one" do
      assert {:error, message} =
               Validators.object_storage(Map.put(@creds, "endpoint", "127.0.0.1"),
                 owner: :system
               )

      assert message =~ "reach"

      for owner <- [:system, {:user, "u"}] do
        assert {:error, message} =
                 Validators.object_storage(Map.put(@creds, "endpoint", "169.254.169.254"),
                   owner: owner
                 )

        assert message =~ "local, private or metadata", inspect(owner)
      end
    end

    test "an unusable endpoint is named, not reported as unreachable" do
      assert {:error, message} =
               Validators.object_storage(Map.put(@creds, "endpoint", "ftp://nope"),
                 owner: :system
               )

      assert message =~ "not a usable"
    end
  end

  describe "object_storage/1 really connects" do
    test "an unreachable endpoint is rejected, distinctly from bad credentials" do
      # Nothing listens on 127.0.0.1:443 in the test environment -- fails
      # immediately, no outside network needed (mirrors the SMTP relay test).
      creds = %{"access_key" => "AKIA_T", "secret_key" => "S", "endpoint" => "127.0.0.1"}

      assert {:error, message} = Validators.object_storage(creds, owner: :system)
      assert message =~ "reach"
      refute message =~ "credentials"
      refute message =~ "Incomplete"
    end

    test "an endpoint pasted with its scheme still reaches the network instead of crashing" do
      # Before the endpoint normalization fix, a scheme-prefixed endpoint (the
      # form R2's dashboard hands out) made ExAws raise a MatchError building
      # the request -- silently swallowed into the same "could not reach"
      # message. object_storage_config/1's own tests below confirm the host
      # is actually parsed correctly; this is the end-to-end smoke test that
      # nothing raises uncaught along the way.
      creds = %{"access_key" => "AKIA_T", "secret_key" => "S", "endpoint" => "https://127.0.0.1/"}

      assert {:error, message} = Validators.object_storage(creds, owner: :system)
      assert message =~ "reach"
    end
  end

  describe "object_storage_config/1 always resolves a real host" do
    test "a region ExAws's own resolver silently fails on still gets a usable host" do
      # ExAws.Config.Defaults.host(:s3, "il-central-1") returns nil -- its
      # partition-prefix regex has no entry for newer regions. Confirmed live
      # against this dependency version; see the inline comment in
      # object_storage_config/1 for the full trap.
      config =
        Validators.object_storage_config(%{
          "access_key" => "AKIA_T",
          "secret_key" => "S",
          "region" => "il-central-1"
        })

      assert Keyword.get(config, :host) == "s3.il-central-1.amazonaws.com"
    end

    test "the China partition still gets its .cn suffix" do
      # Unlike il-central-1/mx-central-1, ExAws's own resolver gets THIS
      # partition right (confirmed:
      # ExAws.Config.Defaults.host(:s3, "cn-north-1") ==
      # "s3.cn-north-1.amazonaws.com.cn") -- a naive always-hardcode-.com
      # fix would regress a case ExAws already handled correctly.
      config =
        Validators.object_storage_config(%{
          "access_key" => "AKIA_T",
          "secret_key" => "S",
          "region" => "cn-north-1"
        })

      assert Keyword.get(config, :host) == "s3.cn-north-1.amazonaws.com.cn"
    end

    test "no region falls back to us-east-1, both as the signing region and the host" do
      config = Validators.object_storage_config(%{"access_key" => "AKIA_T", "secret_key" => "S"})

      assert Keyword.get(config, :region) == "us-east-1"
      assert Keyword.get(config, :host) == "s3.us-east-1.amazonaws.com"
    end

    test "a scheme-prefixed endpoint, trailing slash included, is normalized to a bare host" do
      config =
        Validators.object_storage_config(%{
          "access_key" => "AKIA_T",
          "secret_key" => "S",
          "endpoint" => "https://abc123.r2.cloudflarestorage.com/"
        })

      assert Keyword.get(config, :host) == "abc123.r2.cloudflarestorage.com"
    end

    test "a bare endpoint is used as-is" do
      config =
        Validators.object_storage_config(%{
          "access_key" => "AKIA_T",
          "secret_key" => "S",
          "endpoint" => "s3.us-west-002.backblazeb2.com"
        })

      assert Keyword.get(config, :host) == "s3.us-west-002.backblazeb2.com"
    end
  end

  describe "request_list_buckets/2 confirms the invalid-credentials verdict before delivering it" do
    # AWS briefly answers a *correct* request with SignatureDoesNotMatch right
    # after rejecting a bad signature from the same key, and a freshly created
    # access key answers InvalidAccessKeyId until it propagates -- both are the
    # create-key/paste/Test flow a first-run operator produces. A verdict of
    # "invalid" is confirmed before it is delivered, mirroring
    # request_send_quota/3's SES confirm-retry.
    test "a key that fails once and then succeeds is NOT called invalid" do
      requester = stub1([{:invalid, "SignatureDoesNotMatch"}, :ok])

      assert :ok == Validators.request_list_buckets(%{}, requester)
    end

    test "a key that fails twice is called invalid" do
      requester =
        stub1([{:invalid, "SignatureDoesNotMatch"}, {:invalid, "SignatureDoesNotMatch"}])

      assert {:error, message} = Validators.request_list_buckets(%{}, requester)
      assert message =~ "Invalid credentials"
    end

    test "a key that works is not retried" do
      requester = stub1([:ok, {:invalid, "should never be asked for"}])

      assert :ok == Validators.request_list_buckets(%{}, requester)
    end

    test "a non-credential error is returned as-is, without a retry" do
      requester = stub1([{:error, "Storage service is busy"}, :ok])

      assert {:error, "Storage service is busy"} =
               Validators.request_list_buckets(%{}, requester)
    end

    test "a pass with a note is handed through unchanged, without a retry" do
      note = %{fact: "bucket access was not verified"}
      requester = stub1([{:ok, note}, {:invalid, "should never be asked for"}])

      assert {:ok, ^note} = Validators.request_list_buckets(%{}, requester)
    end

    test "a rejection that gives way to a pass with a note returns the note" do
      note = %{fact: "bucket access was not verified"}
      requester = stub1([{:invalid, "SignatureDoesNotMatch"}, {:ok, note}])

      assert {:ok, ^note} = Validators.request_list_buckets(%{}, requester)
    end
  end

  describe "interpret_object_storage_error/1" do
    test "InvalidAccessKeyId and SignatureDoesNotMatch are confirmed before being called invalid" do
      for code <- ~w(InvalidAccessKeyId SignatureDoesNotMatch) do
        assert {:invalid, ^code} = Validators.interpret_object_storage_error(s3_error(code))
      end
    end

    test "AccessDenied passes with a note that bucket access was not verified" do
      # A Cloudflare R2 token scoped to specific objects cannot call
      # ListBuckets, and it is the key a site should hold -- so this must
      # neither read as "wrong keys" nor fail the check. AccessDenied also
      # comes back for an IAM user with no S3 rights, so the note states only
      # what was observed. A standing fact about these credentials, so it is
      # stored with them.
      assert {:ok, %{fact: note}} =
               Validators.interpret_object_storage_error(s3_error("AccessDenied"))

      assert note =~ "not allowed to list buckets"
      assert note =~ "not verified"
      refute note =~ "Invalid credentials"
    end

    test "SlowDown, InternalError and ServiceUnavailable say to retry, not that credentials are wrong" do
      for code <- ~w(SlowDown InternalError ServiceUnavailable) do
        assert {:error, message} = Validators.interpret_object_storage_error(s3_error(code))
        assert message =~ "busy"
        refute message =~ "Invalid credentials"
      end
    end

    test "RequestTimeTooSkewed is a clock problem, not something retrying fixes -- surfaced verbatim" do
      assert {:error, message} =
               Validators.interpret_object_storage_error(s3_error("RequestTimeTooSkewed"))

      assert message =~ "RequestTimeTooSkewed"
      refute message =~ "busy"
    end

    test "an unrecognised code is surfaced verbatim rather than guessed at" do
      assert {:error, message} =
               Validators.interpret_object_storage_error(s3_error("MalformedXML"))

      assert message =~ "MalformedXML"
    end

    test "a body with no code, and anything that is not an HTTP error, are transport failures" do
      assert {:error, message} =
               Validators.interpret_object_storage_error(
                 {:http_error, 500, %{body: "<html>502</html>"}}
               )

      assert message =~ "reach"
      assert {:error, message} = Validators.interpret_object_storage_error(:timeout)
      assert message =~ "reach"
    end
  end

  # Response bodies below are the shapes DataForSEO and SerpApi returned to
  # real requests (2026-09-17), trimmed to the fields that matter and with the
  # account details replaced.
  @dataforseo_ok %{
    "status_code" => 20_000,
    "status_message" => "Ok.",
    "cost" => 0,
    "tasks_count" => 1,
    "tasks_error" => 0,
    "tasks" => [
      %{
        "status_code" => 20_000,
        "status_message" => "Ok.",
        "path" => ["v3", "appendix", "user_data"],
        "result" => [
          %{
            "login" => "you@example.com",
            "timezone" => "UTC",
            "money" => %{"total" => 1, "balance" => 1, "limits" => %{}, "statistics" => %{}},
            "price" => %{},
            "rates" => %{},
            "backlinks_subscription_expiry_date" => nil,
            "llm_mentions_subscription_expiry_date" => nil
          }
        ]
      }
    ]
  }

  @dataforseo_unauthorized %{
    "status_code" => 40_100,
    "status_message" =>
      "You are not authorized to access this resource. See your login details here: https://app.dataforseo.com/api-access .",
    "cost" => 0,
    "tasks_count" => 0,
    "tasks_error" => 0,
    "tasks" => []
  }

  # SerpApi's own documented example carries the account's API key too.
  @serpapi_ok %{
    "account_id" => "5ac54d6adefb2f1dba1663f5",
    "api_key" => "serp-key",
    "account_email" => "you@example.com",
    "account_status" => "Active",
    "plan_name" => "Free Plan",
    "searches_per_month" => 250,
    "this_month_usage" => 12,
    "total_searches_left" => 238
  }

  @serpapi_invalid_key %{
    "error" => "Invalid API key. Your API key should be here: https://serpapi.com/manage-api-key"
  }

  describe "dataforseo/2 refuses to guess" do
    test "a missing login or password is reported without a network round trip" do
      for creds <- [
            %{},
            %{"login" => "you@example.com"},
            %{"password" => "secret"},
            %{"login" => "  ", "password" => "secret"},
            %{"login" => "you@example.com", "password" => ""}
          ] do
        assert {:error, "No credentials configured"} =
                 Validators.dataforseo(creds, plug: &flunk_request/1),
               inspect(creds)
      end
    end
  end

  describe "dataforseo/2 asks the account endpoint" do
    test "with HTTP Basic credentials, and reports the balance" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.host == "api.dataforseo.com"
        assert conn.request_path == "/v3/appendix/user_data"

        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Basic " <> Base.encode64("you@example.com:api-secret")]

        Req.Test.json(conn, @dataforseo_ok)
      end

      creds = %{"login" => "you@example.com", "password" => "api-secret"}
      assert {:ok, %{reading: "Balance: $1.00"}} = Validators.dataforseo(creds, plug: plug)
    end

    test "a wrong password is an error that points at the API password" do
      plug = fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(@dataforseo_unauthorized)
      end

      creds = %{"login" => "you@example.com", "password" => "account-password"}
      assert {:error, message} = Validators.dataforseo(creds, plug: plug)
      assert message =~ "Invalid API login or password"
      assert message =~ "API Access"
    end

    test "an unreachable API is reported as such" do
      plug = &Req.Test.transport_error(&1, :econnrefused)
      creds = %{"login" => "you@example.com", "password" => "api-secret"}

      assert {:error, "Could not reach DataForSEO"} = Validators.dataforseo(creds, plug: plug)
    end

    test "an answer that cannot be read is not called unreachable, and its body is not logged" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          ~s({"status_code":20000,"tasks":[{"result":[{"login":"you@exa)
        )
      end

      creds = %{"login" => "you@example.com", "password" => "api-secret"}

      log =
        capture_log(fn ->
          assert {:error, "Unexpected answer from DataForSEO"} =
                   Validators.dataforseo(creds, plug: plug)
        end)

      refute log =~ "you@exa"
      refute log =~ "api-secret"
    end

    test "a redirect is not followed" do
      {plug, calls} =
        counting(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://app.dataforseo.com/login")
          |> Plug.Conn.send_resp(301, "")
        end)

      creds = %{"login" => "you@example.com", "password" => "api-secret"}
      assert {:error, "DataForSEO error 301"} = Validators.dataforseo(creds, plug: plug)
      assert calls.() == 1
    end

    test "asks once: no retry on a failed answer or a dropped connection" do
      creds = %{"login" => "you@example.com", "password" => "api-secret"}

      for {respond, expected} <- [
            {&Plug.Conn.send_resp(&1, 503, "busy"), "DataForSEO error 503"},
            {&Req.Test.transport_error(&1, :timeout), "Could not reach DataForSEO"}
          ] do
        {plug, calls} = counting(respond)
        assert {:error, ^expected} = Validators.dataforseo(creds, plug: plug)
        assert calls.() == 1, expected
      end
    end
  end

  describe "interpret_dataforseo/2" do
    test "a float balance is shown to the cent" do
      body =
        put_in(@dataforseo_ok, ["tasks", Access.at(0), "result", Access.at(0), "money"], %{
          "balance" => 12.3456
        })

      assert {:ok, %{reading: "Balance: $12.35"}} = Validators.interpret_dataforseo(200, body)
    end

    test "an empty balance still connects, and says what it means" do
      body =
        put_in(@dataforseo_ok, ["tasks", Access.at(0), "result", Access.at(0), "money"], %{
          "balance" => 0
        })

      assert {:ok, %{reading: note}} = Validators.interpret_dataforseo(200, body)
      assert note =~ "$0.00"
      assert note =~ "add funds"
    end

    test "the warning follows the amount shown, not the raw number" do
      for {balance, shown} <- [{0.004, "$0.00"}, {-0.004, "$0.00"}, {-5, "$-5.00"}] do
        body = with_balance(balance)
        assert {:ok, %{reading: note}} = Validators.interpret_dataforseo(200, body)
        assert note =~ shown, "#{balance}: #{note}"
        assert note =~ "add funds", "#{balance}: #{note}"
      end

      assert {:ok, %{reading: "Balance: $0.01"}} =
               Validators.interpret_dataforseo(200, with_balance(0.005))
    end

    test "a balance no float can hold is shown, not crashed on" do
      # `:erlang.float_to_binary/2` refuses 1.0e300, and an integer this large
      # cannot become a float at all.
      assert {:ok, %{reading: "Balance: $" <> _}} =
               Validators.interpret_dataforseo(200, with_balance(1.0e300))

      assert {:ok, %{reading: "Balance: $1" <> rest}} =
               Validators.interpret_dataforseo(200, with_balance(Integer.pow(10, 400)))

      assert rest == String.duplicate("0", 400) <> ".00"
    end

    test "balance formatting preserves every digit and the caller's decimal context" do
      context = %{Decimal.Context.get() | precision: 4, flags: [:inexact]}

      Decimal.Context.with(context, fn ->
        assert {:ok, %{reading: "Balance: $12345678901234567890.00"}} =
                 Validators.interpret_dataforseo(200, with_balance(12_345_678_901_234_567_890))

        assert Decimal.Context.get() == context
      end)
    end

    test "a success with no account in it is still a success" do
      assert :ok = Validators.interpret_dataforseo(200, Map.put(@dataforseo_ok, "tasks", []))

      no_money =
        put_in(@dataforseo_ok, ["tasks", Access.at(0), "result"], [%{"login" => "x"}])

      assert :ok = Validators.interpret_dataforseo(200, no_money)
    end

    test "a failed task is an error even when the request succeeded" do
      body =
        @dataforseo_ok
        |> put_in(["tasks", Access.at(0), "status_code"], 40_204)
        |> put_in(["tasks", Access.at(0), "status_message"], "Access denied.")

      assert {:error, "DataForSEO error 40204: Access denied."} =
               Validators.interpret_dataforseo(200, body)
    end

    test "the account problems an operator can fix get their own message" do
      for {code, expected} <- [
            {40_104, "not verified"},
            {40_200, "needs funds"},
            {40_210, "needs funds"},
            {40_201, "paused"},
            {40_202, "Too many requests"},
            {40_203, "daily spending limit"},
            {40_209, "at once"}
          ] do
        body = %{@dataforseo_unauthorized | "status_code" => code, "status_message" => "x"}
        assert {:error, message} = Validators.interpret_dataforseo(402, body)
        assert message =~ expected, "#{code}: #{message}"
      end
    end

    test "an unknown code carries DataForSEO's own message, cut to length" do
      body = %{@dataforseo_unauthorized | "status_code" => 50_000, "status_message" => "Boom."}

      assert {:error, "DataForSEO error 50000: Boom."} =
               Validators.interpret_dataforseo(500, body)

      long = %{body | "status_message" => String.duplicate("a", 1_000)}
      assert {:error, message} = Validators.interpret_dataforseo(500, long)
      assert String.length(message) < 250
    end

    test "answers without a DataForSEO body fall back to the HTTP status" do
      assert {:error, message} = Validators.interpret_dataforseo(401, "Unauthorized")
      assert message =~ "Invalid API login or password"

      assert {:error, "DataForSEO error 502"} =
               Validators.interpret_dataforseo(502, "<html>Bad gateway</html>")

      assert {:error, "Unexpected answer from DataForSEO"} =
               Validators.interpret_dataforseo(200, "<html>maintenance</html>")
    end

    test "a success code on a failed HTTP response is not a success" do
      assert {:error, "DataForSEO error 500"} =
               Validators.interpret_dataforseo(500, @dataforseo_ok)
    end
  end

  describe "brevo_api/2" do
    # what Brevo answers /v3/account (status, body)
    @brevo_ok %{
      "email" => "ops@example.com",
      "plan" => [%{"type" => "free", "credits" => 300, "creditsType" => "sendLimit"}]
    }
    @brevo_bad_key %{"code" => "unauthorized", "message" => "Key not found"}
    @brevo_ip %{
      "code" => "unauthorized",
      "message" =>
        "We have detected you are using an unrecognised IP address 203.0.113.7. If you performed this action make sure to add the new IP address in this link: https://app.brevo.com/security/authorised_ips"
    }

    test "a missing key is reported without a network round trip" do
      for creds <- [%{}, %{"api_key" => ""}, %{"api_key" => "   "}] do
        assert {:error, "No credentials configured"} =
                 Validators.brevo_api(creds, plug: &flunk_request/1),
               inspect(creds)
      end
    end

    test "an SMTP key is named as one, without a network round trip" do
      for key <- ["xsmtpsib-0123abcd-XyZ", "  xsmtpsib-0123abcd-XyZ"] do
        assert {:error, message} =
                 Validators.brevo_api(%{"api_key" => key}, plug: &flunk_request/1)

        assert message =~ "SMTP key"
        assert message =~ "xkeysib-"
      end
    end

    # The request would run inside Probe, which swallows a crash (flunk
    # included) into a generic error — so assert the exact verdict, which only
    # the no-request branch gives.
    test "a key that is not a string is refused without a network round trip" do
      for key <- [12_345, %{"k" => "v"}, ["xkeysib-a"]] do
        assert {:error, "Invalid credentials"} =
                 Validators.brevo_api(%{"api_key" => key}, plug: &flunk_request/1),
               inspect(key)
      end
    end

    test "asks /v3/account with the key in the api-key header, and reports the credits" do
      plug = fn conn ->
        assert conn.method == "GET"
        assert conn.host == "api.brevo.com"
        assert conn.request_path == "/v3/account"
        assert Plug.Conn.get_req_header(conn, "api-key") == ["xkeysib-good"]
        Req.Test.json(conn, @brevo_ok)
      end

      assert {:ok, %{reading: reading}} =
               Validators.brevo_api(%{"api_key" => "xkeysib-good"}, plug: plug)

      assert reading =~ "300"
    end

    test "a refused key says what Brevo said" do
      plug = fn conn -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(@brevo_bad_key) end

      assert {:error, message} = Validators.brevo_api(%{"api_key" => "xkeysib-wrong"}, plug: plug)
      assert message =~ "Invalid credentials"
      assert message =~ "Key not found"
    end

    test "a good key from an IP outside Authorised IPs is not called invalid" do
      assert {:error, message} = Validators.interpret_brevo(401, @brevo_ip)
      assert message =~ "Authorised IPs"
      refute message =~ "Invalid credentials"
    end

    test "other answers" do
      assert {:error, "Invalid credentials"} = Validators.interpret_brevo(401, "")
      assert {:error, "Invalid credentials"} = Validators.interpret_brevo(401, %{"message" => ""})
      assert {:error, "Access denied"} = Validators.interpret_brevo(403, %{})

      assert {:error, "Brevo error 500: busy"} =
               Validators.interpret_brevo(500, %{"message" => "busy"})

      assert {:error, "Brevo error 502"} = Validators.interpret_brevo(502, "<html>")
      assert {:error, "Unexpected answer from Brevo"} = Validators.interpret_brevo(200, "<html>")
    end
  end

  describe "serpapi/2 refuses to guess" do
    test "a missing key is reported without a network round trip" do
      for creds <- [%{}, %{"api_key" => ""}, %{"api_key" => "   "}] do
        assert {:error, "No credentials configured"} =
                 Validators.serpapi(creds, plug: &flunk_request/1),
               inspect(creds)
      end
    end
  end

  describe "serpapi/2 asks the Account API" do
    test "with the key as a query parameter, and reports the searches left" do
      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.method == "GET"
        assert conn.host == "serpapi.com"
        assert conn.request_path == "/account.json"
        assert conn.query_params == %{"api_key" => "serp-key"}
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        Req.Test.json(conn, @serpapi_ok)
      end

      assert {:ok, %{fact: "Free Plan", reading: "Searches left: 238"}} =
               Validators.serpapi(%{"api_key" => "serp-key"}, plug: plug)
    end

    test "a bad key is an error" do
      plug = fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(@serpapi_invalid_key)
      end

      assert {:error, "Invalid API key"} =
               Validators.serpapi(%{"api_key" => "wrong"}, plug: plug)
    end

    test "an unreachable API is reported as such" do
      plug = &Req.Test.transport_error(&1, :timeout)

      assert {:error, "Could not reach SerpApi"} =
               Validators.serpapi(%{"api_key" => "serp-key"}, plug: plug)
    end

    test "an answer that cannot be read is not called unreachable, and the key stays out of the log" do
      # A cut-off account body: SerpApi's carries the API key.
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"account_id":"x","api_key":"serp-key","plan_name":"Fr))
      end

      log =
        capture_log(fn ->
          assert {:error, "Unexpected answer from SerpApi"} =
                   Validators.serpapi(%{"api_key" => "serp-key"}, plug: plug)
        end)

      refute log =~ "serp-key"
    end

    test "a redirect is not followed" do
      # A same-host redirect would drop `params` — the key with it — and Req
      # logs every Location it follows.
      {plug, calls} =
        counting(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "/account.json?api_key=serp-key")
          |> Plug.Conn.send_resp(302, "")
        end)

      assert {:error, "SerpApi error 302"} =
               Validators.serpapi(%{"api_key" => "serp-key"}, plug: plug)

      assert calls.() == 1
    end

    test "a failure reason carrying response bytes is logged by its tag only" do
      plug = &Req.Test.transport_error(&1, {:bad_alpn_protocol, "SERP-SECRET-bytes"})

      log =
        capture_log(fn ->
          assert {:error, "Could not reach SerpApi"} =
                   Validators.serpapi(%{"api_key" => "serp-key"}, plug: plug)
        end)

      assert log =~ ":bad_alpn_protocol"
      refute log =~ "SERP-SECRET"
    end

    test "asks once: no retry on a failed answer or a dropped connection" do
      for {respond, expected} <- [
            {&Plug.Conn.send_resp(&1, 503, "busy"), "SerpApi error 503"},
            {&Req.Test.transport_error(&1, :timeout), "Could not reach SerpApi"}
          ] do
        {plug, calls} = counting(respond)
        assert {:error, ^expected} = Validators.serpapi(%{"api_key" => "serp-key"}, plug: plug)
        assert calls.() == 1, expected
      end
    end
  end

  describe "interpret_serpapi/2" do
    test "a used-up plan still connects, and says so" do
      body = %{@serpapi_ok | "this_month_usage" => 250, "total_searches_left" => 0}

      assert {:ok, %{fact: "Free Plan", reading: "No searches left"}} =
               Validators.interpret_serpapi(200, body)
    end

    test "large counts are grouped" do
      body = %{@serpapi_ok | "plan_name" => "Big Data Plan", "total_searches_left" => 29_500}

      assert {:ok, %{fact: "Big Data Plan", reading: "Searches left: 29,500"}} =
               Validators.interpret_serpapi(200, body)
    end

    test "an account without plan details is still a success" do
      assert :ok = Validators.interpret_serpapi(200, %{"account_email" => "you@example.com"})
    end

    test "the searches left are reported with or without a plan name" do
      assert {:ok, %{reading: "No searches left"}} =
               Validators.interpret_serpapi(200, %{"total_searches_left" => 0})

      assert {:ok, %{reading: "Searches left: 1,500"}} =
               Validators.interpret_serpapi(200, %{"total_searches_left" => 1_500})

      # A blank plan name is no plan name, so there is no fact to keep.
      assert {:ok, %{reading: "Searches left: 3"} = note} =
               Validators.interpret_serpapi(200, %{"plan_name" => "", "total_searches_left" => 3})

      refute Map.has_key?(note, :fact)

      # A plan with no count is the plan name alone, and it is a fact: it
      # stays true, so it is worth keeping on the connection.
      assert {:ok, %{fact: "Free Plan"} = note} =
               Validators.interpret_serpapi(200, %{"plan_name" => "Free Plan"})

      refute Map.has_key?(note, :reading)

      assert :ok = Validators.interpret_serpapi(200, %{"plan_name" => ""})
    end

    test "an account that is not active says so first" do
      body = %{@serpapi_ok | "account_status" => "Suspended"}

      # The status is a fact — it stays true until SerpApi says otherwise — and
      # the searches left are a reading.
      assert {:ok,
              %{
                fact: "Account status: Suspended · Free Plan",
                reading: "Searches left: 238"
              }} = Validators.interpret_serpapi(200, body)

      # Case aside, "Active" is the documented healthy value, so the status
      # drops out of the fact and the plan is all that is left of it.
      assert {:ok, %{fact: "Free Plan", reading: "Searches left: 238"}} =
               Validators.interpret_serpapi(200, %{@serpapi_ok | "account_status" => "active"})
    end

    test "an error body is an error, whatever the status" do
      assert {:error, "SerpApi error: Account is suspended."} =
               Validators.interpret_serpapi(200, %{"error" => "Account is suspended."})

      assert {:error, "Unexpected answer from SerpApi"} =
               Validators.interpret_serpapi(200, %{"error" => ""})

      assert {:error, "SerpApi error 429: Too many requests."} =
               Validators.interpret_serpapi(429, %{"error" => "Too many requests."})
    end

    test "an error of any other shape is not an account" do
      for error <- [%{"code" => "rate_limited"}, ["x"], true, 1] do
        assert {:error, "Unexpected answer from SerpApi"} =
                 Validators.interpret_serpapi(200, Map.put(@serpapi_ok, "error", error)),
               inspect(error)
      end

      # An explicit null or false is no error.
      assert {:ok, %{}} = Validators.interpret_serpapi(200, Map.put(@serpapi_ok, "error", nil))
      assert {:ok, %{}} = Validators.interpret_serpapi(200, Map.put(@serpapi_ok, "error", false))
    end

    test "answers without a SerpApi body fall back to the HTTP status" do
      assert {:error, "Invalid API key"} = Validators.interpret_serpapi(401, "")
      assert {:error, "SerpApi error 503"} = Validators.interpret_serpapi(503, "<html></html>")

      assert {:error, "Unexpected answer from SerpApi"} =
               Validators.interpret_serpapi(200, "<html></html>")
    end
  end

  defp with_balance(balance) do
    put_in(@dataforseo_ok, ["tasks", Access.at(0), "result", Access.at(0), "money"], %{
      "balance" => balance
    })
  end

  # Wraps a plug so the test can see how many requests reached it. The plug runs
  # in Probe's check process, hence a counter rather than the process dictionary.
  defp counting(respond) do
    counter = :counters.new(1, [])

    plug = fn conn ->
      :counters.add(counter, 1, 1)
      respond.(conn)
    end

    {plug, fn -> :counters.get(counter, 1) end}
  end

  # A plug for tests that must not reach the network at all.
  defp flunk_request(_conn), do: flunk("no request was expected")

  defp s3_error(code) do
    {:http_error, 403,
     %{
       body: "<?xml version=\"1.0\"?><Error><Code>#{code}</Code><Message>x</Message></Error>"
     }}
  end

  # Same idea as `stub/1` below, but for the 1-arity `data -> result` shape
  # `request_list_buckets/2`'s requester uses (SES's confirm-retry threads a
  # region through too, hence the separate helper).
  defp stub1(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fn _data ->
      Agent.get_and_update(agent, fn
        [result | rest] -> {result, rest}
        [] -> raise "the requester was called more times than the test allows"
      end)
    end
  end

  defp stub(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fn _region, _data ->
      Agent.get_and_update(agent, fn
        [result | rest] -> {result, rest}
        [] -> raise "the requester was called more times than the test allows"
      end)
    end
  end

  # Accepts the connection and then says nothing at all — no SMTP banner.
  defp silent_relay do
    listener = listen()

    server =
      spawn(fn ->
        {:ok, _socket} = :gen_tcp.accept(listener)
        # Hold it open: an acceptor that exits closes the socket with it, and the
        # client would see a dropped connection rather than the silence under test.
        Process.sleep(:infinity)
      end)

    # spawn_link would NOT do: a normal exit does not propagate, so the acceptor, the
    # listener and the accepted socket would outlive the test for the life of the VM.
    reap(server, listener)
    port(listener)
  end

  # Greets, answers EHLO, and advertises no AUTH — an IP-authenticated smarthost.
  defp relay_without_auth(notify \\ nil) do
    listener = listen()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        if notify, do: send(notify, :relay_accepted)
        :gen_tcp.send(socket, "220 relay.internal ESMTP\r\n")
        {:ok, _ehlo} = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.send(socket, "250-relay.internal\r\n250-8BITMIME\r\n250 SIZE 10240000\r\n")
        # The client gives up at the auth step; hold the socket until we are reaped.
        Process.sleep(:infinity)
      end)

    reap(server, listener)
    port(listener)
  end

  defp listen do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :line])

    listener
  end

  defp port(listener) do
    {:ok, port} = :inet.port(listener)
    port
  end

  defp reap(server, listener) do
    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)
  end

  defp aws_error(code) do
    {:http_error, 403,
     %{
       body:
         "<ErrorResponse><Error><Code>#{code}</Code><Message>x</Message></Error></ErrorResponse>"
     }}
  end
end
