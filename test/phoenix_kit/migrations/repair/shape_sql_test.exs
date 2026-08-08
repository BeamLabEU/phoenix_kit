defmodule PhoenixKit.Migrations.Repair.ShapeSqlTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.ShapeSql

  describe "column_create/4" do
    test "no default, not_null: false → bare ADD COLUMN" do
      shape = %{type: "character varying(50)", not_null: false, default: nil}

      assert ShapeSql.column_create("public", "phoenix_kit_widgets", "name", shape) ==
               ~s|ALTER TABLE public.phoenix_kit_widgets ADD COLUMN IF NOT EXISTS "name" character varying(50)|
    end

    test "default present, not_null: false → DEFAULT only, no NOT NULL" do
      shape = %{type: "boolean", not_null: false, default: "false"}

      assert ShapeSql.column_create("public", "t", "flag", shape) ==
               ~s(ALTER TABLE public.t ADD COLUMN IF NOT EXISTS "flag" boolean DEFAULT false)
    end

    test "not_null: true WITHOUT a default never emits NOT NULL (the asymmetry Object documents)" do
      shape = %{type: "character varying(50)", not_null: true, default: nil}

      refute ShapeSql.column_create("public", "t", "name", shape) =~ "NOT NULL"
    end

    test "not_null: true WITH a default emits both, DEFAULT before NOT NULL" do
      shape = %{type: "uuid", not_null: true, default: "public.uuid_generate_v7()"}

      assert ShapeSql.column_create("public", "phoenix_kit_widgets", "uuid", shape) ==
               ~s|ALTER TABLE public.phoenix_kit_widgets ADD COLUMN IF NOT EXISTS "uuid" uuid DEFAULT public.uuid_generate_v7() NOT NULL|
    end

    test "prefix is interpolated as the schema, not the token" do
      shape = %{type: "text", not_null: false, default: nil}
      sql = ShapeSql.column_create("auth", "phoenix_kit_settings", "value", shape)

      assert sql =~ "ALTER TABLE auth.phoenix_kit_settings"
      refute sql =~ "__SCHEMA__"
    end
  end

  describe "index_create/1" do
    test "CREATE INDEX gets IF NOT EXISTS inserted, name stays bare" do
      shape = %{definition: "CREATE INDEX my_idx ON public.widgets USING btree (owner_uuid)"}

      assert ShapeSql.index_create(shape) ==
               "CREATE INDEX IF NOT EXISTS my_idx ON public.widgets USING btree (owner_uuid)"
    end

    test "CREATE UNIQUE INDEX gets IF NOT EXISTS inserted after UNIQUE" do
      shape = %{definition: "CREATE UNIQUE INDEX my_uidx ON public.widgets USING btree (slug)"}

      assert ShapeSql.index_create(shape) ==
               "CREATE UNIQUE INDEX IF NOT EXISTS my_uidx ON public.widgets USING btree (slug)"
    end

    test "an unrecognized definition shape raises loudly instead of emitting bad SQL" do
      assert_raise ArgumentError, ~r/unexpected index definition/, fn ->
        ShapeSql.index_create(%{definition: "DROP INDEX my_idx"})
      end
    end
  end

  describe "constraint_create/5" do
    test "the guard is name-anchored (conname + relname + nspname), never a regclass cast" do
      sql =
        ShapeSql.constraint_create("public", "widgets", "widgets_pkey", %{
          definition: "PRIMARY KEY (uuid)"
        })

      assert sql =~ "c.conname = 'widgets_pkey'"
      assert sql =~ "t.relname = 'widgets'"
      assert sql =~ "n.nspname = 'public'"
      refute sql =~ "::regclass"
    end

    test "the guarded ADD CONSTRAINT statement embeds the definition verbatim" do
      sql =
        ShapeSql.constraint_create("public", "widgets", "widgets_pkey", %{
          definition: "PRIMARY KEY (uuid)"
        })

      assert sql =~ "ADD CONSTRAINT widgets_pkey PRIMARY KEY (uuid);"
    end

    test "not_valid: true appends NOT VALID to the ADD, not the guard" do
      sql =
        ShapeSql.constraint_create(
          "public",
          "widgets",
          "widgets_owner_uuid_fkey",
          %{definition: "FOREIGN KEY (owner_uuid) REFERENCES public.owners(uuid)"},
          not_valid: true
        )

      assert sql =~
               "ADD CONSTRAINT widgets_owner_uuid_fkey FOREIGN KEY (owner_uuid) REFERENCES public.owners(uuid) NOT VALID;"
    end

    test "not_valid defaults to false (no suffix)" do
      sql =
        ShapeSql.constraint_create("public", "widgets", "widgets_pkey", %{
          definition: "PRIMARY KEY (uuid)"
        })

      refute sql =~ "NOT VALID"
    end
  end

  describe "validate_constraint/3" do
    test "renders the exact VALIDATE CONSTRAINT statement" do
      assert ShapeSql.validate_constraint("public", "widgets", "widgets_owner_uuid_fkey") ==
               "ALTER TABLE public.widgets VALIDATE CONSTRAINT widgets_owner_uuid_fkey"
    end
  end

  doctest ShapeSql
end
