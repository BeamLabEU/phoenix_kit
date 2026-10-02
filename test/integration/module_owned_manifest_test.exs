defmodule PhoenixKit.Integration.ModuleOwnedManifestTest do
  @moduledoc """
  An object the core chain creates but a module owns is not in core's
  `ExpectedSchema` manifest, so `mix phoenix_kit.doctor`/`repair` neither
  check its shape nor put it back.

  The case: V135 creates `fk_newsletters_broadcasts_template`
  (`template_uuid` → `phoenix_kit_email_templates`), and the newsletters
  module repoints it, under the same name, at a table of its own. While core's
  manifest described the FK, every install that had done so was reported as
  `:wrong_shape`. These tests make that change inside the sandbox transaction
  and read the database the way the repair engine does (`Probe` + `Differ`).
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  @table "phoenix_kit_newsletters_broadcasts"
  @fk "fk_newsletters_broadcasts_template"
  @id "constraint:#{@table}.#{@fk}"
  @check {:catalog, %{kind: :constraint, table: @table, name: @fk}}

  test "the manifest does not describe the FK, under its id or its name" do
    objects = ExpectedSchema.objects("public")

    refute Enum.any?(objects, &(&1.id == @id))
    refute Enum.any?(objects, &match?(%{check: {:catalog, %{name: @fk}}}, &1))
  end

  test "the chain still creates it, pointing at the email templates table" do
    assert %{type: "f", foreign_table: "phoenix_kit_email_templates"} =
             Probe.lookup(Probe.snapshot(Repo, "public"), @check)
  end

  test "repointed at a module's own table, nothing on the broadcasts table is drift" do
    Repo.query!("CREATE TABLE public.phoenix_kit_newsletters_layouts (uuid uuid PRIMARY KEY)")
    Repo.query!("ALTER TABLE public.#{@table} DROP CONSTRAINT #{@fk}")

    Repo.query!("""
    ALTER TABLE public.#{@table} ADD CONSTRAINT #{@fk}
      FOREIGN KEY (template_uuid) REFERENCES public.phoenix_kit_newsletters_layouts(uuid)
      ON DELETE SET NULL
    """)

    snapshot = Probe.snapshot(Repo, "public")

    assert %{foreign_table: "phoenix_kit_newsletters_layouts"} = Probe.lookup(snapshot, @check)

    objects =
      for %{presence: :required} = object <- ExpectedSchema.objects("public"),
          on_table?(object),
          do: object

    # The table, its columns, its other constraints and indexes are still
    # core's and still checked.
    assert Enum.any?(objects, &(&1.class == :constraint))
    assert Enum.any?(objects, &(&1.class == :column))

    problems =
      for object <- objects,
          problem = problem(object, Probe.lookup(snapshot, object.check)),
          do: {object.id, problem}

    assert problems == []
  end

  defp on_table?(%{check: {:catalog, %{kind: :table, name: @table}}}), do: true
  defp on_table?(%{check: {:catalog, %{table: @table}}}), do: true
  defp on_table?(%{class: :index} = object), do: newest_shape(object).table == @table
  defp on_table?(_object), do: false

  defp newest_shape(%{revisions: revisions}) do
    {_version, shape} = Enum.max_by(revisions, fn {version, _} -> version end)
    shape
  end

  defp problem(_object, nil), do: :missing

  defp problem(object, observed) do
    case Differ.compare(object.class, newest_shape(object), observed) do
      :match ->
        nil

      {:mismatch, _} = mismatch ->
        if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
    end
  end
end
