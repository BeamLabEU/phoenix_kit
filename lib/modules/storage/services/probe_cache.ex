defmodule PhoenixKit.Modules.Storage.ProbeCache do
  @moduledoc """
  Remembers what was asked of a picture on disk for the length of one piece of work.

  Processing a file asks the same questions of its original again and again: how big it
  is, whether it is see-through. Each is an ImageMagick run that decodes the whole
  picture (a quarter of a second for a phone's HEIC), and a file with seven sizes asked
  some twenty times, most of them at once. Inside `run/1` an answer is worked out once:
  a second caller, the same process or another one that `adopt/1`ed the cache, gets the
  first one's answer, waiting for it if it is still being worked out.

  Outside `run/1` nothing is remembered and `fetch/3` just calls the function, so the
  probes behave as they always did for every other caller.

  An answer belongs to a path as it is now: the key carries the file's size and
  modification time, so a path that is written again is asked again.
  """

  @key {__MODULE__, :table}
  @poll_ms 10
  # A waiter gives up on the one working an answer out and works it out itself.
  @wait_ms 30_000

  @doc """
  Runs `fun` with a cache. Nested inside another `run/1` (or after `adopt/1`) it uses
  the one already there.
  """
  @spec run((-> result)) :: result when result: var
  def run(fun) when is_function(fun, 0) do
    case current() do
      nil ->
        table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
        Process.put(@key, table)

        try do
          fun.()
        after
          Process.delete(@key)
          :ets.delete(table)
        end

      _table ->
        fun.()
    end
  end

  @doc "The cache of this process, to hand to a process it starts (`adopt/1`), or nil."
  @spec current() :: :ets.tid() | nil
  def current, do: Process.get(@key)

  @doc "Makes this process use `cache` (another process's `current/0`). Nil is no cache."
  @spec adopt(:ets.tid() | nil) :: :ok
  def adopt(nil), do: :ok

  def adopt(cache) do
    Process.put(@key, cache)
    :ok
  end

  @doc """
  The answer to `question` about the file at `path`: the remembered one, or `fun`'s,
  which is then remembered. Without a cache, or for a path that is not a file, `fun` is
  simply called.
  """
  @spec fetch(term(), Path.t(), (-> answer)) :: answer when answer: var
  def fetch(question, path, fun) when is_function(fun, 0) do
    with table when not is_nil(table) <- current(),
         {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <- File.stat(path) do
      lookup(table, {question, path, size, mtime}, fun, System.monotonic_time(:millisecond))
    else
      _ -> fun.()
    end
  end

  defp lookup(table, key, fun, started) do
    case state(table, key) do
      {:done, answer} ->
        answer

      :running ->
        if System.monotonic_time(:millisecond) - started > @wait_ms do
          fun.()
        else
          Process.sleep(@poll_ms)
          lookup(table, key, fun, started)
        end

      :claimed ->
        work_out(table, key, fun)

      # The cache's owner is gone, its table with it: ask as if there were none.
      :gone ->
        fun.()
    end
  end

  # What is known of `key`; `:claimed` when this caller is now the one to work it out.
  defp state(table, key) do
    case :ets.lookup(table, key) do
      [{^key, state}] -> state
      [] -> if :ets.insert_new(table, {key, :running}), do: :claimed, else: :running
    end
  rescue
    ArgumentError -> :gone
  end

  defp work_out(table, key, fun) do
    answer = fun.()
    put(table, key, {:done, answer})
    answer
  rescue
    error ->
      forget(table, key)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      forget(table, key)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp put(table, key, state) do
    :ets.insert(table, {key, state})
  rescue
    ArgumentError -> true
  end

  defp forget(table, key) do
    :ets.delete(table, key)
  rescue
    ArgumentError -> true
  end
end
