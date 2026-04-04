defmodule PhoenixKit.Modules.Sitemap.LLMText.GenerateJob do
  @moduledoc """
  Oban worker for generating LLM text files.

  ## Scopes

  - `"all"` - Regenerate all sources and rebuild index
  - `"source"` - Regenerate a single source (by source_name) and rebuild index
  - `"file"` - Regenerate a single file (by source_name + path) and rebuild index

  ## Enqueueing

  Use the helper functions to build changesets; the caller inserts them:

      changeset = GenerateJob.enqueue_all()
      {:ok, job} = Oban.insert(changeset)

      changeset = GenerateJob.enqueue_for_source(:blog)
      {:ok, job} = Oban.insert(changeset)

      changeset = GenerateJob.enqueue_for_file(:blog, "posts/article.md")
      {:ok, job} = Oban.insert(changeset)
  """

  use Oban.Worker,
    queue: :sitemap,
    max_attempts: 3,
    unique: [period: 5, fields: [:args], keys: [:scope, :source]]

  require Logger

  alias PhoenixKit.Modules.Sitemap.LLMText.Generator

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "all"}}) do
    Logger.info("Sitemap.LLMText.GenerateJob: Running all sources")
    Generator.run_all()
  end

  def perform(%Oban.Job{args: %{"scope" => "source", "source" => source_name}}) do
    Logger.info("Sitemap.LLMText.GenerateJob: Running source #{source_name}")

    case resolve_source(source_name) do
      nil ->
        Logger.warning("Sitemap.LLMText.GenerateJob: Source not found: #{source_name}")
        {:error, {:source_not_found, source_name}}

      source_module ->
        Generator.run_source(source_module)
    end
  end

  def perform(%Oban.Job{args: %{"scope" => "file", "source" => source_name, "path" => path}}) do
    Logger.info("Sitemap.LLMText.GenerateJob: Running file #{path} from source #{source_name}")

    case resolve_source(source_name) do
      nil ->
        Logger.warning("Sitemap.LLMText.GenerateJob: Source not found: #{source_name}")
        {:error, {:source_not_found, source_name}}

      source_module ->
        alias PhoenixKit.Modules.Sitemap.LLMText.FileStorage
        alias PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

        files = Source.safe_collect_page_files(source_module)

        case Enum.find(files, fn {p, _} -> p == path end) do
          nil ->
            Logger.warning("Sitemap.LLMText.GenerateJob: File not found in source: #{path}")
            {:error, {:file_not_found, path}}

          {_, content} ->
            FileStorage.write(path, content)
            Generator.rebuild_index()
        end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc """
  Returns an Oban changeset that regenerates all sources. Caller inserts it.
  """
  @spec enqueue_all() :: Ecto.Changeset.t()
  def enqueue_all do
    new(%{"scope" => "all"})
  end

  @doc """
  Returns an Oban changeset that regenerates a specific source. Caller inserts it.
  """
  @spec enqueue_for_source(atom() | String.t()) :: Ecto.Changeset.t()
  def enqueue_for_source(source_name) when is_atom(source_name) do
    enqueue_for_source(Atom.to_string(source_name))
  end

  def enqueue_for_source(source_name) when is_binary(source_name) do
    new(%{"scope" => "source", "source" => source_name})
  end

  @doc """
  Returns an Oban changeset that regenerates a single file. Caller inserts it.
  """
  @spec enqueue_for_file(atom() | String.t(), String.t()) :: Ecto.Changeset.t()
  def enqueue_for_file(source_name, path) when is_atom(source_name) do
    enqueue_for_file(Atom.to_string(source_name), path)
  end

  def enqueue_for_file(source_name, path) when is_binary(source_name) and is_binary(path) do
    new(%{"scope" => "file", "source" => source_name, "path" => path})
  end

  @doc """
  Finds a source module whose `source_name/0` matches the given string.
  """
  @spec resolve_source(String.t()) :: module() | nil
  def resolve_source(source_name) when is_binary(source_name) do
    Generator.get_sources()
    |> Enum.find(fn mod ->
      case Code.ensure_loaded(mod) do
        {:module, _} ->
          function_exported?(mod, :source_name, 0) and
            to_string(mod.source_name()) == source_name

        _ ->
          false
      end
    end)
  end
end
