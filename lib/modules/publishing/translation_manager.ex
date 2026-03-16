defmodule PhoenixKit.Modules.Publishing.TranslationManager do
  @moduledoc """
  Language and translation management for the Publishing module.

  Handles primary language detection, migration, adding/removing languages,
  setting translation statuses, and AI-powered translation.
  """

  require Logger

  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage

  @content_statuses Constants.content_statuses()
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

  @doc "Gets the primary language for a specific post from the database."
  def get_post_primary_language(group_slug, post_slug, _version \\ nil) do
    db_post =
      if Shared.uuid_format?(post_slug) do
        DBStorage.get_post_by_uuid(post_slug)
      else
        DBStorage.get_post(group_slug, post_slug)
      end

    case db_post do
      nil -> LanguageHelpers.get_primary_language()
      post -> post.primary_language || LanguageHelpers.get_primary_language()
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] get_post_primary_language failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      LanguageHelpers.get_primary_language()
  end

  @doc "Checks the primary language migration status for a post."
  def check_primary_language_status(group_slug, post_slug) do
    global_primary = LanguageHelpers.get_primary_language()

    case DBStorage.get_post(group_slug, post_slug) do
      nil ->
        {:needs_backfill, nil}

      %{primary_language: nil} ->
        {:needs_backfill, nil}

      %{primary_language: ^global_primary} ->
        {:ok, :current}

      %{primary_language: stored} ->
        {:needs_migration, stored}
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] check_primary_language_status failed for #{group_slug}/#{post_slug}: #{inspect(e)}"
      )

      {:needs_backfill, nil}
  end

  @doc """
  Updates the primary language for a post.
  Accepts a post UUID.
  """
  def update_post_primary_language(_group_slug, post_uuid, new_primary_language) do
    update_primary_language_in_db(post_uuid, new_primary_language)
  end

  @doc """
  Updates all posts in a group to use the current global primary language.

  Single bulk UPDATE query — runs in milliseconds. Regenerates cache after.
  Returns `{:ok, count}` with the number of posts updated.
  """
  @spec update_posts_primary_language(String.t()) :: {:ok, integer()}
  def update_posts_primary_language(group_slug) do
    primary_language = LanguageHelpers.get_primary_language()
    {:ok, count} = DBStorage.update_primary_language(group_slug, primary_language)

    if count > 0 do
      Logger.info(
        "[Publishing] Updated #{count} posts in #{group_slug} to primary language #{primary_language}"
      )

      ListingCache.regenerate(group_slug)

      PublishingPubSub.broadcast_primary_language_migration_completed(
        group_slug,
        count,
        0,
        primary_language
      )
    end

    {:ok, count}
  end

  @doc "Counts posts in a group that don't match the current primary language."
  @spec count_posts_needing_language_update(String.t()) :: integer()
  def count_posts_needing_language_update(group_slug) do
    primary_language = LanguageHelpers.get_primary_language()
    DBStorage.count_posts_needing_language_update(group_slug, primary_language)
  end

  @doc """
  Adds a new language translation to an existing post.

  Accepts an optional version parameter to specify which version to add
  the translation to. If not specified, defaults to the latest version.
  """
  @spec add_language_to_post(String.t(), String.t(), String.t(), integer() | nil) ::
          {:ok, map()} | {:error, any()}
  def add_language_to_post(group_slug, post_uuid, language_code, version \\ nil) do
    result = add_language_to_db(group_slug, post_uuid, language_code, version)

    with {:ok, new_post} <- result do
      ListingCache.regenerate(group_slug)

      broadcast_id = new_post.slug || new_post.uuid

      if broadcast_id do
        PublishingPubSub.broadcast_translation_created(group_slug, broadcast_id, language_code)
      end
    end

    result
  end

  # Adds a language to a post.
  # Creates a new content row in the database and returns the post map.
  @doc false
  def add_language_to_db(group_slug, post_uuid, language_code, version_number) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         version when not is_nil(version) <-
           if(version_number,
             do: DBStorage.get_version(db_post.uuid, version_number),
             else: DBStorage.get_latest_version(db_post.uuid)
           ),
         # Check if content already exists for this language
         nil <- DBStorage.get_content(version.uuid, language_code),
         {:ok, _content} <-
           DBStorage.create_content(%{
             version_uuid: version.uuid,
             language: language_code,
             title: Constants.default_title(),
             content: "",
             status: "draft"
           }) do
      # Read the post back from DB to return a proper post map
      Shared.read_back_post(group_slug, post_uuid, db_post, language_code, version.version_number)
    else
      nil ->
        {:error, :not_found}

      %PhoenixKit.Modules.Publishing.PublishingContent{} = _existing ->
        # Content already exists for this language - read back the post
        db_post = DBStorage.get_post_by_uuid(post_uuid, [:group])

        resolved_version =
          if version_number do
            version_number
          else
            case db_post && DBStorage.get_latest_version(db_post.uuid) do
              nil -> nil
              v -> v.version_number
            end
          end

        Shared.read_back_post(group_slug, post_uuid, db_post, language_code, resolved_version)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning(
        "[Publishing] add_language_to_db failed for #{group_slug}/#{post_uuid}/#{language_code}: #{inspect(e)}"
      )

      {:error, :not_found}
  end

  @doc """
  Hard-deletes a language's content row from a post.

  Unlike `delete_language` (which archives), this permanently removes the content.
  Refuses to delete the last remaining language.
  """
  @spec clear_translation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def clear_translation(group_slug, post_uuid, language_code) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         db_version when not is_nil(db_version) <- Shared.resolve_db_version(db_post, nil),
         content when not is_nil(content) <-
           DBStorage.get_content(db_version.uuid, language_code),
         :ok <- validate_not_last_content(db_version, language_code) do
      repo = PhoenixKit.RepoHelper.repo()

      case repo.delete(content) do
        {:ok, _} ->
          broadcast_id = db_post.slug || db_post.uuid
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_translation_deleted(group_slug, broadcast_id, language_code)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp validate_not_last_content(db_version, language_code) do
    remaining =
      DBStorage.list_contents(db_version.uuid)
      |> Enum.reject(&(&1.language == language_code))

    if remaining == [], do: {:error, :last_language}, else: :ok
  end

  @doc """
  Deletes a specific language translation from a post.

  For versioned posts, specify the version. For unversioned posts, version is ignored.
  Refuses to delete the last remaining language content.

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec delete_language(String.t(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, term()}
  def delete_language(group_slug, post_uuid, language_code, version \\ nil) do
    with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
         db_version when not is_nil(db_version) <- Shared.resolve_db_version(db_post, version),
         content when not is_nil(content) <-
           DBStorage.get_content(db_version.uuid, language_code),
         :ok <- validate_not_last_language(db_version) do
      case DBStorage.update_content(content, %{status: "archived"}) do
        {:ok, _} ->
          broadcast_id = db_post.slug || db_post.uuid
          ListingCache.regenerate(group_slug)
          PublishingPubSub.broadcast_translation_deleted(group_slug, broadcast_id, language_code)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp validate_not_last_language(db_version) do
    active =
      DBStorage.list_contents(db_version.uuid)
      |> Enum.reject(&(&1.status == "archived"))

    if length(active) <= 1, do: {:error, :last_language}, else: :ok
  end

  @doc """
  Sets a translation's status and marks it as manually overridden.

  When a translation status is set manually, it will NOT inherit status
  changes from the primary language when publishing.

  Accepts a post UUID or slug as the post identifier.

  ## Examples

      iex> Publishing.set_translation_status("blog", "019cce93-...", 2, "es", "draft")
      :ok
  """
  @spec set_translation_status(String.t(), String.t(), integer(), String.t(), String.t()) ::
          :ok | {:error, any()}
  def set_translation_status(group_slug, post_identifier, version, language, status)
      when status in @content_statuses do
    db_post =
      if Shared.uuid_format?(post_identifier) do
        DBStorage.get_post_by_uuid(post_identifier)
      else
        DBStorage.get_post(group_slug, post_identifier)
      end

    with db_post when not is_nil(db_post) <- db_post,
         db_version when not is_nil(db_version) <- DBStorage.get_version(db_post.uuid, version),
         content when not is_nil(content) <- DBStorage.get_content(db_version.uuid, language),
         :ok <- validate_translation_status_change(db_post, db_version, language, status) do
      case DBStorage.update_content(content, %{status: status}) do
        {:ok, _} ->
          if status == "published", do: ListingCache.regenerate(group_slug)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def set_translation_status(_group_slug, _post_identifier, _version, _language, _status) do
    {:error, :invalid_status}
  end

  # Prevents publishing a translation when the primary language content isn't published.
  # This avoids the contradiction where set_translation_status allows publishing but
  # fix_translation_status_consistency (stale fixer) silently reverts it.
  defp validate_translation_status_change(_db_post, _db_version, _language, status)
       when status != "published",
       do: :ok

  defp validate_translation_status_change(db_post, db_version, language, "published") do
    if language == db_post.primary_language do
      :ok
    else
      case DBStorage.get_content(db_version.uuid, db_post.primary_language) do
        nil ->
          {:error, :primary_not_published}

        primary ->
          if primary.status == "published", do: :ok, else: {:error, :primary_not_published}
      end
    end
  end

  @doc """
  Enqueues an Oban job to translate a post to all enabled languages using AI.

  This creates a background job that will:
  1. Read the source post in the primary language
  2. Translate the content to each target language using the AI module
  3. Create or update translation content for each language

  ## Options

  - `:endpoint_uuid` - AI endpoint UUID to use for translation (required if not set in settings)
  - `:source_language` - Source language to translate from (defaults to primary language)
  - `:target_languages` - List of target language codes (defaults to all enabled except source)
  - `:version` - Version number to translate (defaults to latest/published)
  - `:user_uuid` - User UUID for audit trail

  ## Configuration

  Set the default AI endpoint for translations:

      PhoenixKit.Settings.update_setting("publishing_translation_endpoint_uuid", "endpoint-uuid")

  ## Examples

      # Translate to all enabled languages using default endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...")

      # Translate with specific endpoint
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...",
        endpoint_uuid: "endpoint-uuid"
      )

      # Translate to specific languages only
      {:ok, job} = Publishing.translate_post_to_all_languages("docs", "019cce93-...",
        endpoint_uuid: "endpoint-uuid",
        target_languages: ["es", "fr", "de"]
      )

  ## Returns

  - `{:ok, %Oban.Job{}}` - Job was successfully enqueued
  - `{:error, changeset}` - Failed to enqueue job

  """
  @spec translate_post_to_all_languages(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def translate_post_to_all_languages(group_slug, post_uuid, opts \\ []) do
    TranslatePostWorker.enqueue(group_slug, post_uuid, opts)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp update_primary_language_in_db(post_uuid, new_primary_language) do
    case DBStorage.get_post_by_uuid(post_uuid) do
      nil ->
        {:error, :post_not_found}

      db_post ->
        case DBStorage.update_post(db_post, %{primary_language: new_primary_language}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      Logger.warning(
        "[Publishing] update_primary_language_in_db failed for #{post_uuid}: #{inspect(e)}"
      )

      {:error, :post_not_found}
  end
end
