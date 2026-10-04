# Module-owned tables: extracting them from core

Core's baseline (V135) still creates tables that belong to modules
(`phoenix_kit_shop_*`, `phoenix_kit_cat_*`, `phoenix_kit_entities*`, …).
The protocol for a module to take ownership without a breaking core release
is written once, in the Hello World template module:

* `phoenix_kit_hello_world` README → `## Database conventions` →
  `### Versioned migrations` → `#### Adopting a table core already creates (extraction)`
* template coordinator: `lib/phoenix_kit_hello_world/migrations.ex`
* live examples: `phoenix_kit_legal` (`phoenix_kit_consent_logs`,
  `dev_docs/reports/2026-08-10-consent-logs-extraction.md`),
  `phoenix_kit_billing` (`phoenix_kit_payment_provider_configs`),
  and since 2026-09: `phoenix_kit_catalogue` (`pkc_schema`),
  `phoenix_kit_entities` (`pkn_schema`), `phoenix_kit_ecommerce` (`pke_schema`).

The three phases, in one paragraph each:

**Phase 0 — adopt.** The module ships V1 whose every statement is
`CREATE … IF NOT EXISTS` / guarded `DO $$ … $$`, shape- and name-identical
to core's objects, and stamps a namespaced `COMMENT ON TABLE` marker
(`<ns>_schema:1`) on one designated table. `down/1` only unstamps. Core
keeps creating the same tables; nothing changes for hosts.

**Phase 1 — first shape change.** Before releasing a module V2 that alters
one of these tables: add the changed objects' ids to `@module_owned_ids`
(`PhoenixKit.Squash.Generate.Emitter` in
`dev_docs/squash/generate_baseline.exs`), take them out of `ExpectedSchema`
(regenerate, or remove them by hand with a dated note where each was), and
raise the module's core version floor — otherwise `mix phoenix_kit.doctor`
reports the change as drift and `mix phoenix_kit.repair` may offer to put
the old shape back. Not `@excluded_exact`: that list is a refuse-to-emit
guard for objects the chain no longer creates, and an object core's chain
still creates would abort the generation there.

**Phase 2 — core stops creating.** Only at core's next baseline squash does
core drop its copy of the DDL. The module's V1 must already be able to
create the tables from scratch. Core never drops module tables
conditionally ("if the module is absent") — uninstall is a documented
manual step in the module README.

Tables that a module has stopped using but that core still creates (for
example `phoenix_kit_shop_products` once the shop reads products from
`phoenix_kit_catalogue`) are marked with a `COMMENT ON TABLE … 'deprecated
<date>: …'` by the host app, never dropped by anyone in this cycle; the
squash of Phase 2 decides their fate.

## What the adoption marker means today — and how a module can strengthen that

The `COMMENT ON TABLE ... IS '<ns>_schema:<N>'` marker has always meant
**"this table's objects exist"** — nothing more. Every adoption statement is
`CREATE ... IF NOT EXISTS` / `ADD COLUMN ... IF NOT EXISTS`, which checks
presence, never shape: a column narrowed by hand outside any migration (a
money column quietly changed from `numeric(15,2)` to `numeric(10,2)`, say)
survives adoption completely silently — the marker gets written, the
narrower type is never noticed. That has always been the marker's historical
meaning for every module listed in the inventory below, and stays that way
for any module that doesn't opt into the mechanism described here — this is
not a breaking change to what the marker promises.

`PhoenixKit.Migrations.Adoption.verify_shape/3` and
`.marker_conflict/5` now exist so a module's adoption step *can* make a
stronger claim than "exists" — "exists, and its shape matches what I
expect" — if it chooses to call them. This is opt-in machinery: a module
that never calls it behaves exactly as before.

The recommended pattern is to verify shape **before** writing the marker.
`PhoenixKit.Migrations.Adoption` itself is mode-agnostic — it only reports
drift, never reacts to it — but the reaction is a decided, shared contract
across core and `phoenix_kit_legal`'s own adoption step (issue legal#23):

  * **By default** — decline the marker and **raise**, with the diff
    rendered via `format_drift/1` into the message. Never silently skip,
    never auto-repair.
  * **Under an explicit, per-host operator opt-in** (a config toggle the
    module itself reads — the key is the module's own choice) — render
    the SAME diff via `format_drift/1` into an `:error`-level log line
    instead, **write the marker anyway**, and let the migration succeed
    so the chain's version advances. The migration must not fail in this
    mode: `mix phoenix_kit.update` regenerates a module's migration file
    on every run, so one that never completes would be regenerated and
    re-attempted forever. `:warn` accepts the drift, it does not hide
    it — but the `:error`-level log line is the durable record of that,
    not a promise that a later `mix phoenix_kit.repair`/`doctor` run will
    independently rediscover it: `Differ` itself excludes
    `not_null: true, default: nil` from comparison entirely, and any
    object a module has since gone through Phase 1 for
    (`@module_owned_ids`, dropped from core's manifest) stops being
    asserted by core at all — see `PhoenixKit.Migrations.Adoption`'s
    moduledoc for the full reasoning.

This is a reviewed, explicit, per-host decision — never a default, never
something a module flips on for itself — for the hosts where the drift is
already known and understood and adoption otherwise could never complete.

Auto-fixing DDL during unattended adoption (at app boot, no operator
watching) carries the same silent-mutation risk this mechanism exists to
close, just inverted: a column silently widened back is a smaller but
structurally identical mistake to a column silently narrowed. That is
still ruled out — the operator override above only changes whether the
marker gets written over a known, accepted drift, never the table's actual
DDL. `mix phoenix_kit.repair` cannot substitute for a manual fix either
way — it is additive-only (it can add a missing column or index, never
alter an existing one's type, nullability, or definition) and has no
notion of module ownership, so a module-adopted table's drift is always a
manual `ALTER`/re-declare, or the `:warn` override above, never something
to point an operator at repair for.

A real module coordinator implements `up(opts \\ [])` and issues its DDL
through `Ecto.Migration.execute/1`, which only *queues* the command on the
migration runner — a `flush()` is required before any read (like
`verify_shape/3`) that depends on the DDL having actually landed:

```elixir
def up(opts \\ []) do
  prefix = Keyword.get(opts, :prefix, "public")
  repo = repo()

  execute("CREATE TABLE IF NOT EXISTS #{prefix}.#{table} (...)")
  flush()

  case PhoenixKit.Migrations.Adoption.verify_shape(repo, prefix, checks) do
    :ok -> :ok
    {:drift, diffs} -> handle_drift(diffs)
  end

  case PhoenixKit.Migrations.Adoption.marker_conflict(repo, prefix, table, @marker_prefix) do
    :ok ->
      execute("COMMENT ON TABLE #{prefix}.#{table} IS '#{@marker_prefix}#{version}'")

    {:conflict, existing} ->
      raise "table already carries an unrelated marker: #{inspect(existing)}"

    {:error, reason} ->
      raise "could not read the table's current comment: #{inspect(reason)}"
  end
end

# Default: decline and raise. Under an explicit, per-host operator
# opt-in, log the same diff at :error and return normally instead — up/1
# then proceeds to write the marker anyway.
defp handle_drift(diffs) do
  diff_text = PhoenixKit.Migrations.Adoption.format_drift(diffs)

  case Application.get_env(:my_app, :adoption_shape_check, :raise) do
    :warn -> Logger.error("adopting over known shape drift:\n\n#{diff_text}")
    _ -> raise "table shape does not match what this module expects:\n\n#{diff_text}"
  end
end
```

Full worked example, including the `checks` vocabulary (the same
per-class shape maps `PhoenixKit.Migrations.ExpectedSchema` already uses
internally, and how to build one from a real manifest entry rather than
hand-copying manifest source text) and the full reasoning behind
decline-and-raise vs. the `:warn` override above: `PhoenixKit.Migrations.
Adoption`'s moduledoc, which this section mirrors in short form.

## Inventory: which core-baseline tables are already module-owned

Each module below is at Phase 0 (adopted, `down/1` only unstamps) or
already past it. Core's baseline still creates every table listed — this
inventory is what a future baseline squash removes from core once all
hosts have adopted the owning module's V1, not something this PR drops or
migrates. Only the module's designated version table carries the
`COMMENT ON TABLE … '<ns>_schema:<N>'` marker; the rest of a module's
tables are recognized by ownership (this list), not by a per-table
comment.

**`phoenix_kit_ecommerce`** — marker `pke_schema:<N>` on
`phoenix_kit_shop_config` (`PhoenixKitEcommerce.Migrations.version_table/0`).
Ten tables, all `phoenix_kit_shop_*`:

* `phoenix_kit_shop_config`
* `phoenix_kit_shop_shipping_methods`
* `phoenix_kit_shop_categories`
* `phoenix_kit_shop_products`
* `phoenix_kit_shop_product_slugs`
* `phoenix_kit_shop_category_slugs`
* `phoenix_kit_shop_carts`
* `phoenix_kit_shop_cart_items`
* `phoenix_kit_shop_import_configs`
* `phoenix_kit_shop_import_logs`

**`phoenix_kit_catalogue`** — marker `pkc_schema:<N>` on
`phoenix_kit_cat_catalogues` (`PhoenixKitCatalogue.Migrations.version_table/0`).
Eighteen tables, all `phoenix_kit_cat_*`:

* `phoenix_kit_cat_catalogues`
* `phoenix_kit_cat_folders`
* `phoenix_kit_cat_categories`
* `phoenix_kit_cat_manufacturers`
* `phoenix_kit_cat_suppliers`
* `phoenix_kit_cat_manufacturer_suppliers`
* `phoenix_kit_cat_items`
* `phoenix_kit_cat_item_catalogue_rules`
* `phoenix_kit_cat_item_supplier_info`
* `phoenix_kit_cat_pdfs`
* `phoenix_kit_cat_pdf_pages`
* `phoenix_kit_cat_pdf_page_contents`
* `phoenix_kit_cat_pdf_extractions`
* `phoenix_kit_cat_attribute_groups`
* `phoenix_kit_cat_attributes`
* `phoenix_kit_cat_attribute_values`
* `phoenix_kit_cat_item_attribute_groups`
* `phoenix_kit_cat_item_attribute_sets`

**`phoenix_kit_entities`** — marker `pkn_schema:<N>` on
`phoenix_kit_entities` itself (`PhoenixKitEntities.Migrations.version_table/0`).
Two tables:

* `phoenix_kit_entities`
* `phoenix_kit_entity_data`

Storage's orphaned-file check and doctor's NULL-uuid check are the two
places that have historically hardcoded a table list next to this kind of
inventory; see their own comments for why each one currently does or does
not need the catalogue tables added — the answer is not the same for both.
