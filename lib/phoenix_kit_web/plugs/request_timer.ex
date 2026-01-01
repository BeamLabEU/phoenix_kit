defmodule PhoenixKitWeb.Plugs.RequestTimer do
  @moduledoc """
  A plug that logs detailed timing information for requests.

  Logs:
  - When request enters the plug (after endpoint plugs, before router)
  - When response is about to be sent
  - Total time spent in router/controller/view
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time(:microsecond)
    path = conn.request_path

    Logger.debug("[RequestTimer] START #{conn.method} #{path}")

    conn
    |> put_private(:request_timer_start, start_time)
    |> register_before_send(fn conn ->
      end_time = System.monotonic_time(:microsecond)
      duration_us = end_time - start_time
      duration_ms = duration_us / 1000

      Logger.info(
        "[RequestTimer] END #{conn.method} #{path} - #{Float.round(duration_ms, 2)}ms (status: #{conn.status})"
      )

      conn
    end)
  end
end
