# PR #998 — Stop repair reporting wrong_shape for a CHECK that only nests its AND differently

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve, no code changes

Read: `Repair.CheckExpression` in full, the `Differ.compare(:constraint, %{type: "c" | "x"})` change,
the unit tests and `real_manifest_shapes_test.exs` additions.

## Checked and sound

- **Only meaning-preserving rewrites.** OR is split before AND (SQL precedence), only same-connective
  chains are spliced (associativity holds under three-valued logic), and parentheses are dropped only
  when they wrap a *whole* AND/OR operand (or the whole text) and hold no top-level comma. Parentheses
  inside a sequence (arithmetic, casts, `NOT (...)`, function arguments, rows) stay as `{:paren, _}`.
  Token order is preserved, so two texts can only compare equal when their tokens match in order.
- **Failure direction is safe.** Anything unparseable (unbalanced parens, unterminated literal, empty
  operand, `E'..'`) is `:error` and equal only to identical text — the pre-PR behaviour. The new code
  can only turn a `:wrong_shape` into `:match`, never the reverse.
- **`CASE` is not understood, harmlessly.** `CASE WHEN a AND b THEN … END` is split at its inner `AND`
  as if it were a connective. I tried to build two *different* valid conditions that canonicalise to
  the same tree through this and could not: the dropped parentheses must still wrap a whole operand,
  and every rewrite the splice allows is an associativity of the same connective. What it does cause is
  a false `wrong_shape` for `CASE WHEN (a AND b)` vs `CASE WHEN a AND b` — the old behaviour, and core's
  manifest has no CHECK with a `CASE`.
- **BETWEEN.** The flag is set only while splitting on `AND` and cleared by the `AND` that ends it;
  `NOT BETWEEN` / `BETWEEN SYMMETRIC` keep their `AND`. (PostgreSQL rewrites `BETWEEN` to `>= AND <=`
  at parse time, so deparsed text rarely has one anyway.)
- **Differ.** `check_equivalent?/2` keeps the existing `normalize_default/1` pass first, and a `nil`
  definition equals only `nil`.
- **Tests.** Both directions are asserted; the refute block covers regrouping AND/OR, arithmetic
  parentheses, `NOT (group)`, comma lists, operand order, literals that spell keywords, and
  unparseable text.

No findings.
