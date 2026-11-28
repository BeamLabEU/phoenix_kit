defmodule Mix.Tasks.PhoenixKit.Gen.Migration do
  use Mix.Task

  @moduledoc """
  Generate a PhoenixKit versioned migration for the parent application.

  Scans existing migrations in `priv/repo/migrations/` to determine the current
  PhoenixKit version, then generates a migration that upgrades to the latest version.

  ## Usage

      mix phoenix_kit.gen.migration

  ## Options

    * `--prefix` - Database schema prefix. When omitted, resolves from
      `config :phoenix_kit, :prefix`, then defaults to "public" (validated:
      `[a-z_][a-z0-9_]*`). The generated migration passes
      `create_schema: true` only for a fresh install (no prior PhoenixKit
      migration in the project) with a non-public prefix.

  ## Examples

      # Generate upgrade migration with default prefix
      mix phoenix_kit.gen.migration

      # Generate with custom schema prefix
      mix phoenix_kit.gen.migration --prefix my_schema

  """
  alias PhoenixKit.Install.PrefixConfig
  alias PhoenixKit.Migrations.Postgres, as: PkMigrations

  @shortdoc "Generate PhoenixKit versioned migration"

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)
    prefix = PrefixConfig.resolve_prefix(opts)

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
  # Looks for files matching `*_phoenix_kit_update_v*_to_v*.exs` or
  # `*_add_phoenix_kit_tables.exs` / `*_create_phoenix_kit_tables.exs`.
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
  # - `20250908_add_phoenix_kit_tables.exs`         → 1 (initial install)
  # - `20260316_create_phoenix_kit_tables.exs`      → 1 (legacy initial-install name)
  #
  # `add_phoenix_kit_tables` is what the installer actually emits — see
  # `PhoenixKit.Install.MigrationStrategy.create_initial_migration_silent/3`
  # (`migration_strategy.ex:208`) and `PhoenixKit.Install.Common.phoenix_kit_migration?/1`'s
  # own doctest (`common.ex:299`). `create_phoenix_kit_tables` does not appear
  # anywhere the installer writes today (2026-07 audit: zero hits outside this
  # module's own comments) but is kept as a second, harmless match for any
  # older/manual migration using that name — widening the scan can only
  # recognize more real installs, never fewer, so both forms stay matched
  # rather than replacing one with the other.
  @doc false
  def extract_phoenix_kit_version(filename) do
    cond do
      # Pattern: phoenix_kit_update_vXX_to_vYY.exs
      match = Regex.run(~r/phoenix_kit_update_v\d+_to_v(\d+)/, filename) ->
        [_, version_str] = match
        [String.to_integer(version_str)]

      # Pattern: {add,create}_phoenix_kit_tables.exs (initial install = version 1)
      String.contains?(filename, "add_phoenix_kit_tables") or
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

  # Public for testability (mix task internals otherwise); @doc false.
  @doc false
  def migration_content(app_module, slug, from_version, to_version, prefix) do
    module_name = Macro.camelize(slug)
    # An upgrade (from_version > 0) implies the schema exists — never ask
    # the chain to create it (CREATE SCHEMA fails for low-privilege roles
    # even with IF NOT EXISTS; V01 skips it when the schema is present).
    # But from_version == 0 means no prior PhoenixKit migration exists in
    # the project: that's a fresh install and a non-public schema may
    # genuinely need creating.
    create_schema = from_version == 0 and prefix != "public"
    down_body = down_body(from_version, prefix)

    """
    defmodule #{app_module}.Repo.Migrations.#{module_name} do
      @moduledoc false
      use Ecto.Migration

      @disable_ddl_transaction true

      def up do
        # PhoenixKit Update Migration: V#{from_version} -> V#{to_version}
        # A no-op on a database already at V#{to_version} or later (up_to!/2).
        PhoenixKit.Migrations.up_to!(#{to_version},
          prefix: "#{prefix}",
          create_schema: #{create_schema}
        )
      end

      def down do
    #{down_body}
      end
    end
    """
  end

  # `from_version` is read off migration FILENAMES, and the installer's own file
  # (`add_phoenix_kit_tables`) carries no version: it scans as 1 whatever the
  # install really built, which today is the whole chain. A host installed at
  # V190 with no update file yet would get `down(version: 1)` here — and one
  # `mix ecto.rollback` of this single step would tear PhoenixKit down to the
  # chain's floor, dropping sixty versions of tables with their data instead of
  # the handful this step added. When the starting version is only that guess,
  # the generated `down` refuses and says how to roll back on purpose.
  @install_file_version 1

  defp down_body(@install_file_version, prefix) do
    """
        # The version this project was at before this step is not recorded in
        # its migration filenames (the install migration carries none), so an
        # automatic rollback has no safe target: guessing would drop most of
        # PhoenixKit's tables. To roll back deliberately, call
        # `PhoenixKit.Migrations.down(prefix: "#{prefix}", version: N)` with
        # the version you mean.
        raise "PhoenixKit: refusing to roll back — the version before this " <>
                "update is unknown. See the comment in this migration."\
    """
    |> String.trim_trailing("\n")
  end

  defp down_body(from_version, prefix) do
    """
        # Rollback PhoenixKit to V#{from_version}
        PhoenixKit.Migrations.down(
          prefix: "#{prefix}",
          version: #{from_version}
        )\
    """
    |> String.trim_trailing("\n")
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
