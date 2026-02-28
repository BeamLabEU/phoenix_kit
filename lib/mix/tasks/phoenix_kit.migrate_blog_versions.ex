defmodule Mix.Tasks.PhoenixKit.MigrateBlogVersions do
  # Suppress dialyzer warnings for Mix module functions not recognized at analysis time
  @dialyzer :no_undefined_callbacks
  @dialyzer {:no_unknown, run: 1}

  @moduledoc """
  Migrates existing blog posts to the new versioned folder structure.

  This task moves blog posts from the legacy flat structure to the versioned structure:

  - Legacy: `blog-slug/post-slug/en.phk`
  - Versioned: `blog-slug/post-slug/v1/en.phk`

  All existing posts are treated as version 1 with the appropriate metadata fields added.

  ## Usage

      mix phoenix_kit.migrate_blog_versions

  ## Options

      --dry-run     Show what would be changed without making changes
      --verbose     Show detailed output during migration
      --blog SLUG   Only migrate a specific blog (default: all blogs)

  ## Examples

      # See what would be changed
      mix phoenix_kit.migrate_blog_versions --dry-run

      # Migrate all blogs with detailed output
      mix phoenix_kit.migrate_blog_versions --verbose

      # Migrate a specific blog
      mix phoenix_kit.migrate_blog_versions --blog my-blog

  The migration is idempotent - posts already in versioned structure are skipped.
  """

  @shortdoc "Migrates blog posts to versioned folder structure"

  use Mix.Task

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} =
      OptionParser.parse(args,
        switches: [
          dry_run: :boolean,
          verbose: :boolean,
          blog: :string
        ],
        aliases: [
          d: :dry_run,
          v: :verbose,
          b: :blog
        ]
      )

    # Start the application
    Mix.Task.run("app.start", [])

    # Welcome message
    Mix.shell().info([
      :bright,
      :blue,
      "\n📦 PhoenixKit Blog Version Migration Tool\n",
      :normal,
      "Migrating blog posts to versioned folder structure\n"
    ])

    if opts[:dry_run] do
      Mix.shell().info([:yellow, "🔍 DRY RUN MODE - No files will be modified\n"])
    end

    {:ok, stats} = run_migration(opts)
    display_success_summary(stats, opts)
  end

  defp run_migration(opts) do
    blogs = get_blogs_to_migrate(opts)

    if blogs == [] do
      Mix.shell().info([:yellow, "No blogs found to migrate."])
      {:ok, %{migrated: 0, skipped: 0, errors: 0}}
    else
      stats = %{migrated: 0, skipped: 0, errors: 0}

      stats =
        Enum.reduce(blogs, stats, fn blog, acc_stats ->
          migrate_blog(blog, opts, acc_stats)
        end)

      {:ok, stats}
    end
  end

  defp get_blogs_to_migrate(opts) do
    all_blogs = Publishing.list_groups()

    case opts[:blog] do
      nil ->
        # Migrate all blogs
        all_blogs

      slug ->
        # Find specific blog
        case Enum.find(all_blogs, fn b -> b["slug"] == slug end) do
          nil ->
            Mix.shell().error("Blog '#{slug}' not found")
            []

          blog ->
            [blog]
        end
    end
  end

  defp migrate_blog(blog, opts, stats) do
    blog_slug = blog["slug"]
    blog_mode = blog["mode"] || "timestamp"

    if opts[:verbose] do
      Mix.shell().info("\n📁 Processing blog: #{blog["name"]} (#{blog_slug})")
      Mix.shell().info("   Mode: #{blog_mode}")
    end

    # Only slug-mode blogs support versioning
    if blog_mode != "slug" do
      if opts[:verbose] do
        Mix.shell().info([
          :yellow,
          "   Skipping: Timestamp-mode blogs don't require version migration"
        ])
      end

      stats
    else
      migrate_slug_mode_blog(blog_slug, opts, stats)
    end
  end

  defp migrate_slug_mode_blog(blog_slug, opts, stats) do
    blog_path = Storage.group_path(blog_slug)

    case File.ls(blog_path) do
      {:ok, entries} ->
        post_slugs =
          entries
          |> Enum.filter(&File.dir?(Path.join(blog_path, &1)))
          |> Enum.reject(&(String.starts_with?(&1, ".") or String.starts_with?(&1, "_trash")))

        if opts[:verbose] do
          Mix.shell().info("   Found #{length(post_slugs)} post directories")
        end

        Enum.reduce(post_slugs, stats, fn post_slug, acc_stats ->
          migrate_post(blog_slug, post_slug, opts, acc_stats)
        end)

      {:error, reason} ->
        Mix.shell().error("   Error reading blog directory: #{reason}")
        %{stats | errors: stats.errors + 1}
    end
  end

  defp migrate_post(blog_slug, post_slug, opts, stats) do
    post_path = Path.join(Storage.group_path(blog_slug), post_slug)

    # Check the post structure
    case Storage.detect_post_structure(post_path) do
      :versioned ->
        # Already versioned, skip
        if opts[:verbose] do
          Mix.shell().info("   ✓ #{post_slug}: Already versioned (skipped)")
        end

        %{stats | skipped: stats.skipped + 1}

      :legacy ->
        # Needs migration
        if opts[:dry_run] do
          Mix.shell().info("   → #{post_slug}: Would migrate to v1/")
          %{stats | migrated: stats.migrated + 1}
        else
          case migrate_legacy_post(blog_slug, post_slug, opts) do
            :ok ->
              Mix.shell().info("   ✓ #{post_slug}: Migrated to v1/")
              %{stats | migrated: stats.migrated + 1}

            {:error, reason} ->
              Mix.shell().error("   ✗ #{post_slug}: Failed - #{reason}")
              %{stats | errors: stats.errors + 1}
          end
        end

      :empty ->
        if opts[:verbose] do
          Mix.shell().info("   - #{post_slug}: Empty directory (skipped)")
        end

        %{stats | skipped: stats.skipped + 1}
    end
  end

  defp migrate_legacy_post(blog_slug, post_slug, opts) do
    post_path = Path.join(Storage.group_path(blog_slug), post_slug)
    v1_path = Path.join(post_path, "v1")

    with {:ok, phk_files} <- list_phk_files_for_migration(post_path),
         :ok <- File.mkdir_p(v1_path),
         :ok <- migrate_phk_files(post_path, v1_path, phk_files, opts) do
      :ok
    else
      {:error, :no_files} -> {:error, "No .phk files found"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Failed to create v1 directory: #{inspect(reason)}"}
    end
  end

  defp list_phk_files_for_migration(post_path) do
    case File.ls(post_path) do
      {:ok, files} ->
        phk_files = Enum.filter(files, &String.ends_with?(&1, ".phk"))
        if phk_files == [], do: {:error, :no_files}, else: {:ok, phk_files}

      {:error, reason} ->
        {:error, "Failed to list files: #{inspect(reason)}"}
    end
  end

  defp migrate_phk_files(post_path, v1_path, phk_files, opts) do
    results = Enum.map(phk_files, &migrate_file(post_path, v1_path, &1, opts))

    if Enum.all?(results, &(&1 == :ok)) do
      :ok
    else
      errors = Enum.filter(results, &match?({:error, _}, &1))
      {:error, inspect(errors)}
    end
  end

  defp migrate_file(post_path, v1_path, file, opts) do
    source = Path.join(post_path, file)
    dest = Path.join(v1_path, file)

    with {:ok, content} <- File.read(source),
         {:ok, updated_content} <- update_metadata_for_v1(content),
         :ok <- File.write(dest, updated_content),
         :ok <- File.rm(source) do
      if opts[:verbose], do: Mix.shell().info("     Moved: #{file} → v1/#{file}")
      :ok
    else
      {:error, :enoent} -> {:error, "Failed to read: file not found"}
      {:error, reason} when is_atom(reason) -> {:error, "File operation failed: #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_metadata_for_v1(content) do
    # parse_with_content always returns {:ok, metadata, body_content}
    {:ok, metadata, body_content} = Metadata.parse_with_content(content)

    # Add version fields if missing
    now = UtilsDate.utc_now() |> DateTime.truncate(:second)

    updated_metadata =
      metadata
      |> Map.put_new(:version, 1)
      |> Map.put_new(:version_created_at, DateTime.to_iso8601(now))
      |> Map.put_new(:version_created_from, nil)
      |> Map.put_new(:is_live, metadata[:status] == "published")

    # Serialize back to content
    frontmatter = Metadata.serialize(updated_metadata)
    updated_content = frontmatter <> "\n" <> body_content

    {:ok, updated_content}
  end

  defp display_success_summary(stats, _opts) do
    Mix.shell().info([
      :bright,
      :green,
      "\n✅ Blog version migration completed!\n"
    ])

    Mix.shell().info("📊 Summary:")
    Mix.shell().info("   Migrated: #{stats.migrated} posts")
    Mix.shell().info("   Skipped:  #{stats.skipped} posts (already versioned or empty)")

    if stats.errors > 0 do
      Mix.shell().info([
        :red,
        "   Errors:   #{stats.errors} posts"
      ])
    end

    Mix.shell().info([
      :bright,
      "\n🎉 Posts are now in versioned folder structure!"
    ])

    Mix.shell().info([
      :normal,
      "\nNext steps:",
      "\n  • New posts will automatically use v1/ structure",
      "\n  • Editing a published post will create a new version",
      "\n  • Use the version switcher in the editor to navigate versions"
    ])
  end
end
