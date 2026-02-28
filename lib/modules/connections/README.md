# Connections Module - Social Relationships System

## Overview

The Connections module provides a complete social relationships system for PhoenixKit applications with two types of relationships:

1. **Follows** - One-way relationships (User A follows User B, no consent needed)
2. **Connections** - Two-way mutual relationships (both users must accept)

Plus **blocking** functionality to prevent unwanted interactions.

## Architecture

Each relationship type uses a **dual-table pattern**:

- **Main table**: Stores only the **current state** (one row per user pair)
- **History table**: Logs all **activity over time** for auditing and activity feeds

This design keeps the main tables lean and fast while preserving a complete audit trail.

## Terminology

- **Follow**: One-way, no consent required (like Twitter/Instagram)
- **Connection**: Two-way, requires acceptance from both parties (like LinkedIn)
- **Block**: Prevents all interaction (following, connecting, profile viewing)

---

## Database Schema

### Main Tables (Current State)

#### Table: `phoenix_kit_user_follows`

Stores only ACTIVE follows. Row is deleted when user unfollows.

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| follower_uuid | UUID | User who is following (FK to users.uuid) |
| followed_uuid | UUID | User being followed (FK to users.uuid) |
| inserted_at | naive_datetime | When follow was created |

**Indexes:** Unique on `(follower_uuid, followed_uuid)`, index on `followed_uuid`, index on `follower_uuid`

#### Table: `phoenix_kit_user_connections`

Stores only CURRENT connection state per user pair. Status is "pending" or "accepted" only.
Rejected connections are deleted (not stored as "rejected").

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| requester_uuid | UUID | User who initiated request (FK to users.uuid) |
| recipient_uuid | UUID | User who received request (FK to users.uuid) |
| status | string | "pending" or "accepted" |
| requested_at | naive_datetime | When request was sent |
| responded_at | naive_datetime | When recipient responded |
| inserted_at | naive_datetime | Created timestamp |
| updated_at | naive_datetime | Updated timestamp |

**Indexes:** Index on `(recipient_uuid, status)`, index on `(requester_uuid, status)`

#### Table: `phoenix_kit_user_blocks`

Stores only ACTIVE blocks. Row is deleted when user unblocks.

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| blocker_uuid | UUID | User who blocked (FK to users.uuid) |
| blocked_uuid | UUID | User who is blocked (FK to users.uuid) |
| reason | string | Optional reason (nullable) |
| inserted_at | naive_datetime | When block was created |

**Indexes:** Unique on `(blocker_uuid, blocked_uuid)`, index on `blocked_uuid`

---

### History Tables (Activity Log)

#### Table: `phoenix_kit_user_follows_history`

Logs all follow/unfollow events.

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| follower_uuid | UUID | User who performed action (FK to users.uuid) |
| followed_uuid | UUID | Target user (FK to users.uuid) |
| action | string | "follow" or "unfollow" |
| inserted_at | naive_datetime | When action occurred |

#### Table: `phoenix_kit_user_connections_history`

Logs all connection events.

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| user_a_uuid | UUID | First user (normalized: lower UUID) (FK to users.uuid) |
| user_b_uuid | UUID | Second user (normalized: higher UUID) (FK to users.uuid) |
| actor_uuid | UUID | User who performed this action (FK to users.uuid) |
| action | string | "requested", "accepted", "rejected", "removed" |
| inserted_at | naive_datetime | When action occurred |

#### Table: `phoenix_kit_user_blocks_history`

Logs all block/unblock events.

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| blocker_uuid | UUID | User who performed action (FK to users.uuid) |
| blocked_uuid | UUID | Target user (FK to users.uuid) |
| action | string | "block" or "unblock" |
| reason | string | Reason (for block action) |
| inserted_at | naive_datetime | When action occurred |

---

## Public API: `PhoenixKit.Modules.Connections`

**This is a PUBLIC API** - all functions are available to parent applications for use in their own views, components, and logic.

### Module Management

```elixir
PhoenixKit.Modules.Connections.enabled?()
PhoenixKit.Modules.Connections.enable_system()
PhoenixKit.Modules.Connections.disable_system()
PhoenixKit.Modules.Connections.get_config()
PhoenixKit.Modules.Connections.get_stats()
```

### Follows

```elixir
# Create/remove follows (automatically logs to history)
follow(follower, followed)           # Create a follow relationship
unfollow(follower, followed)         # Remove a follow relationship

# Query follows
following?(follower, followed)       # Check if user A follows user B
list_followers(user)                 # Get all followers of a user
list_following(user)                 # Get all users a user follows
followers_count(user)                # Count followers
following_count(user)                # Count following
```

### Connections

```elixir
# Connection requests (automatically logs to history)
request_connection(requester, recipient)  # Send connection request
accept_connection(connection_id)          # Accept a pending request
reject_connection(connection_id)          # Reject a pending request
remove_connection(user_a, user_b)         # Remove existing connection

# Query connections
connected?(user_a, user_b)                # Check if two users are connected
list_connections(user)                    # Get all connections for a user
list_pending_requests(user)               # Get pending incoming requests
list_sent_requests(user)                  # Get pending outgoing requests
connections_count(user)                   # Count connections
pending_requests_count(user)              # Count pending incoming requests
```

### Blocks

```elixir
# Create/remove blocks (automatically logs to history)
block(blocker, blocked)              # Block a user
unblock(blocker, blocked)            # Remove a block

# Query blocks
blocked?(blocker, blocked)           # Check if user A blocked user B
blocked_by?(user, other)             # Check if user is blocked by other
list_blocked(user)                   # Get all users blocked by a user
can_interact?(user_a, user_b)        # Check if two users can interact
```

### Relationship Status (Convenience)

```elixir
# Get full relationship status between two users in one call
get_relationship(user_a, user_b)
# Returns:
%{
  following: true/false,              # A follows B
  followed_by: true/false,            # B follows A
  connected: true/false,              # mutual connection exists
  connection_pending: :sent/:received/nil,
  blocked: true/false,                # A blocked B
  blocked_by: true/false              # B blocked A
}
```

---

## Usage Examples

### In a User Profile Page

```elixir
# Get relationship for rendering follow/connect buttons
alias PhoenixKit.Modules.Connections

relationship = Connections.get_relationship(current_user, profile_user)

# Display counts
followers = Connections.followers_count(profile_user)
following = Connections.following_count(profile_user)
connections = Connections.connections_count(profile_user)
```

### In a LiveView

```elixir
def handle_event("follow", %{"user_id" => user_id}, socket) do
  target_user = get_user(user_id)

  case Connections.follow(socket.assigns.current_user, target_user) do
    {:ok, _follow} -> {:noreply, put_flash(socket, :info, "Now following!")}
    {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
  end
end

def handle_event("request_connection", %{"user_id" => user_id}, socket) do
  target_user = get_user(user_id)

  case Connections.request_connection(socket.assigns.current_user, target_user) do
    {:ok, _connection} -> {:noreply, put_flash(socket, :info, "Connection request sent!")}
    {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
  end
end
```

---

## Business Rules

### Following

- Cannot follow yourself
- Cannot follow if blocked (either direction)
- Instant, no approval needed

### Connections

- Cannot connect with yourself
- Cannot connect if blocked
- Requires acceptance from recipient
- If A requests B while B has pending request to A → auto-accept both

### Blocking

- Blocking removes any existing follow/connection between the users
- Blocked user cannot follow, connect, or view profile
- Blocking is one-way (A blocks B doesn't mean B blocks A)

---

## File Structure

```
lib/modules/connections/
  README.md                  # This documentation
  connections.ex             # Main context API
  follow.ex                  # Follow schema
  follow_history.ex          # Follow history schema
  connection.ex              # Connection schema
  connection_history.ex      # Connection history schema
  block.ex                   # Block schema
  block_history.ex           # Block history schema

lib/phoenix_kit_web/live/modules/connections/
  connections.ex             # Admin: overview/moderation
  connections.html.heex
  user_connections.ex        # User: manage own connections
  user_connections.html.heex

lib/phoenix_kit/migrations/postgres/
  v36.ex                     # Migration for all connection tables
```

---

## Admin Interface

Available at `{prefix}/admin/connections`:

- Overview statistics (total follows, connections, pending, blocks)
- Module enable/disable toggle
- Relationship type explanations
- Public API documentation

## User Interface

Available at `{prefix}/profile/connections`:

- **Followers** tab - Users who follow you
- **Following** tab - Users you follow (with unfollow button)
- **Connections** tab - Mutual connections (with remove button)
- **Requests** tab - Pending incoming/outgoing requests (with accept/reject buttons)
- **Blocked** tab - Users you've blocked (with unblock button)
