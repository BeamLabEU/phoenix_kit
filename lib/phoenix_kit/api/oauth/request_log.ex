defmodule PhoenixKit.API.OAuth.RequestLog do
  @moduledoc """
  Keeps the consent capability URL (`<prefix>/oauth/consent/<token>`) and the query of any
  `/oauth/*` request out of the application log, whatever the host's endpoint looks like.

  The routes of the OAuth pages are declared `log: false`, but that only silences the router's own
  "Processing with ..." and "Parameters" lines. The path was still written by the request line of
  the endpoint's `Plug.Telemetry` (`Phoenix.Logger`, `:info`) and by `Plug.Logger`, both before the
  router runs and both outside the control of this library.

  So the kit registers a **primary Logger filter** (`install/0`, called when `PhoenixKit.Supervisor`
  starts) and the host's endpoint needs no change. The filter looks at the one shape those two
  loggers write, `"<METHOD> <path>"`, and at a plain text message: in the first it replaces the token
  of a consent path by `[FILTERED]` (the word Phoenix uses for a parameter it hides) and drops a
  query string from any `/oauth/` path; in the second it replaces the token of a consent path. Every
  other event passes unchanged. The `[RequestTimer]` lines of the kit's own
  `PhoenixKitWeb.Plugs.RequestTimer` log `path/1`.

  A token in a line of the log is of no use to a reader of the log alone anyway: a request is found
  only for the browser that started it (`PhoenixKit.API.OAuth.Requests`).
  """

  @filter_id :phoenix_kit_oauth_request_log
  @consent_token ~r{(/oauth/consent/)[^/?#\s]+}
  @filtered "[FILTERED]"

  @doc """
  Registers the filter with the Logger (the primary filters of `:logger`). Safe to call again.
  """
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{msg: {:string, [method, ?\s, path]}} = event, _extra)
      when is_binary(method) and is_binary(path) do
    case redact(path) do
      ^path -> event
      redacted -> %{event | msg: {:string, [method, ?\s, redacted]}}
    end
  end

  def filter(%{msg: {:string, text}} = event, _extra) when is_binary(text) do
    if :binary.match(text, "/oauth/consent/") == :nomatch,
      do: event,
      else: %{event | msg: {:string, hide_token(text)}}
  end

  def filter(event, _extra), do: event

  @doc """
  The path of `conn` as it may be written to the log (see `redact/1`).
  """
  @spec path(Plug.Conn.t()) :: String.t()
  def path(%Plug.Conn{request_path: path}) when is_binary(path), do: redact(path)

  @doc """
  `path` as it may be logged: the token of a consent path is replaced by `[FILTERED]`, the query of
  an `/oauth/` path (a code, a state) is dropped, any other path is as it is.
  """
  @spec redact(String.t()) :: String.t()
  def redact(path) when is_binary(path) do
    if :binary.match(path, "/oauth/") == :nomatch,
      do: path,
      else: path |> drop_query() |> hide_token()
  end

  defp drop_query(path) do
    case :binary.split(path, "?") do
      [head, _query] -> head <> "?" <> @filtered
      [_whole] -> path
    end
  end

  defp hide_token(text), do: Regex.replace(@consent_token, text, "\\1" <> @filtered)
end
