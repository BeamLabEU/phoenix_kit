defmodule PhoenixKit.Migrations.Postgres.V158Test do
  @moduledoc """
  Pins the post-V158 schema shape — the suite's `ensure_current/2` runs
  the full chain (now through V158) before any test, same approach as
  `v155_test.exs`/`v156_test.exs`.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.RepoHelper, as: Repo

  defp column(table, name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, name]
      )

    case rows do
      [[data_type, is_nullable, default]] ->
        %{type: data_type, nullable: is_nullable, default: default}

      [] ->
        nil
    end
  end

  describe "phoenix_kit_newsletters_broadcasts.attachments" do
    test "jsonb, NOT NULL, defaults to an empty array" do
      assert %{type: "jsonb", nullable: "NO", default: default} =
               column("phoenix_kit_newsletters_broadcasts", "attachments")

      assert default =~ "'[]'::jsonb"
    end

    test "the CHECK rejects a non-array value" do
      assert_raise Postgrex.Error, ~r/attachments_is_array/, fn ->
        Repo.query!("""
        INSERT INTO phoenix_kit_newsletters_broadcasts (subject, attachments)
        VALUES ('V158 shape check', '{"not": "an array"}'::jsonb)
        """)
      end
    end

    test "an array of uuids inserts cleanly and round-trips in order" do
      %{rows: [[attachments]]} =
        Repo.query!("""
        INSERT INTO phoenix_kit_newsletters_broadcasts (subject, attachments)
        VALUES ('V158 roundtrip', '["019f0000-0000-7000-8000-000000000001", "019f0000-0000-7000-8000-000000000002"]'::jsonb)
        RETURNING attachments
        """)

      assert attachments == [
               "019f0000-0000-7000-8000-000000000001",
               "019f0000-0000-7000-8000-000000000002"
             ]
    end
  end

  describe "version marker" do
    test "phoenix_kit table comment is at or past V158" do
      %{rows: [[comment]]} =
        Repo.query!("SELECT obj_description('phoenix_kit'::regclass, 'pg_class')")

      assert String.to_integer(comment) >= 158
    end
  end
end
