defmodule PhoenixKit.Migrations.Postgres.V107Test do
  @moduledoc """
  Tests V107's backfill correctness.

  V107.up/down can't be invoked outside an `Ecto.Migrator` runner — they
  rely on `Ecto.Migration.execute/1` which checks for a runner process.
  Instead, this test runs the same backfill SQL directly via `Repo.query`
  against fixture rows, which is what we actually care about: that the
  backfill logic picks the right integration uuid for each endpoint.

  The schema change itself (column add + index) is implicitly verified
  by `test_helper.exs` which runs all core migrations including V107
  before any test runs — every other test that touches
  `phoenix_kit_ai_endpoints.integration_uuid` would fail at boot if
  the column weren't there.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Test.Repo

  defp insert_integration!(name, value_json) do
    # Build the INSERT with the JSON inlined as a literal so PostgreSQL
    # parses it as a JSONB object directly. Passing as a `$N::jsonb`
    # parameter double-encodes through Postgrex's string handling and
    # lands a JSON STRING (containing escaped JSON) instead of an
    # object — ` ->> 'key'` then returns NULL.
    json_literal = value_json |> Jason.encode!() |> String.replace("'", "''")

    %{rows: [[uuid_bin]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_settings (key, value_json, module)
        VALUES ($1, '#{json_literal}'::jsonb, 'integrations')
        RETURNING uuid
        """,
        ["integration:#{name}"]
      )

    Ecto.UUID.cast!(uuid_bin)
  end

  defp insert_endpoint!(name, provider) do
    %{rows: [[uuid_bin]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_ai_endpoints (
          name, provider, model, api_key, enabled, inserted_at, updated_at
        )
        VALUES ($1, $2, 'anthropic/claude-3-haiku', '', true, NOW(), NOW())
        RETURNING uuid
        """,
        [name, provider]
      )

    Ecto.UUID.cast!(uuid_bin)
  end

  defp endpoint_integration_uuid(endpoint_uuid) do
    {:ok, dumped} = Ecto.UUID.dump(endpoint_uuid)

    case Repo.query!(
           "SELECT integration_uuid FROM phoenix_kit_ai_endpoints WHERE uuid = $1",
           [dumped]
         ) do
      %{rows: [[nil]]} -> nil
      %{rows: [[bin]]} -> Ecto.UUID.cast!(bin)
    end
  end

  # Mirrors V107.up's two backfill UPDATE statements verbatim. Run as
  # raw SQL instead of through the migration runner.
  defp run_backfill! do
    Repo.query!("""
    UPDATE phoenix_kit_ai_endpoints e
    SET integration_uuid = s.uuid
    FROM phoenix_kit_settings s
    WHERE s.key = 'integration:' || e.provider
      AND e.integration_uuid IS NULL
      AND e.provider LIKE '%:%'
    """)

    Repo.query!("""
    UPDATE phoenix_kit_ai_endpoints e
    SET integration_uuid = winner.uuid
    FROM (
      SELECT
        split_part(key, ':', 2) AS provider_key,
        uuid,
        ROW_NUMBER() OVER (
          PARTITION BY split_part(key, ':', 2)
          ORDER BY
            (value_json ->> 'last_validated_at') DESC NULLS LAST,
            uuid ASC
        ) AS rn
      FROM phoenix_kit_settings
      WHERE key LIKE 'integration:%:%'
    ) winner
    WHERE winner.rn = 1
      AND winner.provider_key = e.provider
      AND e.integration_uuid IS NULL
      AND e.provider NOT LIKE '%:%'
    """)
  end

  describe "schema change (verified at boot)" do
    test "the integration_uuid column exists" do
      %{rows: [[exists]]} =
        Repo.query!("""
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'phoenix_kit_ai_endpoints'
            AND column_name = 'integration_uuid'
        )
        """)

      assert exists == true
    end

    test "the integration_uuid index exists" do
      %{rows: [[exists]]} =
        Repo.query!("""
        SELECT EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE indexname = 'phoenix_kit_ai_endpoints_integration_uuid_index'
        )
        """)

      assert exists == true
    end

    test "the unique name index exists" do
      %{rows: [[exists]]} =
        Repo.query!("""
        SELECT EXISTS (
          SELECT 1 FROM pg_indexes
          WHERE indexname = 'phoenix_kit_ai_endpoints_name_index'
        )
        """)

      assert exists == true
    end

    test "duplicate endpoint names are rejected by the new UNIQUE constraint" do
      _first = insert_endpoint!("Claude Haiku", "openrouter")

      assert_raise Postgrex.Error, ~r/duplicate key value violates/, fn ->
        insert_endpoint!("Claude Haiku", "openrouter")
      end
    end

    test "case-only differences in endpoint names collide (lower(name) index)" do
      _first = insert_endpoint!("Claude Haiku", "openrouter")

      assert_raise Postgrex.Error, ~r/duplicate key value violates/, fn ->
        insert_endpoint!("CLAUDE HAIKU", "openrouter")
      end
    end
  end

  describe "backfill — exact match for `provider:name` shape" do
    test "stamps integration_uuid for endpoints with explicit provider:name" do
      integration_uuid =
        insert_integration!("openrouter:my-key", %{
          "provider" => "openrouter",
          "name" => "my-key",
          "api_key" => "sk-my-key"
        })

      endpoint_uuid = insert_endpoint!("Test Endpoint", "openrouter:my-key")

      run_backfill!()

      assert endpoint_integration_uuid(endpoint_uuid) == integration_uuid
    end
  end

  describe "backfill — bare provider, most-recently-validated wins" do
    test "matches the row with the latest last_validated_at" do
      _older =
        insert_integration!("openrouter:old", %{
          "provider" => "openrouter",
          "name" => "old",
          "api_key" => "sk-old",
          "last_validated_at" => "2026-01-01T00:00:00Z"
        })

      newer =
        insert_integration!("openrouter:newer", %{
          "provider" => "openrouter",
          "name" => "newer",
          "api_key" => "sk-newer",
          "last_validated_at" => "2026-04-01T00:00:00Z"
        })

      endpoint_uuid = insert_endpoint!("Bare Endpoint", "openrouter")

      run_backfill!()

      assert endpoint_integration_uuid(endpoint_uuid) == newer
    end

    test "uuid ASC tiebreaks when last_validated_at ties (both NULL)" do
      first =
        insert_integration!("openrouter:first", %{
          "provider" => "openrouter",
          "name" => "first",
          "api_key" => "sk-first"
        })

      _second =
        insert_integration!("openrouter:second", %{
          "provider" => "openrouter",
          "name" => "second",
          "api_key" => "sk-second"
        })

      endpoint_uuid = insert_endpoint!("Tied Endpoint", "openrouter")

      run_backfill!()

      # UUIDv7 is time-ordered, so `first` (inserted first → smaller uuid)
      # wins under `uuid ASC`.
      assert endpoint_integration_uuid(endpoint_uuid) == first
    end
  end

  describe "backfill — unresolvable" do
    test "leaves integration_uuid NULL when no integration row matches" do
      endpoint_uuid = insert_endpoint!("Orphan Endpoint", "nonexistent")

      run_backfill!()

      assert endpoint_integration_uuid(endpoint_uuid) == nil
    end
  end
end
