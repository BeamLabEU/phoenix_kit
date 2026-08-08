defmodule PhoenixKit.Migrations.Repair.Differ do
  @moduledoc """
  Structural shape comparison — spec §6.2's "divergence detection is
  structural, not deparse-text". Pure: takes an *expected* shape (from
  `PhoenixKit.Migrations.ExpectedSchema.Object.shape_at/2`, already selected
  for the right comment/revision by `PhoenixKit.Migrations.Repair.Scope`) and
  an *observed* shape (fetched from the target server by
  `PhoenixKit.Migrations.Repair.Probe`), and reports whether — and how — they
  differ.

  ## Which fields are compared, and why

  Per class, only the fields that decompose the underlying catalog fact
  structurally are compared; raw `pg_get_*def`/`definition` text is used only
  where nothing else exists (spec: "raw-text equality only where no
  structural decomposition exists"):

    * `:column` — `type`, `not_null`, `default` (all three already
      `pg_get_expr`/`format_type`-normalized *by the querying server* on
      both sides — the expected shape by the generation server at manifest
      build time, the observed shape by the target server at verify time;
      §6.3's version preflight bounds how far apart those two are allowed to
      be). `pos` is deliberately excluded — column ordinal position is
      accidental (`ADD COLUMN` always appends), never a divergence worth
      reporting. `not_null` is *conditionally* excluded too: when the
      expected shape is `not_null: true` with `default: nil`,
      `PhoenixKit.Migrations.Repair.Executor`'s own additive-only create
      deliberately omits `NOT NULL` (adding one with no default to a
      possibly-populated table fails outright — spec D7/§6.2), so a column
      repair itself just recreated from nothing is *permanently* nullable by
      the engine's own design. Comparing `not_null` there would manufacture
      an error-severity finding no `mix phoenix_kit.repair` run can ever
      clear — including blocking `--adopt`'s clean gate on a floor slice
      that otherwise legitimately converged — out of the one outcome the
      additive-only contract already accepts as the best it can safely do.
      Any *other* expected shape (nullable, or not_null with a real default)
      still compares `not_null` normally.
    * `:sequence` — every field (`data_type`/`start`/`increment`/`min`/
      `max`/`cache`/`cycle`) is schema-declaration metadata, not
      runtime state (`seqstart` is the *declared* start, not `last_value` —
      unaffected by how many times `nextval()` has run).
    * `:function` — `returns`, `language`, `body_md5` (an md5 of `prosrc`
      alone — a meaningful fingerprint, not raw deparse text). `definition`
      (full `pg_get_functiondef`) is excluded — it is exactly the kind of
      text spec §6.2 warns rendering can differ on across PG majors.
    * `:index` — `unique`, `method`, `keys`, `opclasses` structurally;
      `predicate`/`definition` only as a **secondary**, lower-confidence
      signal folded into the same mismatch (still `:error` severity per
      spec's explicit list — this module does not invent a softer tier for
      it, it only labels *which* fields disagreed so an operator can judge a
      cross-major artifact for themselves). `NULLS NOT DISTINCT` (PG15+) has
      no structured field of its own; no version in the chain declares it, and
      until one does it is covered by `definition`, which `pg_get_indexdef`
      renders it into. A version that starts using it should promote it to a
      structured field rather than rely on that text comparison.
    * `:constraint` — dispatches on `type` (`pg_constraint.contype`):
      `"f"` (foreign key) compares `columns`/`foreign_table`/
      `foreign_columns`/`on_delete`/`on_update` — all decomposed,
      never `definition`; `"p"`/`"u"` (primary key/unique) compare
      `columns`; `"c"` (check) and `"x"` (exclusion) have no further
      decomposition available in the catalog snapshot and fall back to
      `definition` text (spec's explicit exception for this exact case).
    * `:table`/`:extension` — no shape to diff (existence is the whole
      story; `Object.shape/0` is `%{}` for both) — `compare/3` always
      returns `:match`.
    * `:seed` — **presence-only, deliberately** — `compare/3` always returns
      `:match`. Spec §6.2 lists `:missing`+creatable, wrong column shapes,
      divergent indexes/constraints, `:create_failed`, and failed data
      invariants as the reportable categories; a seed row's *values* are
      never one of them, and for good reason — spec §5.1/§6.2's seed policy
      is "strict `DO NOTHING` (never clobber operator-tuned values)", so an
      admin who edited a seeded setting after install has produced exactly
      the state repair must leave alone, not something to flag as drift.
      Only presence is ever checked (`PhoenixKit.Migrations.Repair.Probe`
      executes the object's `check` — a `SELECT EXISTS (...)` on the
      business key — directly; there is no "observed shape" fetch for
      seeds at all, so this clause never actually receives divergent
      `values` to compare in practice).

  `compare/3` never looks at `:missing` (`observed == nil`) — that is a
  presence question the caller (`PhoenixKit.Migrations.Repair`) answers
  before ever calling here; `compare/3` assumes both shapes are non-nil.
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Object

  @typedoc "`:match`, or a mismatch with the field names that disagreed."
  @type result :: :match | {:mismatch, [String.t()]}

  # Prefix stamped on reasons that compare pg_get_*def RENDERING rather than a
  # structural catalog field. Two Postgres majors can render one identical
  # expression differently (operator-precedence parenthesisation, array-cast
  # placement, whitespace inside predicates), so a marked reason is only
  # trustworthy on a major this release was verified against.
  @deparse_text_marker "~deparse~ "

  @doc "The marker prefix stamped on rendering-derived (not structural) reasons."
  @spec deparse_text_marker() :: String.t()
  def deparse_text_marker, do: @deparse_text_marker

  @doc """
  True when EVERY reason in a mismatch rests on deparse rendering rather than
  a structural field — the case a cross-major server can produce with no real
  drift behind it.
  """
  @spec deparse_text_only?({:mismatch, [String.t()]} | :match) :: boolean()
  def deparse_text_only?({:mismatch, reasons}) when reasons != [],
    do: Enum.all?(reasons, &String.starts_with?(&1, @deparse_text_marker))

  def deparse_text_only?(_), do: false

  @doc """
  Compares `expected` against `observed` for `class`. Field lists in
  `{:mismatch, reasons}` are human-readable, one entry per disagreeing
  aspect — never a raw diff dump — so a report can print them directly.
  """
  @spec compare(Object.class(), expected :: map(), observed :: map()) :: result()
  def compare(:table, _expected, _observed), do: :match
  def compare(:extension, _expected, _observed), do: :match
  def compare(:seed, _expected, _observed), do: :match

  def compare(:column, expected, observed) do
    reasons =
      []
      |> reason_field(:type, expected, observed)
      |> reason_not_null(expected, observed)
      |> reason_if(
        normalize_default(expected.default) != normalize_default(observed.default),
        "default: expected #{inspect(expected.default)}, got #{inspect(observed.default)}"
      )

    result(reasons)
  end

  def compare(:sequence, expected, observed) do
    reasons =
      []
      |> reason_field(:data_type, expected, observed)
      |> reason_field(:increment, expected, observed)
      |> reason_field(:min, expected, observed)
      |> reason_field(:max, expected, observed)
      |> reason_field(:cache, expected, observed)
      |> reason_field(:cycle, expected, observed)
      |> reason_field(:start, expected, observed)

    result(reasons)
  end

  def compare(:function, expected, observed) do
    reasons =
      []
      |> reason_field(:returns, expected, observed)
      |> reason_field(:language, expected, observed)
      |> reason_if(
        expected.body_md5 != observed.body_md5,
        "body definition changed (body_md5: expected #{expected.body_md5}, got #{observed.body_md5})"
      )

    result(reasons)
  end

  def compare(:index, expected, observed) do
    reasons =
      []
      |> reason_field(:unique, expected, observed)
      |> reason_field(:method, expected, observed)
      |> reason_field(:keys, expected, observed)
      |> reason_field(:opclasses, expected, observed)
      |> reason_if(
        normalize_default(expected.predicate) != normalize_default(observed.predicate),
        # @deparse_text_marker: this reason rests on pg_get_expr's RENDERING,
        # not on a structural field, so a different Postgres major can
        # re-render an identical predicate and produce this reason with no real
        # drift behind it. Repair downgrades a marked reason to :info when the
        # connected major is outside the verified range (see
        # PhoenixKit.Migrations.Repair's server-version preflight).
        "#{@deparse_text_marker}predicate: expected #{inspect(expected.predicate)}, " <>
          "got #{inspect(observed.predicate)}"
      )

    result(reasons)
  end

  def compare(:constraint, %{type: "f"} = expected, observed) do
    reasons =
      []
      |> reason_field(:columns, expected, observed)
      |> reason_field(:foreign_table, expected, observed)
      |> reason_field(:foreign_columns, expected, observed)
      |> reason_field(:on_delete, expected, observed)
      |> reason_field(:on_update, expected, observed)

    result(reasons)
  end

  def compare(:constraint, %{type: type} = expected, observed) when type in ["p", "u"] do
    result(reason_field([], :columns, expected, observed))
  end

  def compare(:constraint, %{type: type} = expected, observed) when type in ["c", "x"] do
    # No further structural decomposition available for CHECK/exclusion
    # predicates — this is the explicit "raw-text equality only where no
    # structural decomposition exists" exception, not a shortcut.
    reasons =
      reason_if(
        [],
        normalize_default(expected.definition) != normalize_default(observed.definition),
        # Same deparse-rendering caveat as :index predicates — see the marker's
        # definition and Repair's server-version preflight.
        "#{@deparse_text_marker}definition: expected #{inspect(expected.definition)}, " <>
          "got #{inspect(observed.definition)}"
      )

    result(reasons)
  end

  # See the moduledoc's `:column` bullet: a `not_null: true, default: nil`
  # expected shape can never be satisfied by the engine's own additive-only
  # column create, so it is excluded from comparison entirely — not just
  # given a softer severity — the same way `pos` is excluded above. Any
  # other expected shape still compares normally.
  defp reason_not_null(reasons, %{not_null: true, default: nil}, _observed), do: reasons

  defp reason_not_null(reasons, expected, observed),
    do: reason_field(reasons, :not_null, expected, observed)

  defp reason_if(reasons, false, _message), do: reasons
  defp reason_if(reasons, true, message), do: [message | reasons]

  defp reason_field(reasons, field, expected, observed) do
    expected_value = Map.fetch!(expected, field)
    observed_value = Map.fetch!(observed, field)

    reason_if(
      reasons,
      expected_value != observed_value,
      field_msg(field, expected_value, observed_value)
    )
  end

  defp field_msg(field, expected_value, observed_value) do
    "#{field}: expected #{inspect(expected_value)}, got #{inspect(observed_value)}"
  end

  defp result([]), do: :match
  defp result(reasons), do: {:mismatch, Enum.reverse(reasons)}

  # `nil` and `nil` compare equal already; this exists so accidental
  # whitespace differences in an expression string (generation server vs
  # target server pretty-printing) do not manufacture a false mismatch.
  defp normalize_default(nil), do: nil

  defp normalize_default(text) when is_binary(text),
    do: text |> String.trim() |> canonicalize_array_casts()

  # Postgres has TWO equally-valid deparse forms for `x = ANY (ARRAY[...])`
  # once the array is built from a cast type (`character varying`, the
  # common case for a status/kind column's CHECK): element-wise
  # (`ARRAY[('a'::type)::text, ('b'::type)::text]`) or array-wise
  # (`(ARRAY['a'::type, 'b'::type])::text[]`) — SAME constraint, same
  # enforced values, chosen non-deterministically by which exact SQL text
  # originally built the constraint's internal expression tree. Confirmed
  # live: a freshly-installed, byte-for-byte-correct chain's own baseline
  # renders the array-wise form (verbatim `pg_get_constraintdef` output
  # captured at generation time) while `mix phoenix_kit.repair`'s *own*
  # `Probe` re-reads the SAME constraint back in element-wise form on some
  # installs — a `:wrong_shape` false positive on an otherwise-healthy
  # database (spec §6.2's "PG deparse differences must be handled
  # structurally" risk, realized in production, not just in tooling). This
  # is the runtime twin of `PhoenixKit.Squash.DumpHelper.canonicalize_array_casts/1`
  # (`dev_docs/squash/dump_helper.ex`) — same rule, independently duplicated
  # here because this module ships in the compiled library and that one does
  # not.
  @array_cast_run_re ~r/ARRAY\[((?:\('[^']*'::[A-Za-z_ ]+\)::text,?\s*)+)\]/
  @array_cast_element_re ~r/\('([^']*)'::([A-Za-z_ ]+)\)::text/

  defp canonicalize_array_casts(text) do
    Regex.replace(@array_cast_run_re, text, fn _whole, run ->
      elements =
        Enum.map(Regex.scan(@array_cast_element_re, run), fn [_whole, literal, type] ->
          "'#{literal}'::#{String.trim(type)}"
        end)

      "(ARRAY[" <> Enum.join(elements, ", ") <> "])::text[]"
    end)
  end
end
