defmodule PhoenixKit.Migrations.Repair.CheckExpressionTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.CheckExpression

  # core's own `phoenix_kit_storage_profiles_copies_check`, as the manifest
  # prints it (a fresh install on PostgreSQL 17.5) ...
  @copies_fresh "CHECK ((((copies_originals >= 1) AND (copies_originals <= 5)) AND " <>
                  "((copies_variants >= 1) AND (copies_variants <= 5)) AND " <>
                  "((min_copies_on_write >= 1) AND (min_copies_on_write <= copies_originals))))"

  # ... and as a database whose constraint was parsed with the first BETWEEN
  # folded into the outer AND prints the same condition.
  @copies_folded "CHECK (((copies_originals >= 1) AND (copies_originals <= 5) AND " <>
                   "((copies_variants >= 1) AND (copies_variants <= 5)) AND " <>
                   "((min_copies_on_write >= 1) AND (min_copies_on_write <= copies_originals))))"

  @local_cloud_fresh "CHECK ((((copies_local >= 0) AND (copies_local <= 5)) AND " <>
                       "((copies_cloud >= 0) AND (copies_cloud <= 5)) AND " <>
                       "((copies_local + copies_cloud) = copies_originals)))"

  @local_cloud_folded "CHECK (((copies_local >= 0) AND (copies_local <= 5) AND " <>
                        "((copies_cloud >= 0) AND (copies_cloud <= 5)) AND " <>
                        "((copies_local + copies_cloud) = copies_originals)))"

  describe "same condition, different parentheses" do
    test "the folded and the nested form of core's copies CHECK are equivalent, both ways" do
      assert CheckExpression.equivalent?(@copies_fresh, @copies_folded)
      assert CheckExpression.equivalent?(@copies_folded, @copies_fresh)
    end

    test "the folded and the nested form of core's local/cloud CHECK are equivalent" do
      assert CheckExpression.equivalent?(@local_cloud_fresh, @local_cloud_folded)
    end

    test "an AND operand that is an AND chain is spliced into its parent" do
      assert CheckExpression.equivalent?(
               "CHECK (((a > 0) AND (b > 0)) AND (c > 0))",
               "CHECK ((a > 0) AND (b > 0) AND (c > 0))"
             )

      assert CheckExpression.equivalent?(
               "CHECK ((a > 0) AND ((b > 0) AND (c > 0)))",
               "CHECK ((a > 0) AND (b > 0) AND (c > 0))"
             )
    end

    test "the same holds for OR" do
      assert CheckExpression.equivalent?(
               "CHECK (((a > 0) OR (b > 0)) OR (c > 0))",
               "CHECK ((a > 0) OR (b > 0) OR (c > 0))"
             )
    end

    test "parentheses around one whole expression are redundant, at any depth" do
      assert CheckExpression.equivalent?("CHECK (((x > 0)))", "CHECK ((x > 0))")
      assert CheckExpression.equivalent?("CHECK (x > 0)", "CHECK ((x > 0))")
      assert CheckExpression.equivalent?("CHECK ((a > 0) AND (b > 0))", "CHECK (a > 0 AND b > 0)")
    end

    test "whitespace between tokens does not matter" do
      assert CheckExpression.equivalent?("CHECK (x>=1 AND x<=5)", "CHECK ((x >= 1) AND (x <= 5))")
      assert CheckExpression.equivalent?("CHECK (x  >  0)", "CHECK (x > 0)")
    end

    test "AND binds tighter than OR, so dropping those parentheses changes nothing" do
      assert CheckExpression.equivalent?(
               "CHECK ((a > 0) OR ((b > 0) AND (c > 0)))",
               "CHECK (a > 0 OR b > 0 AND c > 0)"
             )
    end

    test "the AND of a BETWEEN is not a connective" do
      assert CheckExpression.equivalent?(
               "CHECK ((x BETWEEN 1 AND 5) AND (y > 0))",
               "CHECK (x BETWEEN 1 AND 5 AND y > 0)"
             )
    end

    test "keywords compare without regard to case" do
      assert CheckExpression.equivalent?(
               "CHECK ((a > 0) and (b > 0))",
               "CHECK ((a > 0) AND (b > 0))"
             )
    end
  end

  describe "more of the same condition" do
    test "NOT binds tighter than AND" do
      assert CheckExpression.equivalent?(
               "CHECK (NOT a > 0 AND b > 0)",
               "CHECK ((NOT a > 0) AND (b > 0))"
             )
    end

    test "NOT BETWEEN, BETWEEN inside OR and BETWEEN SYMMETRIC keep their AND" do
      assert CheckExpression.equivalent?(
               "CHECK (x NOT BETWEEN 1 AND 5 AND y > 0)",
               "CHECK ((x NOT BETWEEN 1 AND 5) AND (y > 0))"
             )

      assert CheckExpression.equivalent?(
               "CHECK (x BETWEEN 1 AND 5 OR y > 0)",
               "CHECK ((x BETWEEN 1 AND 5) OR (y > 0))"
             )

      assert CheckExpression.equivalent?(
               "CHECK (x BETWEEN SYMMETRIC 5 AND 1 AND y > 0)",
               "CHECK ((x BETWEEN SYMMETRIC 5 AND 1) AND (y > 0))"
             )
    end

    test "a comma list keeps its own commas" do
      assert CheckExpression.equivalent?(
               "CHECK (x IN (1, 2) AND y > 0)",
               "CHECK ((x IN (1, 2)) AND (y > 0))"
             )

      assert CheckExpression.equivalent?(
               "CHECK (((x = ANY (ARRAY[1, 2]))))",
               "CHECK (x = ANY (ARRAY[1, 2]))"
             )

      assert CheckExpression.equivalent?(
               "CHECK (x = ((ARRAY[1, 2])))",
               "CHECK (x = (ARRAY[1, 2]))"
             )
    end

    test "casts and the operators of jsonb and arrays" do
      assert CheckExpression.equivalent?(
               "CHECK ((x)::text = 'a'::text)",
               "CHECK (((x)::text = 'a'::text))"
             )

      assert CheckExpression.equivalent?("CHECK (a ?| b)", "CHECK ((a ?| b))")
    end

    test "a quoted identifier is one token, whatever it spells" do
      assert CheckExpression.equivalent?(
               ~s|CHECK ("a(b" > 0 AND "x AND y" > 0)|,
               ~s|CHECK (("a(b" > 0) AND ("x AND y" > 0))|
             )
    end
  end

  describe "different condition" do
    test "a changed bound is not equivalent" do
      changed = String.replace(@copies_folded, "copies_originals <= 5", "copies_originals <= 6")

      refute CheckExpression.equivalent?(@copies_fresh, changed)
      refute CheckExpression.equivalent?(changed, @copies_fresh)
    end

    test "a dropped operand is not equivalent" do
      dropped =
        "CHECK (((copies_originals >= 1) AND (copies_originals <= 5) AND " <>
          "((copies_variants >= 1) AND (copies_variants <= 5))))"

      refute CheckExpression.equivalent?(@copies_fresh, dropped)
    end

    test "AND is not OR" do
      refute CheckExpression.equivalent?(
               "CHECK ((a > 0) AND (b > 0))",
               "CHECK ((a > 0) OR (b > 0))"
             )
    end

    test "regrouping AND and OR is not equivalent" do
      refute CheckExpression.equivalent?(
               "CHECK (((a > 0) OR (b > 0)) AND (c > 0))",
               "CHECK ((a > 0) OR ((b > 0) AND (c > 0)))"
             )
    end

    test "parentheses that change the value of an arithmetic expression are kept" do
      refute CheckExpression.equivalent?(
               "CHECK ((a - (b - c)) > 0)",
               "CHECK (((a - b) - c) > 0)"
             )
    end

    test "a negated group is not the group" do
      refute CheckExpression.equivalent?(
               "CHECK (NOT ((a > 0) AND (b > 0)))",
               "CHECK ((a > 0) AND (b > 0))"
             )
    end

    test "a different operator, column or constant is not equivalent" do
      refute CheckExpression.equivalent?("CHECK (x > 0)", "CHECK (x >= 0)")
      refute CheckExpression.equivalent?("CHECK (x > 0)", "CHECK (y > 0)")
      refute CheckExpression.equivalent?("CHECK (x > 0)", "CHECK (x > 1)")
    end

    test "operand order is kept" do
      refute CheckExpression.equivalent?(
               "CHECK ((a > 0) AND (b > 0))",
               "CHECK ((b > 0) AND (a > 0))"
             )
    end

    test "a string literal is compared whole, even when it spells a keyword or a parenthesis" do
      assert CheckExpression.equivalent?(
               "CHECK ((kind)::text = 'a AND (b'::text)",
               "CHECK (((kind)::text = 'a AND (b'::text))"
             )

      refute CheckExpression.equivalent?(
               "CHECK ((kind)::text = 'a AND (b'::text)",
               "CHECK ((kind)::text = 'a AND (c'::text)"
             )

      refute CheckExpression.equivalent?(
               "CHECK ((kind)::text = 'x'::text)",
               "CHECK ((kind)::text = 'X'::text)"
             )
    end

    test "a doubled quote stays inside its literal" do
      assert CheckExpression.equivalent?(
               "CHECK ((note)::text <> 'it''s (fine'::text)",
               "CHECK (((note)::text <> 'it''s (fine'::text))"
             )
    end
  end

  describe "more different conditions" do
    test "NOT applies to the whole group it is written in front of" do
      refute CheckExpression.equivalent?(
               "CHECK (NOT a > 0 AND b > 0)",
               "CHECK (NOT (a > 0 AND b > 0))"
             )
    end

    test "parentheses around a comma list are not redundant" do
      refute CheckExpression.equivalent?("CHECK (f((a, b)) > 0)", "CHECK (f(a, b) > 0)")
      refute CheckExpression.equivalent?("CHECK (x IN ((1, 2)))", "CHECK (x IN (1, 2))")
    end

    test "a cast to another type, a different operator, a different quoted identifier" do
      refute CheckExpression.equivalent?("CHECK (x::text = 'a')", "CHECK (x::int = 'a')")
      refute CheckExpression.equivalent?("CHECK (a ?| b)", "CHECK (a ?& b)")

      refute CheckExpression.equivalent?(
               ~s|CHECK ("x AND y" > 0)|,
               ~s|CHECK ("x AND z" > 0)|
             )
    end
  end

  describe "text it cannot parse" do
    test "is equivalent only to itself" do
      assert CheckExpression.equivalent?("CHECK ((a > 0)", "CHECK ((a > 0)")
      refute CheckExpression.equivalent?("CHECK ((a > 0)", "CHECK (a > 0)")
      refute CheckExpression.equivalent?("CHECK (a > 0))", "CHECK (a > 0)")
      refute CheckExpression.equivalent?("CHECK (a = 'x)", "CHECK (a = 'x')")
    end

    test "an empty operand or an empty text is not a condition" do
      assert CheckExpression.canonical("") == :error
      assert CheckExpression.canonical("AND") == :error
      refute CheckExpression.equivalent?("", "()")
      refute CheckExpression.equivalent?("CHECK (a > 0 AND)", "CHECK (a > 0 AND ())")
      refute CheckExpression.equivalent?("CHECK (f(()))", "CHECK (f())")
    end

    test "an E'..' string, whose backslashes are escapes, is not compared by tokens" do
      escaped = "CHECK (a = E'\\' x \\' y')"
      spaced = "CHECK (a = E'\\'  x \\' y')"

      assert CheckExpression.canonical(escaped) == :error
      assert CheckExpression.equivalent?(escaped, escaped)
      refute CheckExpression.equivalent?(escaped, spaced)
    end

    test "never raises, whatever it is given" do
      for text <- [
            ")",
            "(",
            "'",
            "\"",
            "AND",
            "OR",
            "NOT",
            "BETWEEN",
            "a AND",
            "AND a",
            "a OR OR b",
            "((",
            "))",
            "[",
            "]",
            "::",
            <<255>>,
            <<0>>
          ] do
        assert CheckExpression.canonical(text) == :error or
                 match?({:ok, _}, CheckExpression.canonical(text))

        assert is_boolean(CheckExpression.equivalent?(text, text))
      end
    end

    test "canonical/1 reports it" do
      assert CheckExpression.canonical("CHECK ((a > 0)") == :error
      assert {:ok, _tree} = CheckExpression.canonical("CHECK (a > 0)")
    end
  end
end
