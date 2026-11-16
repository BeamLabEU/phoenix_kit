defmodule PhoenixKit.API.Problem do
  @moduledoc """
  RFC 9457 `application/problem+json` errors for the machine API.

  Every error the API sends, from the endpoint's `PhoenixKit.API.BodyGuard`
  to a tool handler's `{:error, code, message, context}`, goes through
  `send/4`, so a client sees one shape:

      {"type": "https://phoenixkit.dev/api/errors/forbidden",
       "title": "Forbidden", "status": 403, "code": "forbidden",
       "detail": "This key lacks catalogue.prices:write.",
       "context": {"required_scope": "catalogue.prices:write"},
       "request_id": "F9x..."}

  `code` is the contract: stable, machine-readable, and what an agent
  branches on. `detail` is always English prose for a human or an agent to
  relay. `context` carries the fields that make the error actionable
  (`required_scope`, `errors`, `retry_after`, ...).

  The codes of core are a closed table here (`core_code?/1`). A module adds its
  own through `c:PhoenixKit.Module.api_problems/0` (it can never replace a code of
  core). They are read only here, when an error is answered, so a successful call
  pays nothing. `statuses/0` is the table as it stands right now. A code that is
  in neither answers `500` and is logged: it means a handler returned a code
  nothing declares.
  """

  import Plug.Conn

  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.ModuleRegistry

  require Logger

  @type_base "https://phoenixkit.dev/api/errors/"

  @statuses %{
    unauthorized: 401,
    forbidden: 403,
    ip_not_allowed: 403,
    origin_not_allowed: 403,
    token_in_url: 400,
    invalid_json: 400,
    not_found: 404,
    module_disabled: 404,
    module_write_disabled: 403,
    method_not_allowed: 405,
    not_acceptable: 406,
    confirm_token_invalid: 409,
    revision_mismatch: 409,
    idempotency_key_reused: 409,
    idempotency_in_progress: 409,
    payload_too_large: 413,
    validation_failed: 422,
    rate_limited: 429,
    internal_error: 500
  }

  @titles %{
    unauthorized: "Unauthorized",
    forbidden: "Forbidden",
    ip_not_allowed: "IP address not allowed",
    origin_not_allowed: "Origin not allowed",
    token_in_url: "Credential in URL",
    invalid_json: "Invalid JSON",
    not_found: "Not found",
    module_disabled: "Module disabled",
    module_write_disabled: "Module writes disabled for sessions",
    method_not_allowed: "Method not allowed",
    not_acceptable: "Not acceptable",
    confirm_token_invalid: "Confirmation token invalid",
    revision_mismatch: "Revision mismatch",
    idempotency_key_reused: "Idempotency key reused",
    idempotency_in_progress: "Request in progress",
    payload_too_large: "Payload too large",
    validation_failed: "Validation failed",
    rate_limited: "Rate limited",
    internal_error: "Internal error"
  }

  @doc """
  Every error code the API can answer with right now, with its HTTP status: core's,
  those of the enabled modules.
  """
  @spec statuses() :: %{atom() => pos_integer()}
  def statuses do
    Map.merge(
      Map.new(ModuleRegistry.all_api_problems(), fn {code, %{status: status}} ->
        {code, status}
      end),
      @statuses
    )
  end

  @doc "Whether `code` is one of core's own, which no module can override."
  @spec core_code?(atom()) :: boolean()
  def core_code?(code) when is_atom(code), do: Map.has_key?(@statuses, code)

  @doc """
  What is declared for a `code` that core does not define: `%{status, title, advice}`
  from the enabled module that declares it, else `nil`.
  """
  @spec declared(atom()) ::
          %{status: pos_integer(), title: String.t(), advice: String.t() | nil} | nil
  def declared(code) when is_atom(code) do
    if core_code?(code),
      do: nil,
      else: Map.get(ModuleRegistry.all_api_problems(), code)
  end

  @doc """
  The HTTP status of an error `code`.

  A code that no table declares answers `500`.
  """
  @spec status(atom()) :: pos_integer()
  def status(code) when is_atom(code), do: code |> resolve() |> elem(0)

  @doc """
  The problem document as a map with string keys.

  `request_id` is left out of the map when it is `nil`.
  """
  @spec body(atom(), String.t(), map(), String.t() | nil) :: map()
  def body(code, detail, context, request_id)
      when is_atom(code) and is_binary(detail) and is_map(context) do
    {status, title, _known?} = resolve(code)
    build_body(code, status, title, detail, context, request_id)
  end

  defp build_body(code, status, title, detail, context, request_id) do
    %{
      "type" => @type_base <> Atom.to_string(code),
      "title" => title,
      "status" => status,
      "code" => Atom.to_string(code),
      "detail" => detail,
      "context" => context
    }
    |> put_request_id(request_id)
  end

  # `{status, title, known?}`: core's table first (no registry read), then what a module
  # declares, else the generic 500.
  defp resolve(code) do
    case Map.fetch(@statuses, code) do
      {:ok, status} ->
        {status, Map.fetch!(@titles, code), true}

      :error ->
        case declared(code) do
          %{status: status, title: title} -> {status, title, true}
          nil -> {500, "Error", false}
        end
    end
  end

  @doc """
  Sends the problem document for `code` and halts the connection.

  The response carries `content-type: application/problem+json` and
  `cache-control: no-store`. Three codes add a header: `unauthorized` a
  `www-authenticate` challenge, `forbidden` with a `required_scope` in the
  context an `insufficient_scope` challenge, and any context with a
  `retry_after` (seconds) a `retry-after` header.

  The request id is `conn.assigns.phoenix_kit_api_request_id` when the
  `PhoenixKit.API.Auth` plug has run, else the `x-request-id` response
  header that `Plug.RequestId` set. A header value with characters outside
  `[A-Za-z0-9_=+/-]` (`Plug.RequestId` accepts any client-sent id of 20..200
  bytes) is replaced by a fresh id, in the header and in the body, the same
  rule `Auth` applies.
  """
  @spec send(Plug.Conn.t(), atom(), String.t(), map()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, code, detail, context \\ %{})
      when is_atom(code) and is_binary(detail) and is_map(context) do
    {status, title, known?} = resolve(code)

    unless known? do
      Logger.warning(
        "[PhoenixKit.API] unknown error code (#{LogSafe.shape(code)}); answering 500"
      )
    end

    conn = settle_request_id(conn)
    payload = code |> build_body(status, title, detail, context, request_id(conn)) |> encode()

    conn
    |> put_challenge(code, context)
    |> put_retry_after(context)
    |> put_resp_header("content-type", "application/problem+json; charset=utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, payload)
    |> halt()
  end

  @doc false
  # `Plug.RequestId` accepts any client-sent id of 20..200 bytes. The id goes
  # into the problem body and the log lines, so only URL-safe characters are
  # kept.
  @spec safe_request_id?(String.t()) :: boolean()
  def safe_request_id?(id), do: String.match?(id, ~r/\A[A-Za-z0-9_=+\/-]+\z/)

  @doc false
  @spec new_request_id() :: String.t()
  def new_request_id, do: Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false)

  # Before `Auth` has run (a `BodyGuard` answer) the id is the header
  # `Plug.RequestId` set; an unsafe one is replaced, as `Auth` does.
  defp settle_request_id(%Plug.Conn{assigns: %{phoenix_kit_api_request_id: _id}} = conn), do: conn

  defp settle_request_id(conn) do
    case get_resp_header(conn, "x-request-id") do
      [id | _] ->
        if safe_request_id?(id),
          do: conn,
          else: put_resp_header(conn, "x-request-id", new_request_id())

      [] ->
        conn
    end
  end

  defp put_request_id(body, nil), do: body
  defp put_request_id(body, request_id), do: Map.put(body, "request_id", request_id)

  defp request_id(conn) do
    conn.assigns[:phoenix_kit_api_request_id] ||
      conn |> get_resp_header("x-request-id") |> List.first()
  end

  # With OAuth on, `PhoenixKit.API.Auth` leaves `:phoenix_kit_api_oauth_challenge` on the
  # conn and the challenge says where the protected resource's metadata is (RFC 9728). A
  # request that carried no credentials gets no `error` (RFC 6750 section 3.1). Without the
  # private the challenge is the plain one.
  defp put_challenge(conn, :unauthorized, _context) do
    case oauth_challenge(conn) do
      %{missing: true} = oauth ->
        challenge(conn, "Bearer " <> metadata_param(oauth))

      %{} = oauth ->
        challenge(conn, ~s(Bearer error="invalid_token", ) <> metadata_param(oauth))

      nil ->
        challenge(conn, ~s(Bearer error="invalid_token"))
    end
  end

  defp put_challenge(conn, :forbidden, %{required_scope: scope}) when is_binary(scope) do
    case oauth_challenge(conn) do
      %{} = oauth ->
        challenge(conn, ~s(Bearer error="insufficient_scope", ) <> metadata_param(oauth))

      nil ->
        challenge(conn, ~s(Bearer error="insufficient_scope"))
    end
  end

  defp put_challenge(conn, _code, _context), do: conn

  defp challenge(conn, value), do: put_resp_header(conn, "www-authenticate", value)

  defp metadata_param(%{resource_metadata: url}), do: ~s(resource_metadata="#{url}")

  # A URL that could break out of the quoted parameter (a quote, a backslash, a control
  # character, a space) is not sent at all: the plain challenge is the safe answer.
  defp oauth_challenge(conn) do
    case conn.private[:phoenix_kit_api_oauth_challenge] do
      %{resource_metadata: url} = oauth when is_binary(url) ->
        if url =~ ~r/\A[\x21\x23-\x5B\x5D-\x7E]+\z/, do: oauth, else: nil

      _ ->
        nil
    end
  end

  defp put_retry_after(conn, %{retry_after: seconds}) when is_integer(seconds) and seconds > 0,
    do: put_resp_header(conn, "retry-after", Integer.to_string(seconds))

  defp put_retry_after(conn, _context), do: conn

  # A context holding a term JSON cannot carry (a tuple, a pid) must not turn
  # an error response into a crash: fall back to an empty context.
  @doc false
  @spec encode(map()) :: binary()
  def encode(body) do
    JSON.encode!(body)
  rescue
    _ -> body |> Map.put("context", %{}) |> JSON.encode!()
  end
end
