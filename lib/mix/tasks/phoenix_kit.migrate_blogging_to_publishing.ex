defmodule Mix.Tasks.PhoenixKit.MigrateBloggingToPublishing do
  @shortdoc "Migrates blogging module to publishing (storage path and settings)"
  @moduledoc """
  Migrates the PhoenixKit blogging module to the new publishing module.

  ## What this task does

  1. Renames `priv/blogging` directory to `priv/publishing` (if it exists)
  2. Migrates settings keys from legacy names to new names:
     - `blogging_enabled` → `publishing_enabled`
     - `blogging_blogs` → `publishing_groups`
     - `blogging_file_cache_enabled` → `publishing_file_cache_enabled`
     - `blogging_memory_cache_enabled` → `publishing_memory_cache_enabled`
     - `blogging_render_cache_enabled` → `publishing_render_cache_enabled`
     - `blogging_render_cache_enabled_*` → `publishing_render_cache_enabled_*`

  ## Usage

      mix phoenix_kit.migrate_blogging_to_publishing
      mix phoenix_kit.migrate_blogging_to_publishing --dry-run
      mix phoenix_kit.migrate_blogging_to_publishing --verbose

  ## Options

  - `--dry-run` - Shows what would be changed without making any changes
  - `--verbose` - Shows detailed output of each operation

  ## Safety

  This task is idempotent - it's safe to run multiple times:
  - If `priv/publishing` already exists, directory rename is skipped
  - If new settings keys already have values, those values are preserved
  - Legacy settings are not deleted (kept for backward compatibility)

  ## Rollback

  To rollback, manually:
  1. Rename `priv/publishing` back to `priv/blogging`
  2. The application will automatically read from legacy settings keys
  """

  use Mix.Task

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [dry_run: :boolean, verbose: :boolean])
    dry_run = Keyword.get(opts, :dry_run, false)
    verbose = Keyword.get(opts, :verbose, false)

    Mix.shell().info("PhoenixKit Blogging → Publishing Migration")
    Mix.shell().info(String.duplicate("=", 50))

    if dry_run do
      Mix.shell().info("Running in DRY RUN mode - no changes will be made\n")
    end

    # Start the application to access Settings
    unless dry_run do
      Mix.Task.run("app.start")
    end

    # Step 1: Migrate storage directory
    migrate_storage_directory(dry_run, verbose)

    # Step 2: Migrate settings keys
    migrate_settings_keys(dry_run, verbose)

    Mix.shell().info("\nMigration complete!")
  end

  defp migrate_storage_directory(dry_run, _verbose) do
    Mix.shell().info("\n1. Storage Directory Migration")
    Mix.shell().info(String.duplicate("-", 30))

    # Get paths
    legacy_path = Storage.legacy_root_path()
    new_path = Storage.new_root_path()

    legacy_exists = File.dir?(legacy_path)
    new_exists = File.dir?(new_path)

    cond do
      new_exists ->
        Mix.shell().info("✓ New path already exists: #{new_path}")
        Mix.shell().info("  Skipping directory rename")

      legacy_exists ->
        if dry_run do
          Mix.shell().info("Would rename: #{legacy_path}")
          Mix.shell().info("         to: #{new_path}")
        else
          case File.rename(legacy_path, new_path) do
            :ok ->
              Mix.shell().info("✓ Renamed: #{legacy_path}")
              Mix.shell().info("       to: #{new_path}")

            {:error, reason} ->
              Mix.shell().error("✗ Failed to rename directory: #{inspect(reason)}")
              Mix.shell().error("  You may need to rename manually:")
              Mix.shell().error("  mv #{legacy_path} #{new_path}")
          end
        end

      true ->
        Mix.shell().info("✓ Neither path exists - fresh installation")
        Mix.shell().info("  New installations will use: #{new_path}")
    end
  end

  defp migrate_settings_keys(dry_run, verbose) do
    Mix.shell().info("\n2. Settings Key Migration")
    Mix.shell().info(String.duplicate("-", 30))

    if dry_run do
      Mix.shell().info("Settings migration requires database access.")
      Mix.shell().info("Run without --dry-run to migrate settings.")
      return_settings_to_migrate()
    else
      migrate_settings(verbose)
    end
  end

  defp return_settings_to_migrate do
    settings = [
      {"blogging_enabled", "publishing_enabled"},
      {"blogging_blogs", "publishing_groups"},
      {"blogging_file_cache_enabled", "publishing_file_cache_enabled"},
      {"blogging_memory_cache_enabled", "publishing_memory_cache_enabled"},
      {"blogging_render_cache_enabled", "publishing_render_cache_enabled"}
    ]

    Mix.shell().info("\nSettings that would be migrated:")

    for {old_key, new_key} <- settings do
      Mix.shell().info("  #{old_key} → #{new_key}")
    end

    Mix.shell().info("  blogging_render_cache_enabled_* → publishing_render_cache_enabled_*")
  end

  defp migrate_settings(verbose) do
    # Core settings to migrate
    core_settings = [
      {"blogging_enabled", "publishing_enabled"},
      {"blogging_blogs", "publishing_groups"},
      {"blogging_file_cache_enabled", "publishing_file_cache_enabled"},
      {"blogging_memory_cache_enabled", "publishing_memory_cache_enabled"},
      {"blogging_render_cache_enabled", "publishing_render_cache_enabled"}
    ]

    # Migrate core settings
    for {old_key, new_key} <- core_settings do
      migrate_setting(old_key, new_key, verbose)
    end

    # Migrate per-blog render cache settings
    migrate_per_blog_render_cache_settings(verbose)
  end

  defp migrate_setting(old_key, new_key, verbose) do
    # Check if new key already has a value
    case Settings.get_setting(new_key, nil) do
      nil ->
        # New key doesn't exist, check legacy key
        case Settings.get_setting(old_key, nil) do
          nil ->
            if verbose do
              Mix.shell().info("  - #{old_key}: not set, skipping")
            end

          value ->
            Settings.update_setting(new_key, value)
            Mix.shell().info("✓ Migrated: #{old_key} → #{new_key}")

            if verbose do
              Mix.shell().info("    Value: #{inspect(value)}")
            end
        end

      _value ->
        Mix.shell().info("✓ #{new_key}: already exists, keeping existing value")
    end
  end

  defp migrate_per_blog_render_cache_settings(verbose) do
    # Find all per-blog render cache settings
    # These match the pattern blogging_render_cache_enabled_{slug}
    prefix = "blogging_render_cache_enabled_"
    new_prefix = "publishing_render_cache_enabled_"

    # We need to query the settings table for keys matching the pattern
    # Since we don't have a direct query function, we'll use the blogs list
    # to determine which per-blog settings might exist

    case Publishing.list_groups() do
      blogs when is_list(blogs) ->
        for blog <- blogs do
          slug = blog["slug"]
          old_key = prefix <> slug
          new_key = new_prefix <> slug
          migrate_setting(old_key, new_key, verbose)
        end

      _ ->
        if verbose do
          Mix.shell().info("  - No blogs found for per-blog settings migration")
        end
    end
  end
end
