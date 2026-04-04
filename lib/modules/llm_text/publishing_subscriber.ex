defmodule PhoenixKit.Modules.LLMText.PublishingSubscriber do
  @moduledoc """
  GenServer that subscribes to Publishing PubSub events and triggers
  incremental LLM text file regeneration.

  ## Events handled

  - `{:post_status_changed, post}` — if published: enqueue file job; otherwise delete file
  - `{:post_updated, post}` — if published: enqueue file job; otherwise skip
  - `{:post_deleted, post_identifier}` — delete file + enqueue source rebuild
  - `{:group_created, group}` — subscribe to new group's posts topic
  - `{:group_deleted, group_slug}` — enqueue source rebuild

  ## Topics

  Subscribes to:
  - `"publishing:groups"` — group lifecycle events
  - `"publishing:{group_slug}:posts"` — per-group post events for each existing group

  All Publishing calls are guarded with `Code.ensure_loaded?`.
  """

  use GenServer

  require Logger

  alias PhoenixKit.Modules.LLMText.FileStorage
  alias PhoenixKit.Modules.LLMText.Sources.Publishing, as: PublishingSource
  alias PhoenixKit.Modules.LLMText.Workers.GenerateLLMTextJob
  alias PhoenixKit.PubSub.Manager, as: PubSubManager

  @compile {:no_warn_undefined,
            [
              {PhoenixKit.Modules.Publishing, :enabled?, 0},
              {PhoenixKit.Modules.Publishing, :list_groups, 0},
              {PhoenixKit.Modules.Publishing.PubSub, :groups_topic, 0},
              {PhoenixKit.Modules.Publishing.PubSub, :posts_topic, 1}
            ]}

  @publishing_mod PhoenixKit.Modules.Publishing
  @publishing_pubsub PhoenixKit.Modules.Publishing.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    subscribe_to_groups()
    subscribe_to_existing_groups()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:post_status_changed, post}, state) do
    handle_post_event(post)
    {:noreply, state}
  end

  def handle_info({:post_updated, post}, state) do
    if published?(post) do
      handle_post_event(post)
    end

    {:noreply, state}
  end

  def handle_info({:post_deleted, post_identifier}, state) do
    handle_post_removed(post_identifier)
    {:noreply, state}
  end

  def handle_info({:group_created, group}, state) do
    subscribe_to_group(group["slug"])
    {:noreply, state}
  end

  def handle_info({:group_deleted, group_slug}, state) do
    enqueue_source_rebuild(group_slug)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private helpers

  defp handle_post_event(post) do
    group_slug = Map.get(post, :group, "")
    post_slug = extract_post_slug(post)

    if published?(post) do
      changeset =
        GenerateLLMTextJob.enqueue_for_file(:publishing, "#{group_slug}/#{post_slug}.txt")

      insert_job(changeset)
    else
      path = PublishingSource.build_file_path(group_slug, post_slug)
      FileStorage.delete(path)
      enqueue_source_rebuild(group_slug)
    end
  rescue
    error ->
      Logger.warning("LLMText PublishingSubscriber: handle_post_event failed: #{inspect(error)}")
  end

  defp handle_post_removed(post_identifier) do
    # post_identifier may be a string slug or map
    {group_slug, post_slug} =
      case post_identifier do
        %{group: g, slug: s} -> {to_string(g), to_string(s)}
        %{"group" => g, "slug" => s} -> {to_string(g), to_string(s)}
        _ -> {"unknown", to_string(post_identifier)}
      end

    path = PublishingSource.build_file_path(group_slug, post_slug)
    FileStorage.delete(path)
    enqueue_source_rebuild(group_slug)
  rescue
    error ->
      Logger.warning(
        "LLMText PublishingSubscriber: handle_post_removed failed: #{inspect(error)}"
      )
  end

  defp enqueue_source_rebuild(_group_slug) do
    changeset = GenerateLLMTextJob.enqueue_for_source(:publishing)
    insert_job(changeset)
  end

  defp insert_job(changeset) do
    Oban.insert(changeset)
  rescue
    error ->
      Logger.warning("LLMText PublishingSubscriber: failed to insert job: #{inspect(error)}")
      {:error, error}
  end

  defp subscribe_to_groups do
    if publishing_pubsub_available?() do
      topic = @publishing_pubsub.groups_topic()
      PubSubManager.subscribe(topic)
    end
  rescue
    _ -> :ok
  end

  defp subscribe_to_existing_groups do
    if publishing_available?() do
      groups = @publishing_mod.list_groups()

      Enum.each(groups, fn group ->
        subscribe_to_group(group["slug"])
      end)
    end
  rescue
    _ -> :ok
  end

  defp subscribe_to_group(group_slug) when is_binary(group_slug) do
    if publishing_pubsub_available?() do
      topic = @publishing_pubsub.posts_topic(group_slug)
      PubSubManager.subscribe(topic)
    end
  rescue
    _ -> :ok
  end

  defp publishing_available? do
    Code.ensure_loaded?(@publishing_mod) and
      function_exported?(@publishing_mod, :list_groups, 0)
  end

  defp publishing_pubsub_available? do
    Code.ensure_loaded?(@publishing_pubsub) and
      function_exported?(@publishing_pubsub, :groups_topic, 0)
  end

  defp published?(post) do
    case post do
      %{metadata: %{status: "published"}} -> true
      %{metadata: %{"status" => "published"}} -> true
      _ -> false
    end
  end

  defp extract_post_slug(post) do
    case Map.get(post, :mode) do
      :timestamp ->
        date = Map.get(post, :date)
        time = Map.get(post, :time)

        if date && time do
          time_str = time |> Time.to_string() |> String.slice(0..4) |> String.replace(":", "-")
          "#{Date.to_iso8601(date)}-#{time_str}"
        else
          Map.get(post, :slug, "post") || "post"
        end

      _ ->
        Map.get(post, :url_slug) || Map.get(post, :slug, "post") || "post"
    end
  end
end
