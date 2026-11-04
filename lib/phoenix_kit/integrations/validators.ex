defmodule PhoenixKit.Integrations.Validators do
  @moduledoc """
  Real connection checks for providers that cannot be validated with a simple
  authenticated HTTP GET.

  `PhoenixKit.Integrations` falls through to `:ok` for any provider that declares
  no validation. For the e-mail providers that meant "Test Connection" verified
  *nothing*: the connection was stamped `"connected"` without a single byte
  leaving the box, so an operator who pasted a wrong key or a bad SMTP password
  saw a green check and then a failing send.

  A check that always says yes is worse than no check — but so is one that says
  no when the configuration is fine. These validators are therefore careful in
  both directions:

    * a relay that authenticates by IP and offers no `AUTH` verb passes (the
      credentials are simply unused — sending works, so the check is green);
    * SES credentials scoped to `ses:SendEmail` only — the least-privilege policy
      AWS itself recommends — pass, even though they cannot read the send quota.

  Every check runs through `PhoenixKit.Integrations.Probe`, which bounds it with
  a hard deadline and isolates it from the caller — the libraries underneath
  bound neither themselves nor their crashes, and both call sites are LiveView
  callbacks.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.AWS.CredentialsVerifier
  alias PhoenixKit.Integrations.Probe
  alias PhoenixKit.Integrations.Telegram
  alias PhoenixKit.Mailer.SmtpEndpointPolicy
  alias PhoenixKit.Mailer.SmtpTransport
  alias PhoenixKit.Modules.Storage.Endpoint
  alias PhoenixKit.Modules.Storage.Providers.S3Request
  alias PhoenixKit.Utils.Number

  @http_timeout 15_000

  @typedoc "See `t:PhoenixKit.Integrations.Probe.note/0`."
  @type note :: Probe.note()

  @typedoc "A check's verdict, as `PhoenixKit.Integrations` reads it."
  @type verdict :: :ok | {:ok, note()} | {:error, String.t()}

  # A success with something to say, or a plain `:ok` when there is nothing.
  # `fact` stays with the connection; `reading` is true only now.
  defp ok_note(fact, reading) do
    note =
      %{}
      |> put_text(:fact, fact)
      |> put_text(:reading, reading)

    if note == %{}, do: :ok, else: {:ok, note}
  end

  defp put_text(note, _key, nil), do: note
  defp put_text(note, _key, ""), do: note
  defp put_text(note, key, text) when is_binary(text), do: Map.put(note, key, text)

  defp join_facts(parts) do
    case parts |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.join(" · ") do
      "" -> nil
      text -> text
    end
  end

  @doc """
  Validates AWS SES credentials against the SES API itself.

  Asks SES for the account's send quota — the cheapest call that proves the
  credentials are real. Built as a raw `ExAws.Operation.Query`, so it needs no
  `ex_aws_ses` dependency.

  The endpoint host is passed explicitly rather than left to ExAws, whose region
  resolution is a hard-coded prefix allowlist (`~r/^(us|eu|af|ap|sa|ca|me)-.../`)
  that silently yields *no host at all* for newer regions such as `il-central-1`
  — while the send path (`Swoosh.Adapters.AmazonSES`) simply interpolates the
  region and works. Validate and send must resolve the same endpoint.
  """
  @spec aws_ses(map()) :: verdict()
  def aws_ses(data) do
    region = data["aws_region"]

    cond do
      blank?(data["access_key"]) or blank?(data["secret_key"]) ->
        {:error, gettext("Incomplete credentials")}

      # ExAws would otherwise default a blank region to us-east-1 and happily
      # report success, while the send path builds "email..amazonaws.com" from
      # the same blank region and raises.
      blank?(region) ->
        {:error, gettext("Region is required")}

      true ->
        # The send-quota probe stays the AUTH VERDICT — its transient-
        # signature retry logic is what keeps good keys from being called
        # invalid. The CredentialsVerifier sweep (the same one the Emails
        # settings page runs) runs AFTERWARDS in its own probe and is
        # strictly additive: a passing verdict may gain account identity
        # and permission context, but enrichment failing, exiting, or
        # timing out can never downgrade the verdict itself.
        case Probe.run(fn -> request_send_quota(region, data) end) do
          :ok -> ok_with_note(region, data, %{})
          {:ok, %{} = note} -> ok_with_note(region, data, note)
          error -> error
        end
    end
  end

  # The quota is a reading; who the credentials belong to, and what they may
  # do, are facts. Enrichment can only add — see the comment in `aws_ses/1`.
  defp ok_with_note(region, data, note) do
    ok_note(join_facts([enrich_fact(region, data), note[:fact]]), note[:reading])
  end

  # Who the credentials belong to and which management APIs they may call:
  # standing facts, so they are what gets stored. Assembled inside the probe
  # closure, whose contract carries the note; `:ok` means "nothing to add",
  # and a probe that fails, exits or times out adds nothing.
  defp enrich_fact(region, data) do
    result =
      Probe.run(fn ->
        identity =
          case CredentialsVerifier.verify_credentials(
                 data["access_key"],
                 data["secret_key"],
                 region
               ) do
            {:ok, %{account_id: id}} -> gettext("Account %{id}", id: id)
            _ -> nil
          end

        perms =
          case CredentialsVerifier.check_permissions(
                 data["access_key"],
                 data["secret_key"],
                 region
               ) do
            {:ok, perms} -> perms
            _ -> nil
          end

        case aws_note(identity, perms) do
          nil -> :ok
          fact -> {:ok, %{fact: fact}}
        end
      end)

    case result do
      {:ok, %{fact: fact}} -> fact
      _ -> nil
    end
  end

  @doc false
  # Pure note assembly, public for tests. Only GRANTED management APIs are
  # listed — a least-privilege ses:SendEmail-only key (which the verdict
  # deliberately passes) must not read as "SES denied" here, so denied
  # services are omitted rather than dashed out.
  def aws_note(identity, perms) do
    granted =
      for {key, label} <- [ses: "SES", sqs: "SQS", sns: "SNS"],
          is_map(perms),
          perms |> Map.get(key, %{}) |> Map.values() |> Enum.any?(&(&1 == :granted)),
          do: label

    services =
      case granted do
        [] -> nil
        list -> gettext("management API: %{services}", services: Enum.join(list, ", "))
      end

    join_facts([identity, services])
  end

  @doc """
  Validates an Amazon Bedrock API key against the Bedrock control plane.

  Lists foundation models in the configured region — the cheapest call that
  proves both the key and the region at once. Bedrock long-term API keys
  authenticate with a plain Bearer header (no SigV4), the same header the
  OpenAI-compatible runtime endpoint accepts — a green check proves the
  completions path can authenticate IN THIS REGION; an AI endpoint must
  point its base URL at the same region for that guarantee to carry over.
  """
  @spec amazon_bedrock(map()) :: verdict()
  def amazon_bedrock(data) do
    region = String.trim(data["aws_region"] || "")
    api_key = String.trim(data["api_key"] || "")

    cond do
      blank?(api_key) ->
        {:error, gettext("No credentials configured")}

      blank?(region) ->
        {:error, gettext("Region is required")}

      # A malformed region would send the probe to a non-AWS hostname.
      not valid_aws_region?(region) ->
        {:error, gettext("Invalid region format (expected e.g. eu-central-1)")}

      true ->
        Probe.run(fn -> request_bedrock_models(region, api_key) end)
    end
  end

  @doc false
  # Pure, public for tests. The prefix is 2-4 letters (us-east-1 …
  # eusc-de-east-1), the suffix a small number.
  def valid_aws_region?(region) when is_binary(region) do
    Regex.match?(~r/^[a-z]{2,4}(-[a-z]+)+-\d{1,2}$/, region)
  end

  def valid_aws_region?(_), do: false

  defp request_bedrock_models(region, api_key) do
    # retry: false — the outer Probe deadline is the only clock here; Req's
    # default transient retries would sleep through most of it.
    case Req.get("#{bedrock_host(region)}/foundation-models",
           headers: [{"authorization", "Bearer " <> api_key}],
           receive_timeout: @http_timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"modelSummaries" => models}}} when is_list(models) ->
        # A fact, not a reading: the catalog is what proves the key works IN
        # THIS REGION, and nothing spends it.
        {:ok, %{fact: bedrock_models_note(length(models), region)}}

      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401}} ->
        {:error, gettext("Invalid credentials")}

      # The most likely 403 is a key whose IAM identity lacks
      # bedrock:CallWithBearerToken (or ListFoundationModels) — the key
      # itself authenticated, so "invalid credentials" would send the
      # operator off to reissue a perfectly good key.
      {:ok, %{status: 403}} ->
        {:error,
         gettext(
           "Key authenticated but not authorised in %{region} — allow bedrock:CallWithBearerToken (and ListFoundationModels) on its IAM identity, or check the key was issued for this region",
           region: region
         )}

      {:ok, %{status: status}} ->
        {:error, gettext("Bedrock error %{status}", status: status)}

      {:error, reason} ->
        Logger.warning("Bedrock connection check failed: #{inspect(reason)}")
        {:error, gettext("Could not reach Bedrock in %{region}", region: region)}
    end
  end

  @doc false
  # The China partition answers on .amazonaws.com.cn — the global host does not
  # resolve there at all, which would surface as "could not reach Bedrock".
  def bedrock_host("cn-" <> _ = region), do: "https://bedrock.#{region}.amazonaws.com.cn"
  def bedrock_host(region), do: "https://bedrock.#{region}.amazonaws.com"

  @doc false
  # Pure, public for tests. Sidesteps plural forms; the count is the region's
  # whole catalog, not the models this account may invoke — say so.
  def bedrock_models_note(count, region) do
    gettext("Model catalog in %{region}: %{count} (grants are configured separately)",
      count: count,
      region: region
    )
  end

  @doc """
  Validates an SMTP relay by opening a real session and authenticating.

  The connection options come from `PhoenixKit.Mailer.SmtpTransport.config/1`, so
  the check exercises exactly the transport a real send uses — one source of
  truth, no drift between "tested" and "sent".

  Forcing AUTH for the probe is deliberate: with gen_smtp's `:if_available` the
  AUTH exchange is attempted but its failure is tolerated, so a wrong password
  would still open a session and the check would pass. The operator's `auth`
  setting is honored in one direction only — `never` stays `never` (there are no
  credentials to prove), while `if_available` is upgraded to `always` for the
  probe so a bad password fails the check. A connection with no username and no
  password stays `never` for the same reason as an explicit `never`. A relay that
  advertises no `AUTH` verb at all is a different case, and is treated as a pass
  — see the module doc.

  `opts[:owner]` is the connection's owner (`:system` or `{:user, uuid}`). When
  the host has enabled `PhoenixKit.Mailer.SmtpEndpointPolicy`, a personal
  connection's host and port are checked — inside the probe, so a slow lookup
  is bounded too — and the session opens to the checked address; nothing
  connects to an internal host or a non-mail port. A missing owner gets the
  strict policy; `:system` is never checked.
  """
  @spec smtp(map(), keyword()) :: verdict()
  def smtp(data, opts \\ []) do
    policy = SmtpEndpointPolicy.policy_for(data, Keyword.get(opts, :owner))

    case SmtpTransport.config(data) do
      {:ok, options} ->
        Probe.run(fn -> check_and_open_smtp(options, policy) end)

      {:error, {:invalid_smtp_port, port}} ->
        {:error, gettext("Invalid port: %{port}", port: inspect(port))}

      {:error, :no_ca_store} ->
        {:error,
         gettext("No system CA certificates found, so the relay's certificate cannot be verified")}

      {:error, :invalid_ca_cert} ->
        {:error,
         gettext(
           "The CA certificate is not a valid PEM bundle (expected a -----BEGIN CERTIFICATE----- block)"
         )}

      {:error, {:invalid_timeout, value}} ->
        {:error, gettext("Invalid timeout: %{value}", value: inspect(value))}

      {:error, {key, value}}
      when key in [:invalid_security, :invalid_verify_cert, :invalid_auth] ->
        {:error,
         gettext("Invalid %{setting}: %{value}",
           setting: to_string(key) |> String.replace_prefix("invalid_", ""),
           value: inspect(value)
         )}

      # This case runs OUTSIDE Probe.run and its rescue, so a reason added to
      # SmtpTransport later would raise CaseClauseError straight out of a
      # LiveView callback. Say something useless-but-safe instead.
      {:error, reason} ->
        {:error, gettext("Invalid SMTP settings: %{reason}", reason: inspect(reason))}
    end
  end

  # --- SMTP -----------------------------------------------------------------

  defp check_and_open_smtp(options, policy) do
    case SmtpEndpointPolicy.enforce(options, policy) do
      {:ok, options} -> open_smtp(options)
      {:error, {:smtp_endpoint_refused, reason}} -> {:error, SmtpEndpointPolicy.message(reason)}
    end
  end

  # `never` is the operator saying there are no credentials to prove, so leave it
  # alone; anything else becomes `always` so a wrong password fails the check
  # instead of being tolerated (see `smtp/1`'s doc).
  #
  # A relay configured with no login at all is the same case arrived at from the
  # other direction: forcing `always` there makes the probe demand an AUTH
  # exchange it has nothing to send, so a perfectly working IP-authenticated
  # relay would fail Test Connection while sending fine.
  defp probe_auth(options) do
    cond do
      Keyword.get(options, :auth, :if_available) == :never -> :never
      blank?(options[:username]) and blank?(options[:password]) -> :never
      true -> :always
    end
  end

  defp open_smtp(options) do
    probe_options =
      options
      |> Keyword.put(:auth, probe_auth(options))
      # gen_smtp retries a temporarily-failing relay once by default, which doubles
      # the time to a verdict and can push a slow failure past our deadline — the
      # operator would be told "did not respond in time" instead of what went wrong.
      # A real send still wants the retry; a check does not.
      |> Keyword.put(:retries, 0)

    case :gen_smtp_client.open(probe_options) do
      {:ok, socket} ->
        :gen_smtp_client.close(socket)
        :ok

      # The relay offers no AUTH verb — it authenticates by IP, or not at all.
      # The credentials are unused, a real send works, and `username`/`password`
      # are required fields the operator had to fill in with something. A red
      # cross here would be a lie about a working relay.
      {:error, _type, {:missing_requirement, _host, :auth}} ->
        Logger.info("SMTP relay advertises no AUTH; credentials are unused by this relay")
        :ok

      {:error, :bad_option, reason} ->
        {:error, describe_bad_option(reason)}

      {:error, _type, reason} ->
        {:error, describe_smtp_failure(reason)}
    end
  rescue
    # gen_smtp calls to_binary/1 on the username, which has no clause for nil —
    # reachable through the pre-save "test what you typed" probe, which does not
    # go through the credential gate. It is a wide net, so it leaves a trace: a
    # FunctionClauseError from anywhere else must not vanish as "incomplete".
    error in FunctionClauseError ->
      Logger.warning("SMTP connection check raised FunctionClauseError: #{inspect(error)}")
      {:error, gettext("Incomplete SMTP settings")}

    error ->
      Logger.warning("SMTP connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach the SMTP server")}
  catch
    :exit, reason ->
      Logger.warning("SMTP connection check exited: #{inspect(reason)}")
      {:error, describe_smtp_failure(reason)}
  end

  defp describe_bad_option(reason)
       when reason in [:no_relay, :no_credentials, :invalid_port],
       do: gettext("Incomplete SMTP settings")

  defp describe_bad_option(_reason), do: gettext("Invalid SMTP settings")

  defp describe_smtp_failure(reason) do
    text = reason |> inspect() |> String.downcase()

    cond do
      # gen_smtp reports a rejected login as {:permanent_failure, host, :auth_failed}
      String.contains?(text, ["auth_failed", "535", "authentication", "not authenticated"]) ->
        gettext("Invalid credentials")

      String.contains?(text, ["tls_failed", "ssl_not_started"]) ->
        gettext("TLS handshake failed")

      String.contains?(text, ["nxdomain", "econnrefused", "timeout", "ehostunreach"]) ->
        gettext("Could not reach the SMTP server")

      true ->
        gettext("SMTP server rejected the connection")
    end
  end

  # --- SES ------------------------------------------------------------------

  @doc false
  # `requester` is injectable so the confirm-retry — the behaviour that keeps a valid
  # key from being reported invalid — can be tested without talking to AWS.
  def request_send_quota(region, data, requester \\ &send_quota_request/2) do
    case requester.(region, data) do
      # Never call credentials invalid on a single 403. AWS briefly answers a
      # *correct* request with SignatureDoesNotMatch right after it has rejected
      # a bad signature from the same key — which is exactly the flow an operator
      # produces by pasting a wrong key, fixing it, and pressing Test again.
      # Telling them their good keys are invalid sends them off to reissue
      # credentials that were never the problem. Confirm before accusing.
      {:invalid, _} ->
        # A full second, not less: SES throttles GetSendQuota at about one request
        # per second, and the confirm-retry doubles our rate against it. Come back
        # too soon and the second call answers Throttling, which reports a genuinely
        # invalid key as "AWS SES is busy".
        Process.sleep(1_000)

        case requester.(region, data) do
          {:invalid, _} -> {:error, gettext("Invalid credentials")}
          confirmed -> confirmed
        end

      result ->
        result
    end
  end

  defp send_quota_request(region, data) do
    operation = %ExAws.Operation.Query{
      action: :get_send_quota,
      path: "/",
      params: %{"Action" => "GetSendQuota", "Version" => "2010-12-01"},
      service: :ses,
      parser: fn response, _action -> response end
    }

    operation
    |> ExAws.request(
      access_key_id: data["access_key"],
      secret_access_key: data["secret_key"],
      region: region,
      host: "email.#{region}.amazonaws.com",
      # ExAws retries transport errors ten times with backoff by default; an
      # unreachable endpoint would block for minutes. Two attempts survives a
      # single blip (SES throttles GetSendQuota aggressively) and still stays
      # well inside the outer deadline.
      #
      # All three keys are mandatory. ExAws merges this override with `Map.merge`,
      # so the list REPLACES the default wholesale — pass `max_attempts` alone and
      # the backoff keys vanish, leaving `ExAws.Request.backoff/2` to evaluate
      # `nil * :math.pow(2, attempt)`. It raises, the rescue below swallows it, and
      # the check silently performs no retries at all.
      retries: [max_attempts: 2, base_backoff_in_ms: 10, max_backoff_in_ms: 1_000],
      http_opts: [recv_timeout: 5_000, connect_timeout: 5_000]
    )
    |> case do
      {:ok, %{body: body}} ->
        case format_quota_note(body) do
          nil -> :ok
          reading -> {:ok, %{reading: reading}}
        end

      {:error, reason} ->
        interpret_ses_error(reason)
    end
  rescue
    error ->
      Logger.warning("SES connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach AWS SES")}
  catch
    # hackney reaches its connection pool through GenServer.call, which exits
    # rather than raising — `rescue` alone does not see it.
    :exit, reason ->
      Logger.warning("SES connection check exited: #{inspect(reason)}")
      {:error, gettext("Could not reach AWS SES")}
  end

  @doc false
  # Pure: an AWS error payload in, an operator-facing verdict out. Public so the
  # mapping can be tested against real SES bodies without a network round trip.
  def interpret_ses_error({:http_error, _status, response}) do
    case aws_error_code(response) do
      code
      when code in ~w(SignatureDoesNotMatch InvalidClientTokenId UnrecognizedClientException
                      InvalidAccessKeyId ExpiredToken TokenRefreshRequired) ->
        {:invalid, code}

      # SES throttles GetSendQuota hard (~1 request/second). Reporting a
      # throttle as "invalid credentials" would send an operator off to reissue
      # perfectly good keys — observed live while testing this very validator.
      code
      when code in ~w(Throttling ThrottlingException RequestExpired
                      ServiceUnavailable InternalFailure) ->
        {:error, gettext("AWS SES is busy — try again in a moment")}

      # The credentials are valid and merely lack `ses:GetSendQuota` — which is
      # exactly what AWS's own least-privilege guidance produces (grant only
      # ses:SendEmail / ses:SendRawEmail). Reporting "invalid credentials" here
      # would put a permanent red cross on a correctly configured integration and
      # teach operators to ignore the check.
      #
      # But this is NOT proof that the key can send: a signature valid for the
      # wrong AWS account also lands here. So it passes with the truth attached
      # rather than a bare green tick — the note reaches the operator, not just
      # the log.
      "AccessDenied" <> _ ->
        {:ok,
         %{
           fact:
             gettext(
               "Credentials are valid, but not authorised for GetSendQuota — sending was not verified"
             )
         }}

      nil ->
        {:error, gettext("Could not reach AWS SES")}

      code ->
        {:error, gettext("AWS SES error: %{code}", code: code)}
    end
  end

  def interpret_ses_error(_reason), do: {:error, gettext("Could not reach AWS SES")}

  # The Query API answers with an XML body carrying an <Code> element.
  defp aws_error_code(%{body: body}) when is_binary(body), do: aws_error_code(body)

  defp aws_error_code(body) when is_binary(body) do
    case Regex.run(~r{<Code>([^<]+)</Code>}, body) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp aws_error_code(_), do: nil

  @doc false
  # Pure: an XML GetSendQuota body in, a compact operator-facing note out (or
  # `nil` if the body doesn't have the shape we expect — the credentials are
  # still good, we just have nothing to add). Public so the parsing can be
  # tested against real SES bodies without a network round trip.
  def format_quota_note(body) when is_binary(body) do
    with max when not is_nil(max) <- quota_tag(body, "Max24HourSend"),
         sent when not is_nil(sent) <- quota_tag(body, "SentLast24Hours"),
         rate when not is_nil(rate) <- quota_tag(body, "MaxSendRate") do
      # -1 signifies an unlimited quota — AWS's own convention for accounts
      # with no daily cap.
      max_text = if max == -1.0, do: gettext("unlimited"), else: Number.format(round(max))

      gettext("Quota: %{sent} / %{max} sent last 24h · max %{rate}/s",
        sent: Number.format(round(sent)),
        max: max_text,
        rate: Number.format(round(rate))
      )
    else
      _ -> nil
    end
  end

  def format_quota_note(_body), do: nil

  defp quota_tag(body, tag) do
    with [_, value] <- Regex.run(~r{<#{tag}>([^<]+)</#{tag}>}, body),
         {float, _rest} <- Float.parse(value) do
      float
    else
      _ -> nil
    end
  end

  # --- Object Storage (S3-compatible) ----------------------------------------

  @doc """
  Validates S3-compatible object storage credentials against the storage API
  itself (AWS S3, Cloudflare R2, Backblaze B2, Tigris, or a self-hosted
  endpoint).

  Calls `ListBuckets` — an account-level operation that needs no bucket name,
  so it works before the operator has picked one. Built via `ExAws.S3`
  (already a dependency); the `region`/`endpoint` config shape mirrors
  `PhoenixKit.Modules.Storage.Providers.S3`'s `aws_config/1`, which builds the
  same request for the same four providers.

  A refused `ListBuckets` (`AccessDenied`) passes with a note that bucket
  access was not verified: the signature was accepted, so the key is real,
  and a Cloudflare R2 token scoped to specific objects, for one, cannot list
  buckets. Each bucket is checked on its own form. Rejected keys
  (`InvalidAccessKeyId`, `SignatureDoesNotMatch`) still fail.

  Without a custom endpoint, the standard regional AWS host is used —
  including the `.amazonaws.com.cn` host for the China partition. A GovCloud
  environment that requires the FIPS endpoint (`s3-fips.<region>.amazonaws.com`)
  rather than the standard one should set it explicitly via `endpoint`.

  `opts[:owner]` is the connection's owner (`:system` or `{:user, uuid}`). The
  endpoint is where this server is about to connect, so it is checked before
  any request (`Storage.Endpoint.check/3`, resolving the host): a system
  connection may use a local or private endpoint (a MinIO on the same network
  is normal), a personal one may not, and nobody may use a metadata or
  link-local address.
  """
  @spec object_storage(map(), keyword()) :: verdict()
  def object_storage(data, opts \\ []) do
    cond do
      blank?(data["access_key"]) or blank?(data["secret_key"]) ->
        {:error, gettext("Incomplete credentials")}

      message = object_storage_endpoint_refusal(data, opts) ->
        {:error, message}

      true ->
        Probe.run(fn -> request_list_buckets(data) end)
    end
  end

  # An unknown owner is treated as personal: the strict policy is the default.
  defp object_storage_endpoint_refusal(data, opts) do
    policy = if Keyword.get(opts, :owner) == :system, do: :system, else: :personal

    case Endpoint.check(data["endpoint"], policy, resolve: true) do
      :ok ->
        nil

      {:error, :invalid_endpoint} ->
        gettext("The endpoint is not a usable host or URL")

      {:error, :insecure_scheme} ->
        gettext("The endpoint must use https")

      {:error, _blocked} ->
        gettext("The endpoint must not be a local, private or metadata address")
    end
  end

  @doc false
  # `requester` is injectable so the confirm-retry can be tested without
  # talking to a real endpoint — same shape as `request_send_quota/3`.
  def request_list_buckets(data, requester \\ &list_buckets_request/1) do
    case requester.(data) do
      # Never call credentials invalid on a single signature/key rejection.
      # AWS answers a *correct* request with SignatureDoesNotMatch right
      # after rejecting a bad signature from the same key, and a freshly
      # created IAM access key answers InvalidAccessKeyId until it
      # propagates — exactly the create-key/paste/Test flow a first-run
      # operator produces. ExAws's own retry logic does not cover this: a
      # 4xx is only retried for throttling-shaped codes (see
      # `ExAws.Request.request_and_retry/7`), never for these two.
      {:invalid, _code} ->
        # A full second, same as the SES confirm-retry: enough for a
        # transient signature rejection or IAM propagation delay to clear
        # without turning "Test Connection" into a multi-second wait.
        Process.sleep(1_000)

        case requester.(data) do
          {:invalid, _code} -> {:error, gettext("Invalid credentials")}
          confirmed -> confirmed
        end

      result ->
        result
    end
  end

  defp list_buckets_request(data) do
    ExAws.S3.list_buckets()
    |> S3Request.request(object_storage_config(data))
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> interpret_object_storage_error(reason)
    end
  rescue
    error ->
      Logger.warning("Object storage connection check failed: #{inspect(error)}")
      {:error, gettext("Could not reach the storage endpoint")}
  catch
    # hackney reaches its connection pool through GenServer.call, which exits
    # rather than raising — `rescue` alone does not see it (see the SES
    # request above).
    :exit, reason ->
      Logger.warning("Object storage connection check exited: #{inspect(reason)}")
      {:error, gettext("Could not reach the storage endpoint")}
  end

  @doc false
  # Pure: the data map in, the ExAws config out — public so host resolution
  # can be tested without a network round trip.
  def object_storage_config(data) do
    region = object_storage_region(data)

    base = [
      access_key_id: data["access_key"],
      secret_access_key: data["secret_key"],
      region: region,
      # ExAws otherwise retries transport errors ten times with backoff,
      # which would keep an unreachable endpoint hanging well past any
      # reasonable check — same override `request_send_quota/2` uses.
      retries: [max_attempts: 2, base_backoff_in_ms: 10, max_backoff_in_ms: 1_000],
      http_opts: [recv_timeout: 5_000, connect_timeout: 5_000]
    ]

    # `host` is ALWAYS passed explicitly, custom endpoint or not — never left
    # to ExAws to resolve. `ExAws.Config.Defaults.host/2` matches the region
    # against a hardcoded partition-prefix regex
    # (`~r/^(us|eu|af|ap|sa|ca|me)-.../`) that has no entry for newer regions
    # (confirmed: `il-central-1` and `mx-central-1` both resolve to `nil`),
    # which builds a bare "https:/" request URL and fails as :nxdomain —
    # correct credentials in those regions would read as "could not reach
    # the storage endpoint". Same trap `aws_ses`'s `send_quota_request/2`
    # dodges above by building the SES host itself instead of trusting ExAws.
    # ExAws's resolver DOES get the China partition right, though (`.cn`
    # suffix) — `object_storage_default_host/1` below keeps that one case.
    #
    # A custom endpoint goes through `Storage.Endpoint.parse/1`, the parser a
    # bucket's endpoint goes through, so the host validated here is the host a
    # bucket using this connection talks to (a pasted scheme, a trailing slash
    # and a port all read the same way). A set but unusable endpoint never
    # falls back to AWS: `object_storage/2` refuses it first.
    case Endpoint.parse(data["endpoint"]) do
      nil ->
        base ++ [host: object_storage_default_host(region), scheme: "https://"]

      %{scheme: scheme, host: host, port: port} ->
        base ++ [host: host, scheme: scheme <> "://", port: port]

      {:error, :invalid_endpoint} ->
        raise ArgumentError, "the endpoint is not a usable URL"
    end
  end

  # The China partition answers on .amazonaws.com.cn — the global host does
  # not resolve there at all. Same split `bedrock_host/1` above uses for the
  # same reason.
  defp object_storage_default_host("cn-" <> _ = region), do: "s3.#{region}.amazonaws.com.cn"
  defp object_storage_default_host(region), do: "s3.#{region}.amazonaws.com"

  defp object_storage_region(data) do
    if blank?(data["region"]), do: "us-east-1", else: String.trim(data["region"])
  end

  @doc false
  # Pure: an ExAws error reason in, an operator-facing verdict out. Public so
  # the mapping can be tested without a network round trip. Same shape as
  # `interpret_ses_error/1` — `{:invalid, code}` for the codes worth
  # confirming before the final verdict, `{:ok, %{fact: note}}` for a refused
  # `ListBuckets` (the credentials are real, what they cover is not known),
  # `{:error, message}` everywhere else.
  # Mapped against AWS's own S3 error codes; R2/B2/Tigris mirror these for
  # S3-API compatibility, but a provider-specific code not in this list still
  # surfaces verbatim rather than being misclassified.
  def interpret_object_storage_error({:http_error, _status, response}) do
    case aws_error_code(response) do
      code when code in ~w(InvalidAccessKeyId SignatureDoesNotMatch) ->
        {:invalid, code}

      # The signature is valid — the identity is real — it just lacks
      # ListBuckets/ListAllMyBuckets. That is the normal shape of a token
      # limited to one bucket (a Cloudflare R2 token scoped to specific
      # objects cannot list buckets), the key a site should hold, so a red
      # cross here would sit permanently on a correctly configured connection.
      # It passes with what was not verified attached, same as SES's
      # AccessDenied: each bucket is checked on its own form. The note states
      # only what was observed — AccessDenied also comes back for an IAM user
      # with no S3 rights or a key from another account, so it does not name
      # the cause.
      "AccessDenied" <> _ ->
        {:ok,
         %{
           fact:
             gettext(
               "Credentials are valid, but not allowed to list buckets — bucket access was not verified"
             )
         }}

      # Rate-limited or a transient service-side hiccup, not a bad
      # credential — telling the operator to reissue keys over this would be
      # wrong advice. `RequestTimeTooSkewed` is deliberately NOT here: it's a
      # clock problem, and retrying won't fix it, so it falls through to the
      # verbatim case below instead of a misleading "try again".
      code when code in ~w(SlowDown InternalError ServiceUnavailable) ->
        {:error, gettext("Storage service is busy — try again in a moment")}

      nil ->
        {:error, gettext("Could not reach the storage endpoint")}

      code ->
        {:error, gettext("Storage error: %{code}", code: code)}
    end
  end

  def interpret_object_storage_error(_reason),
    do: {:error, gettext("Could not reach the storage endpoint")}

  # --- Brevo ------------------------------------------------------------

  @doc """
  Validates a Brevo API key against the account endpoint, and reports the
  remaining credits.

  Brevo authenticates with a bare `api-key` header (no `Bearer` prefix), and
  `GET /v3/account` doubles as the cheapest authenticated call and the only
  one that tells the operator anything beyond "the key works" — the plan's
  remaining send credits, which is exactly what silently runs out mid-campaign.
  """
  @spec brevo_api(map()) :: verdict()
  def brevo_api(data) do
    api_key = data["api_key"]

    if blank?(api_key) do
      {:error, gettext("No credentials configured")}
    else
      request_account(api_key)
    end
  end

  defp request_account(api_key) do
    case Req.get("https://api.brevo.com/v3/account",
           headers: [{"api-key", api_key}],
           receive_timeout: @http_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        case format_credits_note(body) do
          nil -> :ok
          reading -> {:ok, %{reading: reading}}
        end

      {:ok, %{status: 401}} ->
        {:error, gettext("Invalid credentials")}

      {:ok, %{status: 403}} ->
        {:error, gettext("Access denied")}

      {:ok, %{status: status}} ->
        {:error, gettext("Brevo error %{status}", status: status)}

      {:error, reason} ->
        Logger.warning("Brevo connection check failed: #{inspect(reason)}")
        {:error, gettext("Could not reach Brevo")}
    end
  end

  @doc false
  # Pure: a decoded /v3/account JSON body in, a compact operator-facing note
  # out (or `nil` if there is no usable plan info). Public so the parsing can
  # be tested against real Brevo bodies without a network round trip.
  def format_credits_note(%{"plan" => plan}) when is_list(plan) and plan != [] do
    case plan |> Enum.map(&format_plan_entry/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      entries -> gettext("Plan: %{entries}", entries: Enum.join(entries, "; "))
    end
  end

  def format_credits_note(_body), do: nil

  defp format_plan_entry(%{"type" => type} = entry) when is_binary(type) do
    entry
    |> Map.get("credits")
    |> credits_text(type)
    |> with_reset_date(entry["endDate"])
  end

  defp format_plan_entry(_entry), do: nil

  defp credits_text(credits, type) when is_number(credits) do
    gettext("%{type} · %{credits} credits left",
      type: type,
      credits: Number.format(round(credits))
    )
  end

  defp credits_text(_credits, type), do: type

  defp with_reset_date(text, end_date) do
    case reset_date(end_date) do
      nil -> text
      date -> gettext("%{text} · resets %{date}", text: text, date: date)
    end
  end

  # Brevo's real /v3/account sends `endDate` as an ISO-8601 STRING
  # ("2017-04-11T00:00:00.000Z" — confirmed against the official reference,
  # Postman collection and SDKs). The integer clause is belt-and-braces for
  # a unix timestamp, should the API ever change shape.
  defp reset_date(end_date) when is_binary(end_date) do
    case DateTime.from_iso8601(end_date) do
      {:ok, datetime, _offset} -> Date.to_iso8601(DateTime.to_date(datetime))
      {:error, _reason} -> nil
    end
  end

  defp reset_date(end_date) when is_integer(end_date) do
    case DateTime.from_unix(end_date) do
      {:ok, datetime} -> Date.to_iso8601(DateTime.to_date(datetime))
      {:error, _reason} -> nil
    end
  end

  defp reset_date(_end_date), do: nil

  # --- Telegram ---------------------------------------------------------

  @doc """
  Validates a Telegram bot token against the Bot API's `getMe`.

  Telegram embeds the token in the URL path (`/bot<token>/getMe`) rather than a
  header, so it can't use the generic header-based check. `getMe` is the
  cheapest authenticated call, and its reply carries the bot's username — a
  useful confirmation the operator connected the bot they meant to.
  """
  @spec telegram(map()) :: verdict()
  def telegram(data) do
    token = data["bot_token"]

    if blank?(token) do
      {:error, gettext("No bot token configured")}
    else
      request_telegram(token)
    end
  end

  defp request_telegram(token) do
    url = "https://api.telegram.org/bot#{token}/getMe"

    case Req.get(url, [receive_timeout: @http_timeout] ++ Telegram.req_options()) do
      {:ok, %{status: 200, body: body}} ->
        case telegram_username(body) do
          nil -> :ok
          username -> {:ok, %{fact: gettext("Connected as @%{username}", username: username)}}
        end

      # Telegram answers a bad or malformed token with 401/404 on this path.
      {:ok, %{status: status}} when status in [401, 404] ->
        {:error, gettext("Invalid bot token")}

      {:ok, %{status: status}} ->
        {:error, gettext("Telegram error %{status}", status: status)}

      {:error, reason} ->
        Logger.warning("Telegram connection check failed: #{inspect(reason)}")
        {:error, gettext("Could not reach Telegram")}
    end
  end

  defp telegram_username(%{"ok" => true, "result" => %{"username" => username}})
       when is_binary(username) and username != "",
       do: username

  defp telegram_username(_body), do: nil

  # --- DataForSEO ---------------------------------------------------------

  @dataforseo_account_url "https://api.dataforseo.com/v3/appendix/user_data"

  @doc """
  Validates a DataForSEO API login and password against the account endpoint,
  and reports the balance.

  `GET /v3/appendix/user_data` costs nothing, takes the same HTTP Basic
  credentials as every paid call, and carries the account balance — which is
  what runs out, because every search is paid from it.

  `req_options` is merged into the request (tests pass a `:plug`).
  """
  @spec dataforseo(map(), keyword()) :: verdict()
  def dataforseo(data, req_options \\ []) do
    login = data["login"]
    password = data["password"]

    if blank?(login) or blank?(password) do
      {:error, gettext("No credentials configured")}
    else
      Probe.run(fn -> request_dataforseo_account(login, password, req_options) end)
    end
  end

  defp request_dataforseo_account(login, password, req_options) do
    # retry: false — Req's retries would sleep through most of Probe's
    # deadline; one request is the check. redirect: false — the endpoint does
    # not redirect, and Req logs each Location it follows. decode_body: false
    # — see decode_json/1.
    options =
      Keyword.merge(
        [
          auth: {:basic, "#{login}:#{password}"},
          receive_timeout: @http_timeout,
          retry: false,
          redirect: false,
          decode_body: false
        ],
        req_options
      )

    case Req.get(@dataforseo_account_url, options) do
      {:ok, %{status: status, body: body}} ->
        interpret_dataforseo(status, decode_json(body))

      {:error, reason} ->
        case request_failure("DataForSEO", reason) do
          :unreachable -> {:error, gettext("Could not reach DataForSEO")}
          :unreadable -> {:error, gettext("Unexpected answer from DataForSEO")}
        end
    end
  end

  @doc false
  # Pure: the HTTP status and decoded body of /v3/appendix/user_data in, a
  # verdict out. Public so it can be tested against the answers DataForSEO
  # really gives.
  #
  # DataForSEO reports its own outcome in `status_code`, at the top of the body
  # and again on each task: 2xxxx is success, 4xxxx and 5xxxx are failures, and
  # the code says more than the HTTP status does. A wrong login or password is
  # HTTP 401 with code 40100 and no tasks.
  def interpret_dataforseo(200, %{"status_code" => code} = body)
      when is_integer(code) and code in 20_000..29_999 do
    case body["tasks"] do
      [%{"status_code" => task_code} = task | _]
      when is_integer(task_code) and task_code not in 20_000..29_999 ->
        dataforseo_error(task_code, task["status_message"])

      [%{"result" => [account | _]} | _] ->
        dataforseo_balance_note(account)

      # Authenticated — a bad login never gets a 2xxxx code — but nothing to
      # report beyond that.
      _ ->
        :ok
    end
  end

  def interpret_dataforseo(_status, %{"status_code" => code} = body)
      when is_integer(code) and code not in 20_000..29_999,
      do: dataforseo_error(code, body["status_message"])

  def interpret_dataforseo(401, _body), do: dataforseo_error(40_100, nil)

  def interpret_dataforseo(200, _body),
    do: {:error, gettext("Unexpected answer from DataForSEO")}

  def interpret_dataforseo(status, _body),
    do: {:error, gettext("DataForSEO error %{status}", status: status)}

  # Decimal rather than float formatting: `:erlang.float_to_binary/2` refuses
  # large floats, and an integer past the float range cannot become one. The
  # warning follows the amount shown, so "$0.00" never appears without it.
  defp dataforseo_balance_note(%{"money" => %{"balance" => balance}}) when is_number(balance) do
    cents = balance_cents(balance)
    amount = Decimal.to_string(cents, :normal)

    # A reading, not a fact: the next search spends it. The page that wants a
    # current balance asks for a check of its own.
    if Decimal.gt?(cents, 0) do
      ok_note(nil, gettext("Balance: $%{amount}", amount: amount))
    else
      ok_note(
        nil,
        gettext("Balance: $%{amount} — add funds before running searches", amount: amount)
      )
    end
  end

  defp dataforseo_balance_note(_account), do: :ok

  defp balance_cents(balance) do
    decimal = to_decimal(balance)
    context = Decimal.Context.get()
    # Decimal 3.2's quantize checks the context precision. Leave room for all
    # integer digits, cents and a rounding carry, without changing the caller's
    # context or rounding a large balance down to its default precision.
    precision = byte_size(Integer.to_string(decimal.coef)) + max(decimal.exp, 0) + 3

    Decimal.Context.with(%{context | precision: max(context.precision, precision)}, fn ->
      decimal
      |> Decimal.round(2)
      # -0.00 → 0.00
      |> Decimal.add(Decimal.new(0))
    end)
  end

  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  # The codes from DataForSEO's error list that an operator can act on; the
  # rest are reported with DataForSEO's own message.
  defp dataforseo_error(40_100, _message) do
    {:error,
     gettext(
       "Invalid API login or password — use the API password from the API Access page, not the one you sign in with"
     )}
  end

  defp dataforseo_error(40_104, _message),
    do: {:error, gettext("This DataForSEO account is not verified yet")}

  defp dataforseo_error(code, _message) when code in [40_200, 40_210],
    do: {:error, gettext("This DataForSEO account needs funds — top up the balance")}

  defp dataforseo_error(40_201, _message),
    do: {:error, gettext("DataForSEO has paused this account — contact their support")}

  defp dataforseo_error(40_202, _message),
    do: {:error, gettext("Too many requests to DataForSEO — try again in a minute")}

  defp dataforseo_error(40_203, _message) do
    {:error,
     gettext(
       "This DataForSEO account has reached its daily spending limit — raise it on app.dataforseo.com"
     )}
  end

  defp dataforseo_error(40_209, _message),
    do: {:error, gettext("Too many requests to DataForSEO at once — try again shortly")}

  defp dataforseo_error(code, message) when is_binary(message) and message != "" do
    {:error,
     gettext("DataForSEO error %{code}: %{message}",
       code: code,
       message: String.slice(message, 0, 200)
     )}
  end

  defp dataforseo_error(code, _message),
    do: {:error, gettext("DataForSEO error %{code}", code: code)}

  # --- SerpApi --------------------------------------------------------------

  @serpapi_account_url "https://serpapi.com/account.json"

  @doc """
  Validates a SerpApi key against the Account API, and reports the searches
  left.

  The Account API is free and does not count as a search. SerpApi takes its key
  as the `api_key` query parameter, as its search API does.

  `req_options` is merged into the request (tests pass a `:plug`).
  """
  @spec serpapi(map(), keyword()) :: verdict()
  def serpapi(data, req_options \\ []) do
    api_key = data["api_key"]

    if blank?(api_key) do
      {:error, gettext("No credentials configured")}
    else
      Probe.run(fn -> request_serpapi_account(api_key, req_options) end)
    end
  end

  defp request_serpapi_account(api_key, req_options) do
    # retry: false — Req's retries would sleep through most of Probe's
    # deadline; one request is the check. redirect: false — the endpoint does
    # not redirect; Req would log each Location it follows, and a same-host
    # redirect drops `params`, key included. decode_body: false — see
    # decode_json/1.
    options =
      Keyword.merge(
        [
          params: [api_key: api_key],
          receive_timeout: @http_timeout,
          retry: false,
          redirect: false,
          decode_body: false
        ],
        req_options
      )

    case Req.get(@serpapi_account_url, options) do
      {:ok, %{status: status, body: body}} ->
        interpret_serpapi(status, decode_json(body))

      {:error, reason} ->
        case request_failure("SerpApi", reason) do
          :unreachable -> {:error, gettext("Could not reach SerpApi")}
          :unreadable -> {:error, gettext("Unexpected answer from SerpApi")}
        end
    end
  end

  @doc false
  # Pure: the HTTP status and decoded body of /account.json in, a verdict out.
  # Public so it can be tested against the answers SerpApi really gives. A bad
  # key is HTTP 401 with `{"error": "Invalid API key. …"}`. An `error` of any
  # other shape still means the answer is not an account.
  def interpret_serpapi(200, %{"error" => message}) when is_binary(message) and message != "",
    do: {:error, gettext("SerpApi error: %{message}", message: String.slice(message, 0, 200))}

  def interpret_serpapi(200, %{"error" => error}) when error not in [nil, false],
    do: {:error, gettext("Unexpected answer from SerpApi")}

  def interpret_serpapi(200, %{} = account), do: serpapi_account_note(account)

  def interpret_serpapi(200, _body), do: {:error, gettext("Unexpected answer from SerpApi")}

  def interpret_serpapi(401, _body), do: {:error, gettext("Invalid API key")}

  def interpret_serpapi(status, %{"error" => message}) when is_binary(message) do
    {:error,
     gettext("SerpApi error %{status}: %{message}",
       status: status,
       message: String.slice(message, 0, 200)
     )}
  end

  def interpret_serpapi(status, _body),
    do: {:error, gettext("SerpApi error %{status}", status: status)}

  # The key worked; the note says what the account can do with it. An
  # account status other than SerpApi's documented "Active" leads the note —
  # the key is valid, but the account may not run searches.
  # The plan's name, and an account that is not active, are facts — they stay
  # true until SerpApi says otherwise. The searches left are a reading.
  defp serpapi_account_note(account) do
    status =
      case account["account_status"] do
        status when is_binary(status) and status != "" ->
          if String.downcase(status) != "active",
            do: gettext("Account status: %{status}", status: String.slice(status, 0, 50))

        _ ->
          nil
      end

    plan =
      case account["plan_name"] do
        plan when is_binary(plan) and plan != "" -> plan
        _ -> nil
      end

    ok_note(join_facts([status, plan]), serpapi_searches(account))
  end

  # `total_searches_left` is SerpApi's own count of what the account can still
  # run; the plan's monthly allowance alone would miss any extra credits. The
  # plan's name travels as a fact, so it is not repeated here.
  defp serpapi_searches(%{"total_searches_left" => left}) when is_integer(left) do
    if left > 0,
      do: gettext("Searches left: %{left}", left: Number.format(left)),
      else: gettext("No searches left")
  end

  defp serpapi_searches(_account), do: nil

  # --- shared ---------------------------------------------------------------

  # The body is decoded here rather than by Req, for two reasons. Req decodes
  # by the URL's extension when there is no content type, so a plain-text 503
  # from `account.json` came back as a decode error with its status lost. And a
  # decode error carries the whole body — SerpApi's account body includes the
  # API key — so it must never become a logged `{:error, reason}`. A body that
  # is not JSON stays a binary, which the interpreters read as "not an answer".
  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_json(body), do: body

  # A request that failed without a response to read. Only the kind of failure
  # is logged, never the whole term: some reasons carry response bytes (Mint's
  # `{:unexpected_data, data}`), so of a tuple only its tag is kept.
  defp request_failure(service, %error{reason: reason})
       when error in [Req.TransportError, Req.HTTPError] do
    Logger.warning("#{service} connection check failed: #{inspect(reason_tag(reason))}")
    :unreachable
  end

  # `Req.get/2` returns an exception struct as the error, always.
  defp request_failure(service, %{__struct__: kind}) do
    Logger.warning("#{service} connection check failed: unreadable answer (#{inspect(kind)})")
    :unreadable
  end

  defp reason_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(_reason), do: :other

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
