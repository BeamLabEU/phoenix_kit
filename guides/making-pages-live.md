# Making Pages Live: Real-time Updates & Collaborative Editing

This guide explains how to add real-time functionality to LiveView pages in PhoenixKit, including PubSub events and Phoenix.Presence-based collaborative editing.

## Table of Contents

1. [Overview](#overview)
2. [WebSocket Requirement](#websocket-requirement)
3. [Quick Start](#quick-start)
4. [Events System](#events-system)
5. [Collaborative Editing with Phoenix.Presence](#collaborative-editing-with-phoenixpresence)
6. [On Mount Hooks](#on-mount-hooks)
7. [Common Patterns](#common-patterns)
8. [Troubleshooting](#troubleshooting)

---

## Overview

PhoenixKit provides two main systems for real-time functionality:

### 1. Events System (PubSub Broadcasting)
**Location:** `lib/phoenix_kit/entities/events.ex`

Broadcasts create/update/delete events across all LiveView sessions.

**Key Functions:**
- `subscribe_to_entities()` - Subscribe to all entity events
- `subscribe_to_entity_data(entity_id)` - Subscribe to specific entity's data events
- `broadcast_entity_created(entity_id)` - Notify about new entity
- `broadcast_entity_updated(entity_id)` - Notify about entity changes
- `broadcast_data_updated(entity_id, data_id)` - Notify about data changes

### 2. Phoenix.Presence (Collaborative Editing)
**Location:** `lib/phoenix_kit/entities/presence.ex` + `lib/phoenix_kit/entities/presence_helpers.ex`

Distributed presence tracking with automatic role assignment for collaborative editing.

**How It Works:**
- Multiple users can open the same edit form simultaneously
- **First user in the list = owner** (can edit)
- **Everyone else = spectators** (read-only, see real-time updates)
- When owner leaves, next person auto-promoted (within 5 seconds)
- No manual locks or cleanup needed

**Key Functions:**
- `PresenceHelpers.track_editing_session(type, id, socket, user)` - Join editing session
- `PresenceHelpers.get_editing_role(type, id, socket_id, user_id)` - Determine if owner or spectator
- `PresenceHelpers.get_sorted_presences(type, id)` - Get all editors (FIFO ordered)
- `PresenceHelpers.subscribe_to_editing(type, id)` - Subscribe to presence changes

### 3. SimplePresence (Admin Session Tracking)
**Location:** `lib/phoenix_kit/admin/simple_presence.ex`

Lightweight session tracking for admin dashboard statistics only.

**Key Functions:**
- `track_anonymous(session_id, metadata)` - Track anonymous visitors
- `track_user(user, metadata)` - Track authenticated users
- `get_presence_stats()` - Get dashboard statistics

---

## WebSocket Requirement

### Critical: WebSocket-Only Mode for Instant Presence Cleanup

Phoenix LiveView supports both WebSocket and long-polling transports. **PhoenixKit requires WebSocket-only mode** to enable instant presence cleanup for collaborative editing.

#### Problem with Long-Polling Fallback

If long-polling fallback is enabled, LiveView processes can linger for up to 30 seconds after a tab is closed or refreshed, causing:

- ❌ Stale "ghost" users in presence lists for ~30 seconds
- ❌ Slow role transitions in collaborative editing (owner → spectator)
- ❌ Poor user experience with delayed updates
- ❌ Presence entries not removed immediately on tab close/refresh

#### Solution (Already Applied)

**PhoenixKit has already disabled long-polling in its endpoint configuration:**

```elixir
# lib/phoenix_kit_web/endpoint.ex (line 14)
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: false  # ← Forces WebSocket-only connections
```

**No parent application changes are required.** The server-side configuration is sufficient.

#### Benefits of WebSocket-Only Mode

With WebSocket-only mode enabled:

- ✅ Presence entries removed **instantly** when tabs close
- ✅ Presence entries removed **instantly** when pages refresh
- ✅ Collaborative editing roles (owner/spectator) update **immediately**
- ✅ No 30-second delay for presence cleanup
- ✅ Clean, responsive real-time collaboration

#### Production Considerations

When deploying PhoenixKit with WebSocket-only mode, ensure your infrastructure supports WebSocket connections:

**1. Reverse Proxies (NGINX, Apache, etc.)**

Must forward WebSocket upgrade headers. Example NGINX config:

```nginx
location /live {
  proxy_pass http://backend;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
}
```

**2. CDN/Load Balancers (Cloudflare, AWS ALB, etc.)**

- Must support WebSocket connections
- May require specific routing rules for `/live/websocket` path

**3. Firewall/Security Rules**

- Must allow WebSocket traffic on your application port
- Must not block HTTP upgrade requests

#### Testing WebSocket Connections

To verify WebSocket-only mode is working:

1. Open a collaborative editing page (entity or data form)
2. Open browser Developer Tools → Network tab
3. Look for WebSocket connection: `ws://localhost:4000/live/websocket`
4. Refresh the page
5. Verify the old WebSocket closes **immediately**
6. Verify presence list updates **within 1 second**

If you see `Transport: :longpoll` in server logs, WebSocket connections are failing and clients are attempting fallback (which should not happen with `longpoll: false`).

#### Fallback Strategy (Not Recommended)

If WebSocket support is absolutely unavailable in your environment:

1. Remove `longpoll: false` from endpoint configuration to re-enable fallback
2. Accept the 30-second delay for presence cleanup
3. Consider adding UI indicators to show stale connections
4. Implement periodic refresh to clean up dead PIDs faster

**Note:** This significantly degrades the collaborative editing experience and is not recommended for production use.

---

## Quick Start

### Example 1: Add Real-time Updates to a List Page

```elixir
defmodule PhoenixKitWeb.Live.MyResourcesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Entities.Events
  alias PhoenixKit.MyContext

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to events when connected
    if connected?(socket) do
      Events.subscribe_to_entities()
    end

    resources = MyContext.list_resources()

    {:ok, assign(socket, :resources, resources)}
  end

  # Handle real-time updates
  @impl true
  def handle_info({:entity_created, _entity_id}, socket) do
    # Reload and update the list
    resources = MyContext.list_resources()
    {:noreply, assign(socket, :resources, resources)}
  end

  @impl true
  def handle_info({:entity_updated, _entity_id}, socket) do
    resources = MyContext.list_resources()
    {:noreply, assign(socket, :resources, resources)}
  end

  @impl true
  def handle_info({:entity_deleted, _entity_id}, socket) do
    resources = MyContext.list_resources()
    {:noreply, assign(socket, :resources, resources)}
  end
end
```

### Example 2: Add Collaborative Editing to a Form

```elixir
defmodule PhoenixKitWeb.Live.MyResourceFormLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Entities.{Events, PresenceHelpers}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = MyContext.get_resource!(id)
    form_key = "resource_#{id}"

    socket = assign(socket,
      resource: resource,
      form_key: form_key,
      changeset: MyContext.change_resource(resource),
      editing_role: :spectator  # Will be updated after presence tracking
    )

    if connected?(socket) do
      # Subscribe to presence changes and form updates
      PresenceHelpers.subscribe_to_editing(:resource, id)
      Events.subscribe_to_resource_form(form_key)

      # Track this editing session (pass user struct, not metadata map)
      current_user = socket.assigns.current_user
      PresenceHelpers.track_editing_session(:resource, id, socket, current_user)

      # Determine our role (owner or spectator) - returns tuple
      case PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id) do
        {:owner, _presences} ->
          socket = assign(socket, editing_role: :owner)
          {:ok, socket}

        {:spectator, _owner_meta, _presences} ->
          socket = assign(socket, editing_role: :spectator)
          {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"resource" => params}, socket) do
    # Only owners can edit
    if socket.assigns.editing_role == :owner do
      changeset = MyContext.change_resource(socket.assigns.resource, params)

      # Broadcast changes to spectators via PubSub
      Events.broadcast_resource_form_change("resource_#{socket.assigns.resource.id}", %{
        changeset_params: params
      })

      {:noreply, assign(socket, changeset: changeset, has_unsaved_changes: true)}
    else
      # Spectators can't edit
      {:noreply, socket}
    end
  end

  # Handle presence_diff - someone joined or left
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    resource_id = socket.assigns.resource.id
    current_user = socket.assigns.current_user

    # Recalculate our role
    case PresenceHelpers.get_editing_role(:resource, resource_id, socket.id, current_user.id) do
      {:owner, _presences} ->
        old_role = socket.assigns.editing_role
        socket = assign(socket, editing_role: :owner)

        # If we were promoted from spectator to owner
        socket = if old_role == :spectator do
          put_flash(socket, :info, "You are now editing this resource")
        else
          socket
        end

        {:noreply, socket}

      {:spectator, _owner_meta, _presences} ->
        socket = assign(socket, editing_role: :spectator)
        {:noreply, socket}
    end
  end

  # Handle form changes broadcast from owner
  @impl true
  def handle_info({:resource_form_change, form_key, payload, _source}, socket) do
    if form_key == "resource_#{socket.assigns.resource.id}" && socket.assigns.editing_role == :spectator do
      case Map.get(payload, :changeset_params) do
        params when not is_nil(params) ->
          changeset = MyContext.change_resource(socket.assigns.resource, params)
          {:noreply, assign(socket, changeset: changeset)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"resource" => params}, socket) do
    # Only owners can save
    if socket.assigns.editing_role == :owner do
      case MyContext.update_resource(socket.assigns.resource, params) do
        {:ok, resource} ->
          {:noreply,
           socket
           |> put_flash(:info, "Resource updated successfully")
           |> redirect(to: ~p"/admin/resources/#{resource.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, changeset: changeset)}
      end
    else
      {:noreply, put_flash(socket, :error, "Only the owner can save changes")}
    end
  end

  # No manual cleanup needed - Phoenix.Presence handles it automatically
end
```

---

## Events System

### Creating an Events Module

**File:** `lib/phoenix_kit/entities/events.ex`

```elixir
defmodule PhoenixKit.Entities.Events do
  @moduledoc """
  PubSub event broadcasting for entity lifecycle events.
  """

  alias PhoenixKit.PubSub.Manager

  @entity_topic "phoenix_kit:entities"
  @entity_data_topic_prefix "phoenix_kit:entity_data:"

  # Subscription functions
  def subscribe_to_entities do
    Manager.subscribe(@entity_topic)
  end

  def subscribe_to_entity_data(entity_id) do
    Manager.subscribe(@entity_data_topic_prefix <> to_string(entity_id))
  end

  # Broadcasting functions
  def broadcast_entity_created(entity_id) do
    Manager.broadcast(@entity_topic, {:entity_created, entity_id})
  end

  def broadcast_entity_updated(entity_id) do
    Manager.broadcast(@entity_topic, {:entity_updated, entity_id})
  end

  def broadcast_entity_deleted(entity_id) do
    Manager.broadcast(@entity_topic, {:entity_deleted, entity_id})
  end

  def broadcast_data_created(entity_id, data_id) do
    Manager.broadcast(@entity_data_topic_prefix <> to_string(entity_id),
      {:data_created, entity_id, data_id})
  end

  def broadcast_data_updated(entity_id, data_id) do
    Manager.broadcast(@entity_data_topic_prefix <> to_string(entity_id),
      {:data_updated, entity_id, data_id})
  end
end
```

### Adding Event Broadcasting to Context Functions

**Pattern:** Pipe the result through a notification function.

```elixir
defmodule PhoenixKit.Entities do
  alias PhoenixKit.Entities.Events

  def create_entity(attrs) do
    %Entity{}
    |> changeset(attrs)
    |> repo().insert()
    |> notify_entity_event(:created)
  end

  def update_entity(entity, attrs) do
    entity
    |> changeset(attrs)
    |> repo().update()
    |> notify_entity_event(:updated)
  end

  def delete_entity(entity) do
    entity
    |> repo().delete()
    |> notify_entity_event(:deleted)
  end

  defp notify_entity_event({:ok, %Entity{} = entity}, :created) do
    Events.broadcast_entity_created(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %Entity{} = entity}, :updated) do
    Events.broadcast_entity_updated(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %Entity{} = entity}, :deleted) do
    Events.broadcast_entity_deleted(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event(result, _event), do: result
end
```

---

## Collaborative Editing with Phoenix.Presence

### Understanding the "First in List = Owner" Pattern

PhoenixKit uses a **distributed presence-based ownership model**:

1. Multiple users can open the same form simultaneously
2. Phoenix.Presence tracks all users (sorted by `joined_at` timestamp)
3. **First person in the list = owner** (can edit)
4. **Everyone else = spectators** (read-only, see real-time updates)
5. When owner leaves, Phoenix.Presence automatically removes them and broadcasts `presence_diff`
6. Next person in line becomes owner automatically (within 5 seconds)

**No locks, no manual cleanup, no race conditions.**

### Tracking Editing Sessions

Use `PresenceHelpers` to track editing sessions:

```elixir
alias PhoenixKit.Entities.PresenceHelpers

# In mount/3
if connected?(socket) do
  current_user = socket.assigns.current_user

  # Subscribe to presence changes
  PresenceHelpers.subscribe_to_editing(:entity, entity_id)

  # Track this editing session (pass user struct, not metadata map)
  PresenceHelpers.track_editing_session(:entity, entity_id, socket, current_user)

  # Determine our role (returns tuple, not bare atom)
  case PresenceHelpers.get_editing_role(:entity, entity_id, socket.id, current_user.id) do
    {:owner, _presences} ->
      assign(socket, editing_role: :owner)

    {:spectator, _owner_meta, _presences} ->
      assign(socket, editing_role: :spectator)
  end
end
```

### Broadcasting Changes to Spectators

**Key Concept:** Owner broadcasts form changes via PubSub Events, spectators receive and apply them.

```elixir
# In handle_event("validate")
if socket.assigns.editing_role == :owner do
  changeset = MyContext.change_resource(resource, params)

  # Broadcast changes to spectators via PubSub Events system
  Events.broadcast_entity_form_change("entity_#{entity_id}", %{
    changeset_params: params,
    last_updated: System.system_time(:millisecond)
  })

  {:noreply, assign(socket, changeset: changeset)}
else
  # Spectators can't edit
  {:noreply, socket}
end
```

### Handling Presence Changes

**Handle `presence_diff` to react to ownership changes:**

```elixir
@impl true
def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
  entity_id = socket.assigns.entity.id
  current_user = socket.assigns.current_user

  # Recalculate our role (returns tuple)
  case PresenceHelpers.get_editing_role(:entity, entity_id, socket.id, current_user.id) do
    {:owner, _presences} ->
      old_role = socket.assigns.editing_role
      socket = assign(socket, editing_role: :owner)

      # Notify user if promoted to owner
      socket = if old_role == :spectator do
        put_flash(socket, :info, "You are now editing")
      else
        socket
      end

      {:noreply, socket}

    {:spectator, _owner_meta, _presences} ->
      socket = assign(socket, editing_role: :spectator)
      {:noreply, socket}
  end
end

# Handle form changes broadcast from owner
@impl true
def handle_info({:entity_form_change, form_key, payload, _source}, socket) do
  if form_key == "entity_#{socket.assigns.entity.id}" && socket.assigns.editing_role == :spectator do
    case Map.get(payload, :changeset_params) do
      params when not is_nil(params) ->
        changeset = MyContext.change_resource(socket.assigns.entity, params)
        {:noreply, assign(socket, changeset: changeset)}

      _ ->
        {:noreply, socket}
    end
  else
    {:noreply, socket}
  end
end
```

### Displaying Editor Information in Templates

Show who else is editing and your role:

```heex
<%!-- Show editing role badge --%>
<div class="flex items-center gap-2 mb-4">
  <%= if @editing_role == :owner do %>
    <span class="badge badge-success">You are editing</span>
  <% else %>
    <span class="badge badge-warning">Read-only (someone else editing)</span>
  <% end %>

  <%!-- Show other editors --%>
  <%= if length(@presences) > 1 do %>
    <span class="text-sm text-gray-600">
      <%= length(@presences) - 1 %> other <%= if length(@presences) == 2, do: "person", else: "people" %>
    </span>
  <% end %>
</div>

<%!-- Disable form fields for spectators --%>
<.input
  field={@form[:name]}
  label="Name"
  disabled={@editing_role == :spectator}
/>
```

```elixir
# In mount/3 or handle_info/2
presences = PresenceHelpers.get_sorted_presences(:entity, entity_id)
assign(socket, presences: presences)
```

### No Manual Cleanup Required

**Phoenix.Presence automatically cleans up when your LiveView process terminates:**

```elixir
# ❌ OLD WAY (no longer needed):
@impl true
def terminate(_reason, socket) do
  Presence.untrack("editor:entity:#{entity_id}:")
  Presence.clear_data("state:entity:#{entity_id}")
  :ok
end

# ✅ NEW WAY (automatic cleanup):
# No terminate/2 callback needed!
# Phoenix.Presence removes you automatically when LiveView process dies
```

---

## On Mount Hooks

### Creating Centralized Subscriptions

**File:** `lib/modules/entities/web/hooks.ex`

```elixir
defmodule PhoenixKit.Modules.Entities.Web.Hooks do
  @moduledoc """
  LiveView hooks for entity module pages.
  Provides common setup and subscriptions for all entity-related LiveViews.
  """

  import Phoenix.LiveView
  alias PhoenixKit.Modules.Entities.Events

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_to_entities()
    end

    {:cont, socket}
  end
end
```

### Using Hooks in LiveViews

```elixir
defmodule PhoenixKit.Modules.Entities.Web.EntitiesLive do
  use PhoenixKitWeb, :live_view

  # Add this line to use the hook
  on_mount PhoenixKit.Modules.Entities.Web.Hooks

  # Now you don't need to call Events.subscribe_to_entities() in mount/3
  # It's handled automatically by the hook!

  @impl true
  def mount(_params, _session, socket) do
    entities = Entities.list_entities()
    {:ok, assign(socket, :entities, entities)}
  end

  # Still need handle_info callbacks
  @impl true
  def handle_info({:entity_created, _entity_id}, socket) do
    {:noreply, assign(socket, :entities, Entities.list_entities())}
  end
end
```

---

## Common Patterns

### Pattern 1: List Page with Real-time Updates

**Reference:** `lib/phoenix_kit_web/live/modules/entities/entities.ex`

```elixir
defmodule MyApp.MyResourcesLive do
  use MyAppWeb, :live_view
  on_mount MyAppWeb.Live.Hooks  # Centralized subscriptions

  @impl true
  def mount(_params, _session, socket) do
    resources = load_resources()
    {:ok, assign(socket, :resources, resources)}
  end

  @impl true
  def handle_info({:resource_created, _id}, socket) do
    {:noreply, assign(socket, :resources, load_resources())}
  end

  @impl true
  def handle_info({:resource_updated, _id}, socket) do
    {:noreply, assign(socket, :resources, load_resources())}
  end

  @impl true
  def handle_info({:resource_deleted, _id}, socket) do
    {:noreply, assign(socket, :resources, load_resources())}
  end

  defp load_resources do
    MyContext.list_resources()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end
end
```

### Pattern 2: Detail Page with Remote Updates

**Reference:** `lib/phoenix_kit_web/live/modules/entities/data_navigator.ex`

```elixir
defmodule MyApp.MyResourceDetailLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = MyContext.get_resource!(id)

    if connected?(socket) do
      Events.subscribe_to_resource(id)
    end

    {:ok, assign(socket, :resource, resource)}
  end

  @impl true
  def handle_info({:resource_updated, resource_id}, socket) do
    if resource_id == socket.assigns.resource.id do
      resource = MyContext.get_resource!(resource_id)

      # Check if resource was archived/deleted
      if resource.status == "archived" do
        {:noreply,
         socket
         |> put_flash(:warning, "Resource was archived in another session")
         |> redirect(to: ~p"/admin/resources")}
      else
        # Update with fresh data
        {:noreply, assign(socket, :resource, resource)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:resource_deleted, resource_id}, socket) do
    if resource_id == socket.assigns.resource.id do
      {:noreply,
       socket
       |> put_flash(:error, "Resource was deleted in another session")
       |> redirect(to: ~p"/admin/resources")}
    else
      {:noreply, socket}
    end
  end
end
```

### Pattern 3: Collaborative Form Editing

**Reference:** `lib/phoenix_kit_web/live/modules/entities/entity_form.ex`

```elixir
defmodule MyApp.MyResourceFormLive do
  use MyAppWeb, :live_view

  alias PhoenixKit.Entities.PresenceHelpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = MyContext.get_resource!(id)
    changeset = MyContext.change_resource(resource)

    socket = assign(socket,
      resource: resource,
      changeset: changeset,
      editing_role: :spectator,
      has_unsaved_changes: false,
      presences: []
    )

    if connected?(socket) do
      # Subscribe to presence changes
      PresenceHelpers.subscribe_to_editing(:resource, id)

      # Track this editing session (pass user struct)
      current_user = socket.assigns.current_user
      PresenceHelpers.track_editing_session(:resource, id, socket, current_user)

      # Determine our role (returns tuple)
      {editing_role, presences} =
        case PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id) do
          {:owner, presences} -> {:owner, presences}
          {:spectator, _owner_meta, presences} -> {:spectator, presences}
        end

      # If we're a spectator, sync with owner's current state
      socket = if editing_role == :spectator do
        case PresenceHelpers.get_lock_owner(:resource, id) do
          %{form_state: %{changeset_params: params}} when params != %{} ->
            changeset = MyContext.change_resource(resource, params)
            assign(socket, changeset: changeset, has_unsaved_changes: true)

          _ ->
            socket
        end
      else
        socket
      end

      socket = assign(socket,
        editing_role: editing_role,
        presences: presences
      )

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"resource" => params}, socket) do
    # Only owners can edit
    if socket.assigns.editing_role == :owner do
      changeset = MyContext.change_resource(socket.assigns.resource, params)

      # Broadcast changes to spectators via PubSub Events
      Events.broadcast_resource_form_change("resource_#{socket.assigns.resource.id}", %{
        changeset_params: params,
        last_updated: System.system_time(:millisecond)
      })

      {:noreply, assign(socket, changeset: changeset, has_unsaved_changes: true)}
    else
      # Spectators can't edit
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"resource" => params}, socket) do
    # Only owners can save
    if socket.assigns.editing_role == :owner do
      case MyContext.update_resource(socket.assigns.resource, params) do
        {:ok, resource} ->
          {:noreply,
           socket
           |> put_flash(:info, "Resource updated successfully")
           |> redirect(to: ~p"/admin/resources/#{resource.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, changeset: changeset)}
      end
    else
      {:noreply, put_flash(socket, :error, "Only the owner can save")}
    end
  end

  # Handle presence_diff - someone joined or left
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    resource_id = socket.assigns.resource.id
    current_user = socket.assigns.current_user
    old_role = socket.assigns.editing_role

    # Recalculate our role (returns tuple)
    {editing_role, presences} =
      case PresenceHelpers.get_editing_role(:resource, resource_id, socket.id, current_user.id) do
        {:owner, presences} -> {:owner, presences}
        {:spectator, _owner_meta, presences} -> {:spectator, presences}
      end

    socket = assign(socket, editing_role: editing_role, presences: presences)

    # If we were promoted to owner
    socket = if old_role == :spectator && editing_role == :owner do
      put_flash(socket, :info, "You are now editing this resource")
    else
      socket
    end

    {:noreply, socket}
  end

  # Handle form changes broadcast from owner
  @impl true
  def handle_info({:resource_form_change, form_key, payload, _source}, socket) do
    if form_key == "resource_#{socket.assigns.resource.id}" && socket.assigns.editing_role == :spectator do
      case Map.get(payload, :changeset_params) do
        params when not is_nil(params) ->
          changeset = MyContext.change_resource(socket.assigns.resource, params)
          {:noreply, assign(socket, changeset: changeset)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # No terminate/2 needed - Phoenix.Presence cleans up automatically!
end
```

---

## Troubleshooting

### Issue: Changes Not Appearing for Spectators

**Symptom:** Owner types but spectators don't see updates.

**Causes:**
1. Not subscribed to presence changes
2. Not updating presence metadata
3. `handle_info/2` for `presence_diff` not implemented

**Solution:**
```elixir
# In mount/3 - verify subscription
if connected?(socket) do
  PresenceHelpers.subscribe_to_editing(:resource, id)
end

# In handle_event("validate") - verify broadcasting
if socket.assigns.editing_role == :owner do
  Events.broadcast_resource_form_change("resource_#{id}", %{
    changeset_params: params
  })
end

# Verify handle_info for presence_diff
@impl true
def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
  # Recalculate role when someone joins/leaves
  current_user = socket.assigns.current_user

  case PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id) do
    {:owner, _presences} -> assign(socket, editing_role: :owner)
    {:spectator, _owner_meta, _presences} -> assign(socket, editing_role: :spectator)
  end
  |> then(&{:noreply, &1})
end

# Verify handle_info for form changes
@impl true
def handle_info({:resource_form_change, form_key, payload, _source}, socket) do
  if form_key == "resource_#{id}" && socket.assigns.editing_role == :spectator do
    case Map.get(payload, :changeset_params) do
      params when not is_nil(params) ->
        changeset = MyContext.change_resource(resource, params)
        {:noreply, assign(socket, changeset: changeset)}
      _ ->
        {:noreply, socket}
    end
  else
    {:noreply, socket}
  end
end
```

### Issue: Wrong Person is Owner

**Symptom:** User B is owner but User A joined first.

**Cause:** Phoenix.Presence sorts by `joined_at` timestamp internally.

**Solution:** This should work automatically. If not:
```elixir
# Debug: Check presence list order
presences = PresenceHelpers.get_sorted_presences(:resource, id)
IO.inspect(presences, label: "Presences (sorted by joined_at)")

# Verify your socket_id matches
editing_role = PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id)
IO.inspect({socket.id, editing_role}, label: "My socket_id and role")
```

### Issue: Promoted to Owner But Can't Edit

**Symptom:** User promoted to owner but form fields still disabled.

**Cause:** Not updating UI when role changes.

**Solution:**
```elixir
# In handle_info(%{event: "presence_diff"})
editing_role = PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id)
old_role = socket.assigns.editing_role

socket = assign(socket, editing_role: editing_role)

# Show notification
socket = if old_role == :spectator && editing_role == :owner do
  put_flash(socket, :info, "You are now editing")
else
  socket
end

# Template should react to @editing_role
# <.input field={@form[:name]} disabled={@editing_role == :spectator} />
```

### Issue: Late Joiner Doesn't See Owner's Changes

**Symptom:** User B joins but sees blank form, not User A's work-in-progress.

**Cause:** Not syncing with owner's metadata on mount.

**Solution:**
```elixir
# In mount/3, after tracking presence
if connected?(socket) do
  current_user = socket.assigns.current_user

  PresenceHelpers.track_editing_session(:resource, id, socket, current_user)

  {editing_role, _presences} =
    case PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id) do
      {:owner, presences} -> {:owner, presences}
      {:spectator, _owner_meta, presences} -> {:spectator, presences}
    end

  # Sync with owner if we're a spectator
  socket = if editing_role == :spectator do
    case PresenceHelpers.get_lock_owner(:resource, id) do
      %{form_state: %{changeset_params: params}} when params != %{} ->
        changeset = MyContext.change_resource(resource, params)
        assign(socket, changeset: changeset)
      _ ->
        socket
    end
  else
    socket
  end

  {:ok, assign(socket, editing_role: editing_role)}
end
```

### Issue: Presence Timeout (5 seconds feels slow)

**Symptom:** When owner leaves, it takes 5 seconds before next person promoted.

**Explanation:** This is **intentional** and configurable in `lib/phoenix_kit/entities/presence.ex`:

```elixir
use Phoenix.Presence,
  otp_app: :phoenix_kit,
  pubsub_server: :phoenix_kit_internal_pubsub,
  presence_opts: [timeout: 5_000]  # ← Adjust this value
```

**Trade-offs:**
- **Lower timeout (1-2 seconds):** Faster promotion, but more false positives from network hiccups
- **Higher timeout (10+ seconds):** More reliable, but slower role transitions

**Recommended:** Keep at 5 seconds for production use.

---

## Best Practices

### 1. Always Use PresenceHelpers, Not Phoenix.Presence Directly
```elixir
# ✅ Good - use PresenceHelpers
alias PhoenixKit.Entities.PresenceHelpers

PresenceHelpers.track_editing_session(:resource, id, socket, metadata)
editing_role = PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id)

# ❌ Bad - don't use Phoenix.Presence directly
alias PhoenixKit.Entities.Presence
Presence.track(socket.id, topic, socket.id, metadata)
```

### 2. Broadcast State Changes via PubSub Events
```elixir
# ✅ Good - broadcast changes via Events system
Events.broadcast_resource_form_change("resource_#{id}", %{
  changeset_params: params,
  last_updated: System.system_time(:millisecond)
})

# ❌ Bad - don't try to manually update presence metadata
# (Presence metadata is for user info, not real-time form state)
```

### 3. Use on_mount Hooks for Repeated Subscriptions
```elixir
# Instead of repeating this in every LiveView:
if connected?(socket) do
  Events.subscribe_to_entities()
end

# Create a hook and use it once
on_mount MyAppWeb.Live.Hooks
```

### 4. No Manual Cleanup Needed in terminate/2
```elixir
# ❌ OLD WAY (no longer needed):
@impl true
def terminate(_reason, socket) do
  Presence.untrack("editor:resource:#{id}:")
  Presence.clear_data("state:resource:#{id}")
  :ok
end

# ✅ NEW WAY (automatic cleanup):
# No terminate/2 callback needed!
# Phoenix.Presence automatically cleans up when LiveView dies
```

### 5. Handle Resource Deletion in handle_info
```elixir
def handle_info({:resource_deleted, resource_id}, socket) do
  if resource_id == socket.assigns.resource.id do
    {:noreply,
     socket
     |> put_flash(:error, "Resource deleted in another session")
     |> redirect(to: ~p"/admin/resources")}
  else
    {:noreply, socket}
  end
end
```

### 6. Always Disable Form Fields for Spectators
```elixir
# In templates, bind disabled state to editing_role
<.input
  field={@form[:name]}
  label="Name"
  disabled={@editing_role == :spectator}
/>

# In handle_event, guard against spectator edits
def handle_event("validate", params, socket) do
  if socket.assigns.editing_role == :owner do
    # Process changes
  else
    # Reject changes
    {:noreply, socket}
  end
end
```

### 7. Handle Both Presence Changes AND Form Broadcasts
```elixir
# Handle presence_diff for role changes
def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
  current_user = socket.assigns.current_user

  case PresenceHelpers.get_editing_role(:resource, id, socket.id, current_user.id) do
    {:owner, _presences} -> assign(socket, editing_role: :owner)
    {:spectator, _owner_meta, _presences} -> assign(socket, editing_role: :spectator)
  end
  |> then(&{:noreply, &1})
end

# Handle form changes broadcast from owner
def handle_info({:resource_form_change, form_key, payload, _source}, socket) do
  if form_key == "resource_#{id}" && socket.assigns.editing_role == :spectator do
    case Map.get(payload, :changeset_params) do
      params when not is_nil(params) ->
        changeset = MyContext.change_resource(resource, params)
        {:noreply, assign(socket, changeset: changeset)}
      _ ->
        {:noreply, socket}
    end
  else
    {:noreply, socket}
  end
end
```

---

## Architecture Summary

```
┌──────────────────────────────────────────────────────────────────────┐
│  LiveView Page (entity_form.ex)                                      │
│                                                                       │
│  mount/3:                                                             │
│    - Subscribe to presence changes via PresenceHelpers               │
│    - Track editing session with metadata                             │
│    - Determine role (:owner or :spectator)                           │
│    - Sync with owner's metadata if spectator                         │
│                                                                       │
│  handle_event("validate"):                                           │
│    - Guard: Only :owner can edit                                     │
│    - Update changeset                                                │
│    - Update presence metadata (spectators see via presence_diff)     │
│                                                                       │
│  handle_info(%{event: "presence_diff"}):                             │
│    - Recalculate role (someone joined/left)                          │
│    - Notify if promoted to :owner                                    │
│    - Sync with owner's metadata if :spectator                        │
│                                                                       │
│  No terminate/2 needed!                                              │
│    - Phoenix.Presence auto-cleans up                                 │
└──────────────────────────────────────────────────────────────────────┘
                              ↓              ↑
                              ↓              ↑
        ┌─────────────────────────────────────────────────────┐
        │  PresenceHelpers (Utility Module)                   │
        │                                                      │
        │  - track_editing_session(type, id, socket, user)    │
        │  - get_editing_role(type, id, socket_id, user_id)   │
        │    → {:owner, presences} or {:spectator, meta, presences} │
        │  - get_lock_owner(type, id)                         │
        │  - get_sorted_presences(type, id)                   │
        │  - get_spectators(type, id)                         │
        │  - subscribe_to_editing(type, id)                   │
        └─────────────────────────────────────────────────────┘
                              ↓              ↑
                              ↓              ↑
        ┌─────────────────────────────────────────────────────┐
        │  Phoenix.Presence (CRDT-based)                       │
        │                                                      │
        │  - Distributed presence tracking                     │
        │  - Automatic cleanup (5s timeout)                   │
        │  - Metadata storage (changeset_params)              │
        │  - FIFO ordering by joined_at                       │
        │  - Broadcasts presence_diff events                   │
        └─────────────────────────────────────────────────────┘
                              ↓              ↑
                              ↓              ↑
        ┌─────────────────────────────────────────────────────┐
        │  Events (PubSub for Lifecycle Events)                │
        │                                                      │
        │  - subscribe_to_entities()                           │
        │  - broadcast_entity_created/updated/deleted()        │
        │  - broadcast_data_created/updated/deleted()          │
        └─────────────────────────────────────────────────────┘
                              ↓              ↑
                              ↓              ↑
        ┌─────────────────────────────────────────────────────┐
        │  Context (entities.ex)                               │
        │                                                      │
        │  - create_entity/update_entity/delete_entity         │
        │  - notify_entity_event() after DB operations         │
        └─────────────────────────────────────────────────────┘

Key Concepts:
  • First in list = owner (can edit)
  • Everyone else = spectator (read-only, sees real-time updates)
  • Owner's metadata contains changeset_params
  • Spectators sync with owner's metadata via presence_diff
  • Automatic promotion when owner leaves (within 5 seconds)
  • No manual locks, no manual cleanup, no race conditions
```

---

## Reference Files

### Core Real-time Systems

- **Events System:** `lib/phoenix_kit/entities/events.ex`
  - PubSub broadcasting for entity/data lifecycle events
  - Subscribe/broadcast functions for real-time updates

- **Phoenix.Presence:** `lib/phoenix_kit/entities/presence.ex`
  - CRDT-based distributed presence tracking
  - 5-second timeout configuration
  - Automatic cleanup when LiveView processes terminate

- **PresenceHelpers:** `lib/phoenix_kit/entities/presence_helpers.ex`
  - High-level utilities for collaborative editing
  - "First in list = owner" logic
  - Metadata management for state synchronization

- **SimplePresence (Admin Only):** `lib/phoenix_kit/admin/simple_presence.ex`
  - Lightweight session tracking for admin dashboard
  - NOT used for collaborative editing

### LiveView Examples

- **Hooks:** `lib/phoenix_kit_web/live/modules/entities/hooks.ex`
  - Centralized subscriptions with `on_mount`

- **List Page:** `lib/phoenix_kit_web/live/modules/entities/entities.ex`
  - Real-time list updates via Events system

- **Detail Page:** `lib/phoenix_kit_web/live/modules/entities/data_navigator.ex`
  - Real-time detail updates and deletion handling

- **Collaborative Form (Entity):** `lib/phoenix_kit_web/live/modules/entities/entity_form.ex`
  - Full collaborative editing implementation
  - Owner/spectator roles
  - Real-time state synchronization

- **Collaborative Form (Data):** `lib/phoenix_kit_web/live/modules/entities/data_form.ex`
  - Data record collaborative editing
  - Same patterns as entity_form.ex

---

## Next Steps

1. Read the reference files to see real implementations
2. Copy patterns that match your use case
3. Test with multiple browser tabs to verify real-time updates
4. Check the troubleshooting section if issues arise
5. Follow best practices for clean, maintainable code
