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
  well-behaved `Source`:

  - **Desired parent/name come from the module's own hooks** — the same
    functions the module uses when it creates a folder on first upload — so
    a plan always matches what a fresh upload would do. No hook configured
    means parent `nil` (root) and a deterministic name, which for an
    already-legacy folder means "unchanged": nothing moves. A host with no
    hooks wired is untouched.
  - **Current folder** is the record's pointer if it points at a live
    folder, else the legacy deterministic name looked up at root, else under
    the resolved parent. No folder found means no action — nothing exists to
    move yet; the module creates one on first upload.
  - **Pointer back-fill** happens via `:after_move` when the record has no
    live pointer to its current folder.
  - **Stale pending folders** (a module's own `<prefix>-pending-*` naming):
    empty and older than `pending_days` (an opt threaded through `plan/2`)
    become `op: :trash`; non-empty ones become `op: :report` naming the
    files still inside.
  - A `Source` **must never create folders**. A parent that a module's own
    hook lazily creates (e.g. an "Uncategorized" bucket) is the hook's
    business, not the `Source`'s.
  """

  @doc """
  Returns the actions this source plans for the current database state.

  `actor_uuid` is passed straight through to the module's own hooks (the
  same actor a fresh upload would use). `opts` carries engine options such
  as `pending_days` (default `7`).
  """
  @callback plan(actor_uuid :: String.t() | nil, opts :: keyword()) :: [map()]
end
