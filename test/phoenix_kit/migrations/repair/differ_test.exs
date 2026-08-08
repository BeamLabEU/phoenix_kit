defmodule PhoenixKit.Migrations.Repair.DifferTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.Differ

  describe "presence-only classes (:table/:extension/:seed) always :match" do
    test "table" do
      assert Differ.compare(:table, %{}, %{}) == :match
    end

    test "extension" do
      assert Differ.compare(:extension, %{}, %{}) == :match
    end

    test "seed — deliberately never compares values (operator-tuned rows must not be flagged)" do
      expected = %{key_column: "key", key_value: "time_zone", values: %{"value" => "0"}}

      observed = %{
        key_column: "key",
        key_value: "time_zone",
        values: %{"value" => "operator edited this"}
      }

      assert Differ.compare(:seed, expected, observed) == :match
    end
  end

  describe "column" do
    test "identical shapes match" do
      shape = %{type: "uuid", not_null: true, default: "public.uuid_generate_v7()"}
      assert Differ.compare(:column, shape, shape) == :match
    end

    test "type mismatch is reported" do
      expected = %{type: "character varying(50)", not_null: false, default: nil}
      observed = %{type: "character varying(120)", not_null: false, default: nil}

      assert {:mismatch, reasons} = Differ.compare(:column, expected, observed)
      assert Enum.any?(reasons, &(&1 =~ "type"))
    end

    test "not_null mismatch is reported" do
      expected = %{type: "text", not_null: true, default: "''"}
      observed = %{type: "text", not_null: false, default: "''"}

      assert {:mismatch, reasons} = Differ.compare(:column, expected, observed)
      assert Enum.any?(reasons, &(&1 =~ "not_null"))
    end

    test "default mismatch is reported, whitespace-normalized first" do
      expected = %{type: "text", not_null: false, default: "'a'"}
      observed = %{type: "text", not_null: false, default: "  'a'  "}
      assert Differ.compare(:column, expected, observed) == :match

      observed2 = %{type: "text", not_null: false, default: "'b'"}
      assert {:mismatch, reasons} = Differ.compare(:column, expected, observed2)
      assert Enum.any?(reasons, &(&1 =~ "default"))
    end

    test "pos is never compared (ordinal position is accidental)" do
      expected = %{type: "text", not_null: false, default: nil, pos: 3}
      observed = %{type: "text", not_null: false, default: nil, pos: 9}
      assert Differ.compare(:column, expected, observed) == :match
    end

    test "not_null is never compared when expected has no default — repair's own create can " <>
           "never satisfy it (spec D7), so it can never verify clean otherwise" do
      expected = %{type: "text", not_null: true, default: nil}
      observed = %{type: "text", not_null: false, default: nil}
      assert Differ.compare(:column, expected, observed) == :match

      # A genuinely different type is still reported — the not_null carve-out
      # does not swallow other real divergences on the same column.
      observed2 = %{type: "boolean", not_null: false, default: nil}
      assert {:mismatch, reasons} = Differ.compare(:column, expected, observed2)
      assert Enum.any?(reasons, &(&1 =~ "type"))
      refute Enum.any?(reasons, &(&1 =~ "not_null"))
    end
  end

  describe "sequence — every field is declaration metadata, all compared" do
    @shape %{
      data_type: "bigint",
      start: 1,
      increment: 1,
      min: 1,
      max: 9_223_372_036_854_775_807,
      cache: 1,
      cycle: false
    }

    test "identical matches" do
      assert Differ.compare(:sequence, @shape, @shape) == :match
    end

    test "cycle mismatch is reported" do
      observed = %{@shape | cycle: true}
      assert {:mismatch, reasons} = Differ.compare(:sequence, @shape, observed)
      assert Enum.any?(reasons, &(&1 =~ "cycle"))
    end

    test "start mismatch is reported (declared start, unaffected by nextval() calls)" do
      observed = %{@shape | start: 100}
      assert {:mismatch, reasons} = Differ.compare(:sequence, @shape, observed)
      assert Enum.any?(reasons, &(&1 =~ "start"))
    end
  end

  describe "function — returns/language/body_md5 only, never raw definition text" do
    test "identical matches" do
      shape = %{returns: "uuid", language: "plpgsql", body_md5: "abc", definition: "text A"}
      assert Differ.compare(:function, shape, shape) == :match
    end

    test "definition text differing alone (e.g. cosmetic PG-major deparse differences) is NOT a mismatch" do
      expected = %{returns: "uuid", language: "plpgsql", body_md5: "abc", definition: "text A"}

      observed = %{
        returns: "uuid",
        language: "plpgsql",
        body_md5: "abc",
        definition: "TEXT A (reformatted)"
      }

      assert Differ.compare(:function, expected, observed) == :match
    end

    test "body_md5 mismatch IS reported (the body actually changed)" do
      expected = %{returns: "uuid", language: "plpgsql", body_md5: "abc", definition: "text A"}
      observed = %{returns: "uuid", language: "plpgsql", body_md5: "xyz", definition: "text A"}
      assert {:mismatch, reasons} = Differ.compare(:function, expected, observed)
      assert Enum.any?(reasons, &(&1 =~ "body_md5"))
    end
  end

  describe "index — structural fields primary, predicate/definition secondary" do
    @shape %{
      table: "widgets",
      unique: false,
      method: "btree",
      definition: "CREATE INDEX x ON public.widgets USING btree (owner_uuid)",
      predicate: nil,
      keys: ["owner_uuid"],
      opclasses: ["uuid_ops"]
    }

    test "identical matches" do
      assert Differ.compare(:index, @shape, @shape) == :match
    end

    test "unique mismatch is reported" do
      observed = %{@shape | unique: true}
      assert {:mismatch, reasons} = Differ.compare(:index, @shape, observed)
      assert Enum.any?(reasons, &(&1 =~ "unique"))
    end

    test "keys mismatch is reported" do
      observed = %{@shape | keys: ["different_column"]}
      assert {:mismatch, reasons} = Differ.compare(:index, @shape, observed)
      assert Enum.any?(reasons, &(&1 =~ "keys"))
    end

    test "predicate mismatch is still :error-severity reported (no softer tier invented)" do
      observed = %{@shape | predicate: "some_column IS NOT NULL"}
      assert {:mismatch, reasons} = Differ.compare(:index, @shape, observed)
      assert Enum.any?(reasons, &(&1 =~ "predicate"))
    end
  end

  describe "constraint — dispatches on type" do
    test "foreign key ('f'): columns/foreign_table/foreign_columns/on_delete/on_update, never definition" do
      expected = %{
        type: "f",
        definition: "FOREIGN KEY (owner_uuid) REFERENCES public.owners(uuid) ON DELETE SET NULL",
        columns: ["owner_uuid"],
        foreign_table: "owners",
        foreign_columns: ["uuid"],
        on_delete: "n",
        on_update: "a"
      }

      assert Differ.compare(:constraint, expected, expected) == :match

      observed = %{expected | on_delete: "c", definition: "totally different rendering"}
      assert {:mismatch, reasons} = Differ.compare(:constraint, expected, observed)
      assert Enum.any?(reasons, &(&1 =~ "on_delete"))
      refute Enum.any?(reasons, &(&1 =~ "definition"))
    end

    test "primary key ('p') and unique ('u'): columns only" do
      expected = %{type: "p", definition: "PRIMARY KEY (uuid)", columns: ["uuid"]}
      assert Differ.compare(:constraint, expected, expected) == :match

      observed = %{expected | columns: ["id"]}
      assert {:mismatch, reasons} = Differ.compare(:constraint, expected, observed)
      assert Enum.any?(reasons, &(&1 =~ "columns"))

      expected_u = %{type: "u", definition: "UNIQUE (slug)", columns: ["slug"]}
      assert Differ.compare(:constraint, expected_u, expected_u) == :match
    end

    test "check ('c') and exclusion ('x'): no decomposition available, falls back to definition text" do
      expected = %{type: "c", definition: "CHECK (status IN ('active','inactive'))"}
      assert Differ.compare(:constraint, expected, expected) == :match

      observed = %{expected | definition: "CHECK (status IN ('active','inactive','archived'))"}
      assert {:mismatch, reasons} = Differ.compare(:constraint, expected, observed)
      assert Enum.any?(reasons, &(&1 =~ "definition"))

      expected_x = %{type: "x", definition: "EXCLUDE USING gist (range WITH &&)"}
      assert Differ.compare(:constraint, expected_x, expected_x) == :match
    end

    test "check definition whitespace differences alone do not manufacture a mismatch" do
      expected = %{type: "c", definition: "CHECK (x > 0)"}
      observed = %{type: "c", definition: "  CHECK (x > 0)  "}
      assert Differ.compare(:constraint, expected, observed) == :match
    end

    test "check: element-wise vs array-wise ANY(ARRAY[...]) deparse forms do not manufacture a mismatch" do
      element_wise =
        "CHECK (((kind)::text = ANY (ARRAY[('standard'::character varying)::text, " <>
          "('smart'::character varying)::text])))"

      array_wise =
        "CHECK (((kind)::text = ANY ((ARRAY['standard'::character varying, " <>
          "'smart'::character varying])::text[])))"

      expected = %{type: "c", definition: element_wise}
      observed = %{type: "c", definition: array_wise}

      assert Differ.compare(:constraint, expected, observed) == :match
      # Symmetric: whichever side has which form, both fold to the same shape.
      assert Differ.compare(:constraint, observed, expected) == :match

      # A genuine value-set change must still be caught through either form.
      changed = %{
        type: "c",
        definition:
          "CHECK (((kind)::text = ANY ((ARRAY['standard'::character varying, " <>
            "'smart'::character varying, 'extra'::character varying])::text[])))"
      }

      assert {:mismatch, reasons} = Differ.compare(:constraint, expected, changed)
      assert Enum.any?(reasons, &(&1 =~ "definition"))
    end
  end
end
