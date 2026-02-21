defmodule PhoenixKit.Modules.Publishing.Workers.ValidateMigrationWorker do
  @moduledoc """
  Oban worker that validates filesystem vs database consistency after migration.

  Compares post counts and content hashes between filesystem and database
  for each publishing group. Reports discrepancies via Logger and PubSub.

  Run this BEFORE switching reads to DB (`publishing_storage: :db`).

  ## Usage

      ValidateMigrationWorker.enqueue()

  ## PubSub Events

  Broadcasts to the publishing groups topic:

  - `{:migration_validation_completed, results}`
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.PubSub.Manager

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[ValidateMigration] Starting filesystem vs database comparison")

    groups = Publishing.list_groups()

    results =
      Enum.map(groups, fn group ->
        slug = group["slug"]
        mode = group["mode"] || "timestamp"
        validate_group(slug, mode)
      end)

    total_discrepancies = Enum.sum(Enum.map(results, & &1.discrepancies))

    Logger.info(
      "[ValidateMigration] Validation complete: " <>
        "#{length(results)} groups checked, #{total_discrepancies} discrepancies"
    )

    broadcast_validation_completed(results)

    if total_discrepancies > 0 do
      Logger.warning(
        "[ValidateMigration] Found #{total_discrepancies} discrepancies — review before switching to DB"
      )
    end

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  defp validate_group(group_slug, mode) do
    # Count filesystem posts
    fs_posts =
      case mode do
        "slug" -> Storage.list_posts_slug_mode(group_slug)
        _ -> Storage.list_posts(group_slug)
      end

    fs_count = length(fs_posts)

    # Count database posts
    db_posts = DBStorage.list_posts(group_slug)
    db_count = length(db_posts)

    # Check for DB group existence
    db_group = DBStorage.get_group_by_slug(group_slug)

    discrepancies =
      cond do
        is_nil(db_group) ->
          Logger.warning("[ValidateMigration] Group #{group_slug}: missing from database")
          1

        fs_count != db_count ->
          Logger.warning(
            "[ValidateMigration] Group #{group_slug}: " <>
              "FS has #{fs_count} posts, DB has #{db_count} posts"
          )

          abs(fs_count - db_count)

        true ->
          # Counts match — spot-check a few posts for content hash
          check_content_hashes(group_slug, fs_posts, mode)
      end

    %{
      group: group_slug,
      fs_posts: fs_count,
      db_posts: db_count,
      discrepancies: discrepancies,
      group_exists_in_db: not is_nil(db_group)
    }
  end

  defp check_content_hashes(group_slug, fs_posts, mode) do
    # Sample up to 10 posts for content hash comparison
    sample = Enum.take(fs_posts, 10)

    Enum.reduce(sample, 0, fn post, count ->
      post_slug = post[:slug]

      fs_result =
        case mode do
          "slug" -> Storage.read_post_slug_mode(group_slug, post_slug)
          _ -> Storage.read_post(group_slug, post[:path])
        end

      db_result = DBStorage.read_post(group_slug, post_slug)

      case {fs_result, db_result} do
        {{:ok, fs_post}, {:ok, db_post}} ->
          fs_hash = content_hash(fs_post[:content])
          db_hash = content_hash(db_post[:content])

          if fs_hash != db_hash do
            Logger.warning(
              "[ValidateMigration] Content mismatch: #{group_slug}/#{post_slug} " <>
                "(FS hash: #{fs_hash}, DB hash: #{db_hash})"
            )

            count + 1
          else
            count
          end

        {{:ok, _}, {:error, _}} ->
          Logger.warning(
            "[ValidateMigration] Post #{group_slug}/#{post_slug}: in FS but not in DB"
          )

          count + 1

        _ ->
          count
      end
    end)
  end

  defp content_hash(nil), do: "nil"

  defp content_hash(content) when is_binary(content) do
    :crypto.hash(:md5, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0..7)
  end

  defp broadcast_validation_completed(results) do
    Manager.broadcast(
      PublishingPubSub.groups_topic(),
      {:migration_validation_completed, results}
    )
  rescue
    _ -> :ok
  end

  @doc "Creates a validation job."
  def create_job do
    new(%{"type" => "validate_migration"})
  end

  @doc "Enqueues a validation job."
  def enqueue do
    create_job()
    |> Oban.insert()
  end
end
