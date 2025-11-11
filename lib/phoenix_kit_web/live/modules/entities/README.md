# Entities Module

The Entities module delivers PhoenixKit’s dynamic content type system. It mirrors the behaviour of
WordPress ACF by allowing administrators to design structured content (entities) without writing
migrations or code. This README gives a quick orientation for contributors working on the LiveView
layer; the business logic lives in the `PhoenixKit.Entities` context.

## LiveViews & Components

- `entities.ex` / `.html.heex` – Main dashboard listing entities, their status, and health.
- `entity_form.ex` / `.html.heex` – Schema builder for creating and editing entity definitions.
- `entities_settings.ex` / `.html.heex` – Module settings (enable/disable system, defaults).
- `data_navigator.ex` / `.html.heex` – Explorer for entity records with filtering and presence info.
- `data_form.ex` / `.html.heex` – Dynamic form renderer for entity entries.
- `hooks.ex` – LiveView hooks (presence, authorization guards, shared assigns).

All templates follow Phoenix 1.8 layout conventions (`<Layouts.app ...>` with `@current_scope`).

## Feature Highlights

- **Entity Designer** – Build custom fields, validations, and display ordering for each entity type.
- **Schema Versioning** – Update field definitions safely; migrations are generated on the fly.
- **Data Navigator** – Browse, search, and filter entity data with real-time presence indicators.
- **Collaborative Editing** – Presence helpers prevent overwrites when multiple admins edit the same record.
- **Settings Guardrails** – Module can be toggled on/off via PhoenixKit Settings (`entities_enabled`).
- **Audit Trails** – Hooks integrate with `PhoenixKit.Entities.Events` for lifecycle tracking.

## Integration Points

- Context modules: `PhoenixKit.Entities`, `PhoenixKit.Entities.EntityData`, `PhoenixKit.Entities.FieldTypes`.
- Supporting modules: `PhoenixKit.Entities.Events`, `PhoenixKit.Entities.PresenceHelpers`.
- Enabling flag: `PhoenixKit.Settings.get_setting("entities_enabled", "false")`.
- Router: available under `{prefix}/admin/entities/*` via `phoenix_kit_routes()`.

## Additional Reading

- Deep dive: `lib/phoenix_kit/entities/DEEP_DIVE.md`
- Guide: `guides/making-pages-live.md` (sections on entity-driven pages)

Keep this README in sync whenever new submodules or major workflows are added to the Entities
LiveView stack.
