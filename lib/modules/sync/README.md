# DB Sync Module

The PhoenixKit DB Sync module provides peer-to-peer data synchronization between PhoenixKit instances using permanent, token-based connections. Sync data between development and production environments, between different websites, or create database backups - all through secure authenticated connections.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/db-sync`
- **Manage Connections**: `/{prefix}/admin/db-sync/connections`
- **Transfer History**: `/{prefix}/admin/db-sync/history`

## Current Architecture

### Automatic Cross-Site Registration (V35+)

The DB Sync module uses **permanent connections** with automatic cross-site registration:

1. **Sender creates a connection** pointing to a remote site's URL
2. **System automatically notifies** the remote site via API
3. **Remote site registers the connection** based on their incoming settings:
   - **Auto Accept**: Connection activates immediately
   - **Require Approval**: Connection appears as pending
   - **Require Password**: Only accepts with correct password
   - **Deny All**: Rejects the connection request
4. **Both sites have matching connection records** for data sync
5. **All transfers are tracked** in the history with full audit trail

### Connection Types

- **Sender**: "I allow this remote site to pull data from me"
- **Receiver**: "I can pull data from this remote site" (auto-created via API)

When you create a sender connection, the remote site automatically receives a corresponding receiver connection.

## Core Features

- **Token-Based Authentication**: Secure tokens for persistent connections
- **Approval Modes**: Auto-approve, require approval, or per-table approval
- **Access Controls**: Allowed/excluded tables, download limits, record limits
- **Security Features**: IP whitelist, time-of-day restrictions, expiration dates
- **Transfer Tracking**: Full history of all data transfers with statistics
- **Audit Trail**: Track who created, approved, suspended, or revoked connections

## Connection Settings

### Sender-Side Controls

| Setting | Description |
|---------|-------------|
| **Approval Mode** | `auto_approve`, `require_approval`, or `per_table` |
| **Allowed Tables** | Whitelist of tables the receiver can access |
| **Excluded Tables** | Blacklist of tables to hide from receiver |
| **Auto-Approve Tables** | Tables that don't need approval (when mode is `per_table`) |
| **Max Downloads** | Limit total number of transfer sessions |
| **Max Records Total** | Limit total records that can be downloaded |
| **Max Records Per Request** | Limit records per single request (default: 10,000) |
| **Rate Limit** | Requests per minute limit (default: 60) |
| **Download Password** | Optional password required for each transfer |
| **IP Whitelist** | Only allow connections from specific IPs |
| **Allowed Hours** | Time-of-day restrictions (e.g., only 2am-5am) |
| **Expiration Date** | Auto-expire the connection after a date |

### Connection Statuses

| Status | Description |
|--------|-------------|
| **Pending** | Just created, awaiting activation |
| **Active** | Ready to accept connections |
| **Suspended** | Temporarily disabled (can be reactivated) |
| **Revoked** | Permanently disabled |
| **Expired** | Auto-expired due to limits or date |

## Workflow

### Setting Up a Sender Connection

1. Navigate to `/{prefix}/admin/db-sync/connections`
2. Click "New Connection"
3. Enter a name and the remote site's URL
4. Configure access controls (approval mode, tables, limits)
5. Save - the connection is created and token generated
6. **The remote site is notified automatically!**
   - If successful, the connection appears in their list
   - Based on their settings, it may be auto-approved or pending
7. If notification fails, share the token manually as a fallback

### What Happens on the Remote Site

When you create a sender connection:
- Your site calls `POST {remote_url}/phoenix_kit/db-sync/api/register-connection`
- The remote site creates a matching receiver connection
- Based on their incoming mode:
  - **Auto Accept**: Ready to use immediately
  - **Require Approval**: Admin must approve in their connections list
  - **Require Password**: You need to provide their password (not yet in UI)
  - **Deny All**: Connection is rejected

### Remote Site Pulling Data

The remote site uses the token when making API calls or WebSocket connections to authenticate and pull data.

## Programmatic API

### Connection Management

```elixir
alias PhoenixKit.Modules.Sync.Connections

# Create a sender connection
{:ok, connection} = Connections.create_connection(%{
  name: "Production Backup",
  direction: "sender",
  site_url: "https://backup.example.com",
  approval_mode: "auto_approve",
  allowed_tables: ["users", "posts"],
  max_downloads: 100,
  created_by: current_user.id
})

# The token is returned in connection.auth_token (only on create)
token = connection.auth_token

# Approve a pending connection
{:ok, connection} = Connections.approve_connection(connection, admin_user_id)

# Suspend a connection
{:ok, connection} = Connections.suspend_connection(connection, admin_user_id, "Security audit")

# Reactivate a suspended connection
{:ok, connection} = Connections.reactivate_connection(connection, admin_user_id)

# Revoke permanently
{:ok, connection} = Connections.revoke_connection(connection, admin_user_id, "No longer needed")

# Validate a token (used by receiver when connecting)
case Connections.validate_connection(token, client_ip) do
  {:ok, connection} -> # Token is valid, connection is active
  {:error, :invalid_token} -> # Token doesn't exist
  {:error, :connection_expired} -> # Expired or revoked
  {:error, :download_limit_exceeded} -> # Max downloads reached
  {:error, :ip_not_whitelisted} -> # IP not in whitelist
  {:error, :outside_allowed_hours} -> # Outside time window
end
```

### Transfer Tracking

```elixir
alias PhoenixKit.Modules.Sync.Transfers

# Record a transfer
{:ok, transfer} = Transfers.create_transfer(%{
  direction: "send",
  connection_id: connection.id,
  table_name: "users",
  records_transferred: 150,
  bytes_transferred: 45000,
  status: "completed"
})

# Get transfer history
transfers = Transfers.list_transfers(
  connection_id: connection.id,
  direction: "send",
  status: "completed"
)

# Get statistics for a connection
stats = Transfers.connection_stats(connection.id)
# => %{total_transfers: 25, total_records: 5000, total_bytes: 1500000}
```

## Incoming Connection Settings

Control how your site handles connection requests from other sites:

| Mode | Behavior |
|------|----------|
| **Auto Accept** | Incoming connections activate immediately |
| **Require Approval** | Connections appear as pending, need manual approval |
| **Require Password** | Sender must provide correct password |
| **Deny All** | Reject all incoming connection requests |

Configure these settings at `/{prefix}/admin/db-sync`.

### API Endpoints

The following API endpoints handle cross-site communication:

- `POST /{prefix}/db-sync/api/register-connection` - Register incoming connection
- `GET /{prefix}/db-sync/api/status` - Check DB Sync module status

## Future Plans

### Auto-Sync Scheduling (Planned)

Connections have fields for auto-sync but the scheduler isn't implemented yet:
- `auto_sync_enabled`: Enable automatic periodic sync
- `auto_sync_tables`: Tables to sync automatically
- `auto_sync_interval_minutes`: How often to sync

## Database Tables (V37, renamed in V44)

### phoenix_kit_sync_connections

Stores permanent connections with full configuration and audit trail.

### phoenix_kit_sync_transfers

Tracks all data transfers with:
- Direction (send/receive)
- Connection reference
- Table name and record counts
- Approval workflow fields
- Request context (IP, user agent)
- Timestamps and metadata

## Security Considerations

- **Token Security**: Tokens are hashed in database, only shown once on creation
- **Optional Password**: Additional password can be required per-transfer
- **IP Whitelisting**: Restrict connections to specific IP addresses
- **Time Restrictions**: Allow connections only during specific hours
- **Rate Limiting**: Prevent abuse with request limits
- **Audit Trail**: Full tracking of who did what and when

## Migration from Temporary Sessions

The V35 migration adds the permanent connections system. The old temporary session-based system (sender/receiver pages with session codes) is still available in the codebase but routes have been removed from the UI. It can be re-enabled if needed for quick ad-hoc transfers.

## Troubleshooting

### Connection Issues

1. Verify the token is correct and hasn't been regenerated
2. Check connection status is "active"
3. Verify IP is in whitelist (if configured)
4. Check time-of-day restrictions
5. Verify download/record limits haven't been exceeded

### Transfer Failures

1. Check transfer history for error messages
2. Verify table is in allowed tables (if configured)
3. Check approval status if approval mode is enabled
4. Review server logs for detailed errors

## Getting Help

1. Check this README for API documentation
2. Review transfer history for error details
3. Check connection settings for misconfiguration
4. Review server logs with `Logger.configure(level: :debug)`
