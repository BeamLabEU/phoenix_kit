defmodule PhoenixKit.Modules.LLMText.Workers.GenerateLLMTextJobTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.LLMText.Workers.GenerateLLMTextJob

  defmodule BlogSource do
    @behaviour PhoenixKit.Modules.LLMText.Sources.Source

    def source_name, do: :blog
    def enabled?, do: true
    def collect_index_entries, do: []
    def collect_page_files, do: []
  end

  setup do
    Application.put_env(:phoenix_kit, :llm_text_sources, [BlogSource])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :llm_text_sources)
    end)

    :ok
  end

  describe "enqueue_all/0" do
    test "returns a changeset with scope 'all'" do
      changeset = GenerateLLMTextJob.enqueue_all()
      assert changeset.valid?
      assert changeset.changes.args == %{"scope" => "all"}
    end
  end

  describe "enqueue_for_source/1" do
    test "accepts atom source name" do
      changeset = GenerateLLMTextJob.enqueue_for_source(:blog)
      assert changeset.valid?
      assert changeset.changes.args == %{"scope" => "source", "source" => "blog"}
    end

    test "accepts string source name" do
      changeset = GenerateLLMTextJob.enqueue_for_source("blog")
      assert changeset.valid?
      assert changeset.changes.args == %{"scope" => "source", "source" => "blog"}
    end
  end

  describe "enqueue_for_file/2" do
    test "accepts atom source name and path" do
      changeset = GenerateLLMTextJob.enqueue_for_file(:blog, "posts/article.md")
      assert changeset.valid?

      assert changeset.changes.args == %{
               "scope" => "file",
               "source" => "blog",
               "path" => "posts/article.md"
             }
    end

    test "accepts string source name and path" do
      changeset = GenerateLLMTextJob.enqueue_for_file("blog", "posts/article.md")
      assert changeset.valid?

      assert changeset.changes.args == %{
               "scope" => "file",
               "source" => "blog",
               "path" => "posts/article.md"
             }
    end
  end

  describe "resolve_source/1" do
    test "finds a source module by name string" do
      assert GenerateLLMTextJob.resolve_source("blog") == BlogSource
    end

    test "returns nil for unknown source" do
      assert GenerateLLMTextJob.resolve_source("nonexistent") == nil
    end
  end
end
