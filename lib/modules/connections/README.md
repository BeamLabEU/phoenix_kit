# Connections Module - Social Relationships System

## Implementation Checklist

### Phase 1: Database & Schemas
- [ ] Create migration `v34.ex` with all 3 tables
- [ ] Create `follow.ex` schema
- [ ] Create `connection.ex` schema
- [ ] Create `block.ex` schema

### Phase 2: Context Module (`PhoenixKit.Modules.Connections` - Public API)
- [ ] Create `connections.ex` with module management:
  - `PhoenixKit.Modules.Connections.enabled?/0`
  - `PhoenixKit.Modules.Connections.enable_system/0`
  - `PhoenixKit.Modules.Connections.disable_system/0`
- [ ] Implement public follow functions:
  - `PhoenixKit.Modules.Connections.follow/2`
  - `PhoenixKit.Modules.Connections.unfollow/2`
  - `PhoenixKit.Modules.Connections.following?/2`
  - `PhoenixKit.Modules.Connections.list_followers/1`
  - `PhoenixKit.Modules.Connections.list_following/1`
  - `PhoenixKit.Modules.Connections.followers_count/1`
  - `PhoenixKit.Modules.Connections.following_count/1`
- [ ] Implement public connection functions:
  - `PhoenixKit.Modules.Connections.request_connection/2`
  - `PhoenixKit.Modules.Connections.accept_connection/1`
  - `PhoenixKit.Modules.Connections.reject_connection/1`
  - `PhoenixKit.Modules.Connections.remove_connection/2`
  - `PhoenixKit.Modules.Connections.connected?/2`
  - `PhoenixKit.Modules.Connections.list_connections/1`
  - `PhoenixKit.Modules.Connections.list_pending_requests/1`
  - `PhoenixKit.Modules.Connections.list_sent_requests/1`
  - `PhoenixKit.Modules.Connections.connections_count/1`
  - `PhoenixKit.Modules.Connections.pending_requests_count/1`
- [ ] Implement public block functions:
  - `PhoenixKit.Modules.Connections.block/2`
  - `PhoenixKit.Modules.Connections.unblock/2`
  - `PhoenixKit.Modules.Connections.blocked?/2`
  - `PhoenixKit.Modules.Connections.blocked_by?/2`
  - `PhoenixKit.Modules.Connections.list_blocked/1`
  - `PhoenixKit.Modules.Connections.can_interact?/2`
- [ ] Implement public convenience function:
  - `PhoenixKit.Modules.Connections.get_relationship/2`
- [ ] Add block checking to follow/connection operations

### Phase 3: Admin LiveView
- [ ] Create `connections.ex` admin LiveView
- [ ] Create `connections.html.heex` template
- [ ] Add statistics dashboard
- [ ] Add moderation actions

### Phase 4: User-Facing LiveView
- [ ] Create `user_connections.ex` LiveView
- [ ] Create `user_connections.html.heex` template
- [ ] Implement Followers/Following/Connections/Requests/Blocked tabs
- [ ] Add action buttons (follow, connect, block)

### Phase 5: Integration
- [ ] Add routes to `integration.ex`
- [ ] Add to modules list in `modules.ex`
- [ ] Add Settings integration

---

## Overview

The Connections module provides a complete social relationships system for PhoenixKit applications with two types of relationships:

1. **Follows** - One-way relationships (User A follows User B, no consent needed)
2. **Connections** - Two-way mutual relationships (both users must accept)

Plus **blocking** functionality to prevent unwanted interactions.

## Terminology

- **Follow**: One-way, no consent required (like Twitter/Instagram)
- **Connection**: Two-way, requires acceptance from both parties (like LinkedIn)
- **Block**: Prevents all interaction (following, connecting, profile viewing)

---

## Database Schema

### Table: `phoenix_kit_user_follows`

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| follower_id | bigint | User who is following (FK to users) |
| followed_id | bigint | User being followed (FK to users) |
| inserted_at | naive_datetime | When follow was created |

**Indexes:** Unique on `(follower_id, followed_id)`, index on `followed_id`, index on `follower_id`

### Table: `phoenix_kit_user_connections`

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| requester_id | bigint | User who initiated request |
| recipient_id | bigint | User who received request |
| status | string | "pending", "accepted", "rejected" |
| requested_at | naive_datetime | When request was sent |
| responded_at | naive_datetime | When recipient responded |
| inserted_at | naive_datetime | Created timestamp |
| updated_at | naive_datetime | Updated timestamp |

**Indexes:** Unique on sorted user pair, index on `(recipient_id, status)`

### Table: `phoenix_kit_user_blocks`

| Column | Type | Description |
|--------|------|-------------|
| id | UUIDv7 | Primary key |
| blocker_id | bigint | User who blocked |
| blocked_id | bigint | User who is blocked |
| reason | string | Optional reason (nullable) |
| inserted_at | naive_datetime | When block was created |

**Indexes:** Unique on `(blocker_id, blocked_id)`, index on `blocked_id`

---

## Public API: `PhoenixKit.Modules.Connections`

**This is a PUBLIC API** - all functions are available to parent applications for use in their own views, components, and logic.

### Module Management

```elixir
PhoenixKit.Modules.Connections.enabled?()
PhoenixKit.Modules.Connections.enable_system()
PhoenixKit.Modules.Connections.disable_system()
```

### Follows

```elixir
# Create/remove follows
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
# Connection requests
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
# Create/remove blocks
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
  README.md              # This documentation
  connections.ex         # Main context API
  follow.ex              # Follow schema
  connection.ex          # Connection schema
  block.ex               # Block schema

lib/phoenix_kit_web/live/modules/connections/
  connections.ex         # Admin: overview/moderation
  connections.html.heex
  user_connections.ex    # User: manage own connections
  user_connections.html.heex

lib/phoenix_kit/migrations/postgres/
  v34.ex                 # Migration for all connection tables
```

---

## Admin Interface

Available at `{prefix}/admin/modules/connections`:

- Overview statistics (total follows, connections, blocks)
- Searchable list of all relationships
- Moderation actions (remove connections/follows)
- Module enable/disable toggle

## User Interface

Available at `{prefix}/profile/connections` (or integrated into parent app):

- **Followers** tab - Users who follow you
- **Following** tab - Users you follow
- **Connections** tab - Mutual connections
- **Requests** tab - Pending incoming/outgoing requests
- **Blocked** tab - Users you've blocked
