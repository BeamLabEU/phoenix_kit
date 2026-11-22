defmodule PhoenixKit.API.OAuth.RequestLog do
  @moduledoc """
  Keeps the capability URLs of the kit out of the application log, for the stock endpoint
  loggers: the consent URL (`<prefix>/oauth/consent/<token>`), the query of any `/oauth/*`
  request, and the redeem URL of the cross-domain handoff (`<prefix>/handoff/<token>`,
  `PhoenixKit.Handoff`).

  The routes of these pages are declared `log: false`, but that only silences the router's own
  "Processing with ..." and "Parameters" lines. The path was still written by the request line of
  the endpoint's `Plug.Telemetry` (`Phoenix.Logger`, `:info`) and by `Plug.Logger`, both before the
  router runs and both outside the control of this library.

  So the kit registers a **primary Logger filter** (`install/0`, called when `PhoenixKit.Supervisor`
  starts) and the host's endpoint needs no change. The filter looks at the one shape those two
  loggers write, `"<METHOD> <path>"`, and at a plain text message: in the first it replaces the token
  of a consent or handoff path by `[FILTERED]` (the word Phoenix uses for a parameter it hides) and
  drops a query string from any `/oauth/` path; in the second it replaces the tokens. The three
  literal steps of the handoff (`start`, `prepare`, `mint`) are left readable: only the segment
  after `/handoff/` (and any repeated slashes: the router drops empty segments) that is not one
  of them is a token. A message written as other chardata (nested
  lists, a charlist) is read as one text first and judged the same way. Every other event passes
  unchanged. The `[RequestTimer]` lines of the kit's own `PhoenixKitWeb.Plugs.RequestTimer` log
  `path/1`.

  The filter is registered for every install, also while OAuth is off, and it is global to the
  VM: a line of another application that has the same shape is rewritten as well (a path with a
  `/handoff/<something>` segment anywhere in it, a host page included). A request logger that puts
  the path in metadata or in a report (not in a plain text message) is not covered, nor is a proxy's
  access log, an analytics tool or an error tracker: those are the host's.

  A token in a line of the log is of no use to a reader of the log alone anyway: a consent request
  is found only for the browser that started it (`PhoenixKit.API.OAuth.Requests`), and a handoff
  token only redeems in the browser that holds the nonce it was minted for.
  """

  @filter_id :phoenix_kit_oauth_request_log
  @consent_token ~r{(/oauth/consent/)[^/?#\s]+}
  # `/handoff/++`: the router drops empty segments, so `/handoff//<token>` redeems too; a step's
  # name after any number of slashes is still a step.
  @handoff_token ~r{(/handoff/++)(?!(?:start|prepare|mint)(?:[/?#\s]|\z))[^/?#\s]+}
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
    case hide_tokens(text) do
      ^text -> event
      hidden -> %{event | msg: {:string, hidden}}
    end
  end

  # Any other chardata (a list nested another way, a charlist): read as one text, and judged as
  # the request line when it has its shape, else as a plain text message. A message that is not
  # chardata passes as it is.
  def filter(%{msg: {:string, chardata}} = event, _extra) when is_list(chardata) do
    case flatten(chardata) do
      {:ok, text} ->
        if sensitive?(text), do: %{event | msg: {:string, redact_text(text)}}, else: event

      :error ->
        event
    end
  end

  def filter(event, _extra), do: event

  defp flatten(chardata) do
    {:ok, IO.chardata_to_string(chardata)}
  rescue
    _ -> :error
  end

  defp sensitive?(text),
    do: :binary.match(text, "/oauth/") != :nomatch or :binary.match(text, "/handoff/") != :nomatch

  defp redact_text(text) do
    case Regex.run(~r/\A([A-Z]+) (\S+)\z/, text, capture: :all_but_first) do
      [method, path] -> method <> " " <> redact(path)
      nil -> hide_tokens(text)
    end
  end

  @doc """
  The path of `conn` as it may be written to the log (see `redact/1`).
  """
  @spec path(Plug.Conn.t()) :: String.t()
  def path(%Plug.Conn{request_path: path}) when is_binary(path), do: redact(path)

  @doc """
  `path` as it may be logged: the token of a consent or handoff path is replaced by `[FILTERED]`,
  the query of an `/oauth/` path (a code, a state) is dropped, any other path is as it is.
  """
  @spec redact(String.t()) :: String.t()
  def redact(path) when is_binary(path) do
    path
    |> drop_oauth_query()
    |> hide_tokens()
  end

  defp drop_oauth_query(path) do
    if :binary.match(path, "/oauth/") == :nomatch, do: path, else: drop_query(path)
  end

  defp drop_query(path) do
    case :binary.split(path, "?") do
      [head, _query] -> head <> "?" <> @filtered
      [_whole] -> path
    end
  end

  defp hide_tokens(text) do
    text
    |> hide(@consent_token, "/oauth/consent/")
    |> hide(@handoff_token, "/handoff/")
  end

  # The cheap substring test first: almost every line the filter sees has neither.
  defp hide(text, pattern, marker) do
    if :binary.match(text, marker) == :nomatch,
      do: text,
      else: Regex.replace(pattern, text, "\\1" <> @filtered)
  end
end
