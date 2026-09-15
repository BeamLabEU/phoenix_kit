defmodule PhoenixKit.Modules.Storage.Reorganizer.Source do
  @moduledoc """
  Behaviour a module implements to contribute a media-reorganization plan to
  `PhoenixKit.Modules.Storage.Reorganizer`.

  A module registers its `Source` via the optional `PhoenixKit.Module`
  callback `media_reorganizer/0`, collected from **enabled** modules by
  `PhoenixKit.ModuleRegistry.all_media_reorganizers/0`.

      @impl PhoenixKit.Module
      def media_reorganizer, do: MyModule.MediaReorganizer

      defmodule MyModule.MediaReorganizer do
        @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

        @impl true
        def plan(actor_uuid, opts) do
          [
            %{
              source: "my_module",
              kind: :item,
              label: "My item",
              op: :move,
              folder: current_folder,
              parent_uuid: desired_parent_uuid,
              name: desired_name,
              counts: {files, links},
              on_conflict: :suffix
            }
          ]
        end
      end

  `plan/2` returns a list of **plain maps** (`PhoenixKit.Modules.Storage.Reorganizer.Action`
  validates and normalizes them) — a `Source` implementation never needs to
  depend on this module at compile time, only declare the shape. Rules for a
  well-behaved `Source` (the contract behind the 2026-09-15 design decisions
  — `docs/superpowers/specs/2026-09-15-media-reorganizer-design.md` §9/§10 —
  amend this list on conflict):

  - **No hook configured on the host → `:report` actions only.** When the
    module's own parent-folder hook isn't wired up, the `Source` emits
    orphan/pending/duplicate/relocated `:report`s and nothing else — never
    `op: :move`, never `op: :trash`, no pointer back-fill. A host with no
    hooks wired is untouched.
  - **Desired parent/name come from the module's own hooks** — the same
    functions the module uses when it creates a folder on first upload — so
    a plan always matches what a fresh upload would do.
  - **Lookup order is parent-first, in the module's own order**: under the
    resolved parent before root. A host-named folder under the resolved
    parent (the name a fresh upload would use) is itself a lookup step,
    batched — not folded into the legacy-name lookup: if an unclaimed one
    exists there, it IS the current folder (a noop move + pointer
    back-fill); a live host-named folder AND a live legacy-named folder both
    present under/at the same place is one `:report, kind: :duplicate`, no
    move. A live folder found in more than one place the module would look
    (e.g. root AND the resolved parent) is the same: one `:duplicate`
    report naming every uuid found, nothing moves.
  - **The record's pointer wins over any name lookup** when it resolves to
    a live folder. A folder found only through a legacy/host name (no live
    pointer) means the record's pointer needs back-filling.
  - **A pointer-found folder keeps its current name** (`name: nil`) —
    modules never rename a folder the owner may have renamed — UNLESS
    `folder.name` still equals the module's legacy name exactly (the owner
    never touched it), in which case the desired host name is proposed like
    any other rename.
  - **Converging targets**: two records whose desired `{parent, name}` are
    the same collapse into one `:report, kind: :duplicate` for the group —
    never two `:move` actions racing for one target.
  - **Claims are computed from every record's valid pointer**, regardless of
    whether the host has a hook configured — a pending folder any live
    record points at is never planned as an orphan or a stale-pending
    `:trash`, hook or no hook.
  - **A hook is either `{:ok, uuid | nil}` or a failure** — raising, exiting,
    returning `{:error, _}`, or any other shape is the hook FAILING, not
    "root". A failing hook skips the affected record with one
    `op: :report, kind: :hook_error` per source (naming how many records it
    affected) — it must never be read as `{:ok, nil}` and planned as a move
    to root.
  - **No folder found means no action** — nothing exists to move yet; the
    module creates one on first upload.
  - **Pointer-less modules** (no field to back-fill) only ever consider a
    legacy-named folder at root or under the resolved parent; one found
    anywhere else is left alone and reported `kind: :relocated` — never
    moved, since nothing would keep pointing at it afterwards. When the
    hook itself depends on the acting user (not just database state), the
    `:relocated` reason says so.
  - **Records whose parent record is trashed** (e.g. a CRM interaction of a
    trashed contact) are skipped by the `Source`; their folders, if any, are
    reported as orphans, not moved.
  - **Pointer back-fill** happens via `:after_move` when the record has no
    live pointer to its current folder. `:after_move` writes only the
    owned pointer field directly (no context `update_*`, no Activity log, no
    PubSub) and must be a 0-arity function.
  - **Stale pending folders** (a module's own `<prefix>-pending-*` naming):
    empty and older than `pending_days` (an opt threaded through `plan/2`)
    become `op: :trash`; non-empty ones become `op: :report` naming the
    files still inside — but only among folders no live record claims (see
    claims above), and only for a host that has a hook configured.
  - A `Source` **must never create folders**. A parent that a module's own
    hook lazily creates (e.g. an "Uncategorized" bucket) is the hook's
    business, not the `Source`'s.
  - **Query cost**: load only the columns a plan needs (uuid, name/number,
    status, pointer, parent id) — never whole records with large/jsonb
    payloads — and keep the query count independent of record count
    (grouped/batched lookups, not one query per record).
  - **Deterministic order**: parents before children when the module has
    that hierarchy (e.g. category before item), then by `inserted_at`/uuid,
    so re-running `plan/2` against unchanged data always proposes the same
    order.
  """

  @doc """
  Returns the actions this source plans for the current database state.

  `actor_uuid` is passed straight through to the module's own hooks (the
  same actor a fresh upload would use). `opts` carries engine options such
  as `pending_days` (default `7`).
  """
  @callback plan(actor_uuid :: String.t() | nil, opts :: keyword()) :: [map()]
end
