defmodule PhoenixKit.Integration.ModuleOwnedManifestTest do
  @moduledoc """
  An object the core chain creates but a module owns is not in core's
  `ExpectedSchema` manifest, so `mix phoenix_kit.doctor`/`repair` neither
  check its shape nor put it back.

  The case: V135 creates `fk_newsletters_broadcasts_template`
  (`template_uuid` → `phoenix_kit_email_templates`), and the newsletters
  module repoints it, under the same name, at a table of its own. While core's
  manifest described the FK, `verify` reported such an install as
  `:wrong_shape`, and on an install where the FK was gone `repair` re-created
  it pointing at the email templates table.

  Each test puts the FK in one state inside the sandbox transaction (which
  rolls every change back) and runs the real `Repair.verify/1` or
  `Repair.repair/1` against the suite's migrated database. Only findings about
  the broadcasts table are asserted: the shared test database may carry
  unrelated drift left by other packages' runs.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Test.Repo

  @table "phoenix_kit_newsletters_broadcasts"
  @fk "fk_newsletters_broadcasts_template"
  @id "constraint:#{@table}.#{@fk}"

  test "the manifest does not describe the FK, under its id or its name" do
    objects = ExpectedSchema.objects("public")

    refute Enum.any?(objects, &(&1.id == @id))
    refute Enum.any?(objects, &match?(%{check: {:catalog, %{name: @fk}}}, &1))
  end

  test "(a) as the chain creates it: verify says nothing about it" do
    assert fk_target() == "phoenix_kit_email_templates"

    assert table_findings(verify()) == []
  end

  test "(b) repointed at a module's own table: verify says nothing about it" do
    Repo.query!("CREATE TABLE public.phoenix_kit_newsletters_layouts (uuid uuid PRIMARY KEY)")
    Repo.query!("ALTER TABLE public.#{@table} DROP CONSTRAINT #{@fk}")

    Repo.query!("""
    ALTER TABLE public.#{@table} ADD CONSTRAINT #{@fk}
      FOREIGN KEY (template_uuid) REFERENCES public.phoenix_kit_newsletters_layouts(uuid)
      ON DELETE SET NULL
    """)

    assert fk_target() == "phoenix_kit_newsletters_layouts"
    assert table_findings(verify()) == []
  end

  test "(c) gone: verify says nothing, and repair does not put it back" do
    Repo.query!("ALTER TABLE public.#{@table} DROP CONSTRAINT #{@fk}")

    assert table_findings(verify()) == []

    assert {:ok, report} = Repair.repair(repo: Repo, prefix: "public")
    assert table_findings(report) == []
    assert fk_target() == nil
  end

  test "the rest of the broadcasts table is still core's: a dropped FK is repaired" do
    other = "fk_newsletters_broadcasts_created_by"
    other_id = "constraint:#{@table}.#{other}"
    Repo.query!("ALTER TABLE public.#{@table} DROP CONSTRAINT #{@fk}")
    Repo.query!("ALTER TABLE public.#{@table} DROP CONSTRAINT #{other}")

    assert [%{kind: :missing, object_id: ^other_id}] =
             table_findings(verify())

    assert {:ok, report} = Repair.repair(repo: Repo, prefix: "public")

    assert [%{kind: :repaired, object_id: ^other_id}] =
             table_findings(report)

    assert constraint_exists?(other)
    assert fk_target() == nil
  end

  defp verify do
    assert {:ok, report} = Repair.verify(repo: Repo, prefix: "public")
    report
  end

  # Findings about the broadcasts table or the FK, whatever their severity.
  defp table_findings(report) do
    Enum.filter(report.findings, fn finding ->
      id = finding.object_id || ""
      String.contains?(id, @table) or String.contains?(id, @fk)
    end)
  end

  defp fk_target do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT f.relname
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_class f ON f.oid = c.confrelid
        WHERE c.conname = $1 AND t.relname = $2 AND n.nspname = 'public'
        """,
        [@fk, @table]
      )

    case rows do
      [[target]] -> target
      [] -> nil
    end
  end

  defp constraint_exists?(name) do
    %{rows: [[exists]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = $1)",
        [name]
      )

    exists
  end
end
