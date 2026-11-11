defmodule PhoenixKit.Modules.Storage.ProbeCacheTest do
  @moduledoc """
  One piece of work asks a question of a picture once. Making a file's sizes asked its
  original for its size and its transparency once per size, each a full decode.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.ProbeCache

  setup do
    path = Path.join(System.tmp_dir!(), "pk_probe_#{System.unique_integer([:positive])}")
    File.write!(path, "one")
    on_exit(fn -> File.rm(path) end)
    counter = :counters.new(1, [])
    ask = fn -> :counters.add(counter, 1, 1) end
    %{path: path, ask: ask, asked: fn -> :counters.get(counter, 1) end}
  end

  test "outside run/1 nothing is remembered", ctx do
    assert ProbeCache.current() == nil
    for _ <- 1..3, do: ProbeCache.fetch(:q, ctx.path, ctx.ask)
    assert ctx.asked.() == 3
  end

  test "inside run/1 a question of a file is asked once, each question on its own", ctx do
    ProbeCache.run(fn ->
      assert ProbeCache.fetch(:size, ctx.path, fn -> ctx.ask.() && {:ok, 3} end) == {:ok, 3}
      assert ProbeCache.fetch(:size, ctx.path, fn -> ctx.ask.() && :other end) == {:ok, 3}
      assert ProbeCache.fetch(:alpha, ctx.path, fn -> ctx.ask.() && false end) == false
      assert ProbeCache.fetch(:alpha, ctx.path, fn -> ctx.ask.() && true end) == false
    end)

    assert ctx.asked.() == 2
    assert ProbeCache.current() == nil
  end

  test "a file written again is asked again", ctx do
    ProbeCache.run(fn ->
      assert ProbeCache.fetch(:q, ctx.path, fn -> :first end) == :first
      File.write!(ctx.path, "longer than before")
      assert ProbeCache.fetch(:q, ctx.path, fn -> :second end) == :second
    end)
  end

  test "a path that is not a file is asked every time", ctx do
    ProbeCache.run(fn ->
      for _ <- 1..2, do: ProbeCache.fetch(:q, ctx.path <> "-missing", ctx.ask)
    end)

    assert ctx.asked.() == 2
  end

  test "processes that adopt the cache ask once between them, waiting for the first", ctx do
    answers =
      ProbeCache.run(fn ->
        cache = ProbeCache.current()

        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            ProbeCache.adopt(cache)

            ProbeCache.fetch(:q, ctx.path, fn ->
              ctx.ask.()
              Process.sleep(50)
              :answer
            end)
          end)
        end)
        |> Task.await_many()
      end)

    assert answers == List.duplicate(:answer, 8)
    assert ctx.asked.() == 1
  end

  test "a question that raised is asked again, and the error is the caller's", ctx do
    ProbeCache.run(fn ->
      assert_raise RuntimeError, fn -> ProbeCache.fetch(:q, ctx.path, fn -> raise "no" end) end
      assert ProbeCache.fetch(:q, ctx.path, fn -> :fine end) == :fine
    end)
  end

  test "a nested run/1 uses the cache it is in, and leaves it in place", ctx do
    ProbeCache.run(fn ->
      ProbeCache.fetch(:q, ctx.path, ctx.ask)
      ProbeCache.run(fn -> ProbeCache.fetch(:q, ctx.path, ctx.ask) end)
      ProbeCache.fetch(:q, ctx.path, ctx.ask)
    end)

    assert ctx.asked.() == 1
  end

  test "a process that outlives the cache it adopted asks as if there were none", ctx do
    cache = ProbeCache.run(fn -> ProbeCache.current() end)
    ProbeCache.adopt(cache)
    assert ProbeCache.fetch(:q, ctx.path, fn -> :still end) == :still
    Process.delete({ProbeCache, :table})
  end
end
