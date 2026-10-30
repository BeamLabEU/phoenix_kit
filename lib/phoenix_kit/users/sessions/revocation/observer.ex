defmodule PhoenixKit.Users.Sessions.Revocation.Observer do
  @moduledoc false

  require Logger

  # Bound consecutive connection failures, not the duration of a valid host
  # transaction. A permanently stopped dynamic repo must not retain tasks
  # (and their in-memory token batches) forever.
  @doc false
  def run(check, batch_size, opts \\ []) do
    poll(check, batch_size, 0, Keyword.get(opts, :max_failures, 30),
      delay: Keyword.get(opts, :initial_delay, 25),
      max_delay: Keyword.get(opts, :max_delay, 1_000)
    )
  end

  defp poll(check, batch_size, failures, limit, timing) do
    case check.() do
      :done ->
        :ok

      :retry ->
        pause(timing)
        poll(check, batch_size, 0, limit, advance(timing))

      :unavailable when failures + 1 >= limit ->
        Logger.warning(
          "[PhoenixKit] Session disconnect observer stopped after #{failures + 1} " <>
            "consecutive repo failures (#{batch_size} sessions); token absence was not verified"
        )

        :unavailable

      :unavailable ->
        if failures == 0 do
          Logger.warning(
            "[PhoenixKit] Session disconnect observer cannot reach the repo; retrying"
          )
        end

        pause(timing)
        poll(check, batch_size, failures + 1, limit, advance(timing))
    end
  end

  defp pause(timing), do: Process.sleep(timing[:delay])

  defp advance(timing),
    do: Keyword.put(timing, :delay, min(timing[:delay] * 2, timing[:max_delay]))
end
