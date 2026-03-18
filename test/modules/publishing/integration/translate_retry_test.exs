defmodule PhoenixKit.Integration.Publishing.TranslateRetryTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Workers.TranslatePostWorker

  defp unique_name, do: "retry Group #{System.unique_integer([:positive])}"

  defp create_group_and_post do
    {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
    {:ok, post} = Posts.create_post(group["slug"], %{title: "Retry Test"})
    {group, post}
  end

  # ============================================================================
  # Retry skip logic — languages translated by a previous attempt are skipped
  # ============================================================================

  describe "skip_already_translated/5" do
    test "skips languages with content updated after job insertion" do
      {group, post} = create_group_and_post()
      group_slug = group["slug"]

      # Record a time BEFORE we add translations
      job_inserted_at = DateTime.add(DateTime.utc_now(), -60, :second)

      # Get the version UUID for direct content creation
      version = DBStorage.get_latest_version(post[:uuid])

      # Create "de" and "fr" content rows directly (simulating previous attempt's work)
      {:ok, _} =
        DBStorage.upsert_content(%{
          version_uuid: version.uuid,
          language: "de",
          title: "Hallo",
          content: "Hallo Welt",
          status: "published"
        })

      {:ok, _} =
        DBStorage.upsert_content(%{
          version_uuid: version.uuid,
          language: "fr",
          title: "Bonjour",
          content: "Bonjour le monde",
          status: "published"
        })

      # "es" has no content row
      target_languages = ["de", "fr", "es"]

      remaining =
        TranslatePostWorker.skip_already_translated(
          target_languages,
          group_slug,
          post[:uuid],
          nil,
          job_inserted_at
        )

      # de and fr should be skipped (content updated after job_inserted_at)
      # es should remain (no content exists)
      assert "es" in remaining
      refute "de" in remaining
      refute "fr" in remaining
    end

    test "does not skip languages with content from before job insertion" do
      {group, post} = create_group_and_post()
      group_slug = group["slug"]

      # Create "de" content BEFORE the job was "inserted"
      version = DBStorage.get_latest_version(post[:uuid])

      {:ok, _} =
        DBStorage.upsert_content(%{
          version_uuid: version.uuid,
          language: "de",
          title: "Alt",
          content: "Alt inhalt",
          status: "draft"
        })

      # Job inserted AFTER the content — translation is stale, not from this job
      job_inserted_at = DateTime.add(DateTime.utc_now(), 5, :second)

      remaining =
        TranslatePostWorker.skip_already_translated(
          ["de"],
          group_slug,
          post[:uuid],
          nil,
          job_inserted_at
        )

      # de should NOT be skipped because its content predates the job
      assert "de" in remaining
    end

    test "processes all languages when none were previously translated" do
      {group, post} = create_group_and_post()
      group_slug = group["slug"]

      job_inserted_at = DateTime.add(DateTime.utc_now(), -60, :second)
      target_languages = ["de", "fr", "es"]

      remaining =
        TranslatePostWorker.skip_already_translated(
          target_languages,
          group_slug,
          post[:uuid],
          nil,
          job_inserted_at
        )

      assert remaining == target_languages
    end
  end
end
