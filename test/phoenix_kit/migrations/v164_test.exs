defmodule PhoenixKit.Migrations.Postgres.V164Test do
  @moduledoc """
  Pins V164's schema state: `idx_publishing_posts_group_slug` is partial
  (`WHERE (slug IS NOT NULL)`), and the subscription slug index carries
  the `types` name — never the stale `plans` name V65's own bare
  `ALTER INDEX ... RENAME TO` left behind on a named-schema install.

  V164.up/down can't be invoked outside an `Ecto.Migrator` runner (they
  rely on `Ecto.Migration.execute/1`, which checks for a runner process)
  — same constraint as V163Test/V162Test/etc. The schema is verified at
  boot instead: `test_helper.exs` runs `ensure_current/2` (now through
  V164) before any test, so the assertions below pin the post-V164 shape.
  This suite runs against the default (`public`) schema, where V164 is a
  no-op on top of an already-correct `V135` baseline in a properly
  regenerated chain — the assertions exist to catch a regression in
  either V164 itself or in a future baseline regeneration that
  reintroduces the named-schema shape as the default.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Test.Repo

  defp indexdef(table, index_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT indexdef FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename = $1
          AND indexname = $2
        """,
        [table, index_name]
      )

    case rows do
      [[definition]] -> definition
      [] -> nil
    end
  end

  describe "phoenix_kit_publishing_posts group_uuid/slug uniqueness" do
    test "idx_publishing_posts_group_slug is partial on slug IS NOT NULL" do
      definition = indexdef("phoenix_kit_publishing_posts", "idx_publishing_posts_group_slug")

      assert definition =~ "WHERE (slug IS NOT NULL)"
    end
  end

  describe "phoenix_kit_subscription_types slug uniqueness" do
    test "the slug index carries the types name" do
      assert indexdef(
               "phoenix_kit_subscription_types",
               "phoenix_kit_subscription_types_slug_uidx"
             )
    end

    test "the stale plans-named twin is gone" do
      refute indexdef(
               "phoenix_kit_subscription_types",
               "phoenix_kit_subscription_plans_slug_uidx"
             )
    end
  end

  describe "version marker" do
    test "phoenix_kit table comment is at or past V164" do
      %{rows: [[comment]]} =
        Repo.query!("SELECT obj_description('phoenix_kit'::regclass, 'pg_class')")

      # >= rather than ==: pinning the exact latest version breaks this
      # test every time a newer migration ships. What V164 owns is "the
      # chain reached at least me".
      assert String.to_integer(comment) >= 164
    end
  end
end
