defmodule Mix.Tasks.PhoenixKit.Gen.Migration do
  use Mix.Task

  @moduledoc """
  Generate a PhoenixKit versioned migration for the parent application.

  Scans existing migrations in `priv/repo/migrations/` to determine the current
  PhoenixKit version, then generates a migration that upgrades to the latest version.

  ## Usage

      mix phoenix_kit.gen.migration

  ## Options

    * `--prefix` - Database schema prefix (default: "public")

  ## Examples

      # Generate upgrade migration with default prefix
      mix phoenix_kit.gen.migration

      # Generate with custom schema prefix
      mix phoenix_kit.gen.migration --prefix my_schema

  """
  alias PhoenixKit.Migrations.Postgres, as: PkMigrations

  @shortdoc "Generate PhoenixKit versioned migration"

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)
    prefix = opts[:prefix] || "public"

    from_version = detect_current_version()
    to_version = PkMigrations.current_version()

    if from_version >= to_version do
      IO.puts("✅ Already at latest PhoenixKit migration version (v#{to_version}). Nothing to do.")
    else
      generate_migration(from_version, to_version, prefix)
    end
  end

  defp parse_args(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [prefix: :string])
    opts
  end

  # Scan existing migration files to find the highest PhoenixKit version applied.
  # Looks for files matching `*_phoenix_kit_update_v*_to_v*.exs` or `*_create_phoenix_kit_tables.exs`.
  defp detect_current_version do
    migrations_path = "priv/repo/migrations"

    if File.dir?(migrations_path) do
      migrations_path
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.flat_map(&extract_phoenix_kit_version/1)
      |> Enum.max(fn -> 0 end)
    else
      0
    end
  end

  # Extract the "to" version from migration filenames like:
  # - `20260310_phoenix_kit_update_v78_to_v80.exs` → 80
  # - `20260316_create_phoenix_kit_tables.exs`      → 0 (initial install)
  defp extract_phoenix_kit_version(filename) do
    cond do
      # Pattern: phoenix_kit_update_vXX_to_vYY.exs
      match = Regex.run(~r/phoenix_kit_update_v\d+_to_v(\d+)/, filename) ->
        [_, version_str] = match
        [String.to_integer(version_str)]

      # Pattern: create_phoenix_kit_tables.exs (initial install = version 1)
      String.contains?(filename, "create_phoenix_kit_tables") ->
        [1]

      true ->
        []
    end
  end

  defp generate_migration(from_version, to_version, prefix) do
    timestamp = generate_timestamp()
    slug = "phoenix_kit_update_v#{from_version}_to_v#{to_version}"
    filename = "#{timestamp}_#{slug}.exs"
    path = Path.join("priv/repo/migrations", filename)

    File.mkdir_p!("priv/repo/migrations")

    app_module = app_module_name()
    content = migration_content(app_module, slug, from_version, to_version, prefix)
    File.write!(path, content)

    IO.puts("✅ Generated migration: #{filename}")
    IO.puts("   Upgrades PhoenixKit: v#{from_version} → v#{to_version}")
    IO.puts("Run: mix ecto.migrate")
  end

  defp app_module_name do
    app = Mix.Project.config()[:app]

    app
    |> to_string()
    |> Macro.camelize()
  end

  defp migration_content(app_module, slug, from_version, to_version, prefix) do
    module_name = Macro.camelize(slug)
    create_schema = prefix != "public"

    """
    defmodule #{app_module}.Repo.Migrations.#{module_name} do
      @moduledoc false
      use Ecto.Migration

      @disable_ddl_transaction true

      def up do
        # PhoenixKit Update Migration: V#{from_version} -> V#{to_version}
        PhoenixKit.Migrations.up(
          prefix: "#{prefix}",
          version: #{to_version},
          create_schema: #{create_schema}
        )
      end

      def down do
        # Rollback PhoenixKit to V#{from_version}
        PhoenixKit.Migrations.down(
          prefix: "#{prefix}",
          version: #{from_version}
        )
      end
    end
    """
  end

  defp generate_timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    :io_lib.format(
      "~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B",
      [year, month, day, hour, minute, second]
    )
    |> to_string()
  end
end
