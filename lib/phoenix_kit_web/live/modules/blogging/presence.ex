defmodule PhoenixKitWeb.Live.Modules.Blogging.Presence do
  @moduledoc """
  Presence tracking for collaborative blog post editing.

  Uses Phoenix.Presence to track who is currently editing a post.
  The first person to join a topic becomes the "owner" (can edit), and everyone else
  becomes "spectators" (read-only mode).

  ## How It Works

  1. When a user opens the editor, they join a Presence topic (e.g., "blog_edit:blog:post-slug")
  2. Presence tracks all connected users with metadata (user info, joined_at timestamp)
  3. Users are sorted by joined_at to determine order (FIFO)
  4. First user in the sorted list = owner (readonly?: false)
  5. All other users = spectators (readonly?: true)
  6. When owner leaves, Presence removes them automatically
  7. All connected users receive presence_diff event
  8. Each user re-evaluates: "Am I first now?"
  9. New first user auto-promotes to owner

  ## Automatic Cleanup

  Phoenix.Presence automatically detects when LiveView processes die and removes
  them immediately via process monitoring. No manual cleanup needed.

  ## Topics

  - Post editing: "blog_edit:<form_key>"
  """

  use Phoenix.Presence,
    otp_app: :phoenix_kit,
    pubsub_server: :phoenix_kit_internal_pubsub
end
