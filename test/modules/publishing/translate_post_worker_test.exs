defmodule PhoenixKit.Modules.Publishing.TranslatePostWorkerTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

  # ============================================================================
  # timeout/1 — Dynamic timeout scaling
  # ============================================================================

  describe "timeout/1" do
    test "scales with number of target languages" do
      job = build_job(%{"target_languages" => Enum.map(1..10, &"lang-#{&1}")})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 10 * 1.5 = 15 minutes
      assert timeout_ms == :timer.minutes(15)
    end

    test "uses minimum of 15 minutes for small language counts" do
      job = build_job(%{"target_languages" => ["de", "fr"]})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 2 * 1.5 = 3, but min is 15
      assert timeout_ms == :timer.minutes(15)
    end

    test "scales up for many languages" do
      langs = Enum.map(1..39, &"lang-#{&1}")
      job = build_job(%{"target_languages" => langs})
      timeout_ms = TranslatePostWorker.timeout(job)
      # 39 * 1.5 = 58.5, ceil = 59
      assert timeout_ms == :timer.minutes(59)
    end

    test "handles single language" do
      job = build_job(%{"target_languages" => ["de"]})
      timeout_ms = TranslatePostWorker.timeout(job)
      assert timeout_ms == :timer.minutes(15)
    end

    defp build_job(args) do
      %Oban.Job{args: args}
    end
  end
end
