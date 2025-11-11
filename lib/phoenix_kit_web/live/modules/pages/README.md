# Pages Module

The Pages module is an optional file manager and content editor for PhoenixKit-powered sites. It
wraps the `PhoenixKit.Pages` context and exposes a LiveView workspace for managing static pages,
partials, and metadata without leaving the admin UI.

## LiveViews & Templates

- `pages.ex` / `.html.heex` – Explorer view with tree navigation, breadcrumbs, and actions.
- `editor.ex` / `.html.heex` – Monaco-powered editor surface with metadata sidebars.
- `view.ex` / `.html.heex` – Render-only preview of the page within the PhoenixKit layout.

All templates must start with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.

## Core Capabilities

- **Sandboxed File Operations** – Uses `PhoenixKit.Pages.FileOperations` to ensure reads/writes stay
  inside the configured project root.
- **Metadata Management** – Integrates with `PhoenixKit.Pages.Metadata` to attach frontmatter-like
  data to each page.
- **Tree Navigation** – Folder expansion state is tracked in LiveView assigns for smooth UX.
- **Creation Flows** – Modal-driven UI for new files/folders with validation against duplicate names.
- **Move/Copy/Delete** – Bulk operations with safety prompts and guard clauses for root paths.
- **Locale Awareness** – Respects `current_locale` and loads translations via `PhoenixKitWeb.Gettext`.

## Integration Points

- Context module: `PhoenixKit.Pages`
- Helpers: `PhoenixKit.Pages.FileOperations`, `PhoenixKit.Pages.Metadata`
- Settings: `PhoenixKit.Settings.get_setting/2` (e.g., `project_title`)
- Routes: exposed under `{prefix}/admin/pages` by `phoenix_kit_routes()`
- Feature flag: `PhoenixKit.Pages.enabled?()` gate keeps mounting; redirects to Modules dashboard when disabled.

## Operational Notes

- The module assumes a pre-configured root path (`Pages.root_path/0`).
- Remember to stream updates or `push_patch` back to the current path after file operations.
- When adding new UI flows, ensure modals have unique IDs and close/reset assigns on completion.

Update this README whenever new tooling (hooks, components, workflows) is added to the Pages
module so CLAUDE.md can remain lightweight.
