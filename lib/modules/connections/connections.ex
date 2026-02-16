defmodule PhoenixKit.Modules.Connections do
  @moduledoc """
  Connections module for PhoenixKit - Social Relationships System.

  Provides a complete social relationships system with two types of relationships:

  1. **Follows** - One-way relationships (User A follows User B, no consent needed)
  2. **Connections** - Two-way mutual relationships (both users must accept)

  Plus **blocking** functionality to prevent unwanted interactions.

  ## Public API

  This is a **PUBLIC API** - all functions are available to parent applications
  for use in their own views, components, and logic.

  ## Usage Examples

  ### In a User Profile Page

      alias PhoenixKit.Modules.Connections

      # Get relationship for rendering follow/connect buttons
      relationship = Connections.get_relationship(current_user, profile_user)

      # Display counts
      followers = Connections.followers_count(profile_user)
      following = Connections.following_count(profile_user)
      connections = Connections.connections_count(profile_user)

  ### In a LiveView

      def handle_event("follow", %{"user_id" => user_id}, socket) do
        target_user = get_user(user_id)

        case Connections.follow(socket.assigns.current_user, target_user) do
          {:ok, _follow} -> {:noreply, put_flash(socket, :info, "Now following!")}
          {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
        end
      end

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
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Connections.Block
  alias PhoenixKit.Modules.Connections.BlockHistory
  alias PhoenixKit.Modules.Connections.Connection
  alias PhoenixKit.Modules.Connections.ConnectionHistory
  alias PhoenixKit.Modules.Connections.Follow
  alias PhoenixKit.Modules.Connections.FollowHistory
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth

  # ===== MODULE STATUS =====

  @doc """
  Checks if the Connections module is enabled.

  ## Examples

      iex> PhoenixKit.Modules.Connections.enabled?()
      true
  """
  def enabled? do
    Settings.get_boolean_setting("connections_enabled", false)
  end

  @doc """
  Enables the Connections module.
  """
  def enable_system do
    Settings.update_boolean_setting("connections_enabled", true)
  end

  @doc """
  Disables the Connections module.
  """
  def disable_system do
    Settings.update_boolean_setting("connections_enabled", false)
  end

  @doc """
  Returns the Connections module configuration.

  Used by the Modules admin page to display module status and statistics.

  ## Returns

  A map containing:
  - `:enabled` - Whether the module is enabled
  - `:follows_count` - Total number of follows
  - `:connections_count` - Total number of accepted connections
  - `:pending_count` - Total number of pending connection requests
  - `:blocks_count` - Total number of blocks

  ## Examples

      iex> Connections.get_config()
      %{
        enabled: true,
        follows_count: 100,
        connections_count: 50,
        pending_count: 5,
        blocks_count: 3
      }
  """
  def get_config do
    %{
      enabled: enabled?(),
      follows_count: get_total_follows_count(),
      connections_count: get_total_connections_count(),
      pending_count: get_total_pending_count(),
      blocks_count: get_total_blocks_count()
    }
  end

  @doc """
  Returns statistics for the admin overview page.

  ## Returns

  A map containing:
  - `:follows` - Total follows across all users
  - `:connections` - Total accepted connections
  - `:pending` - Total pending connection requests
  - `:blocks` - Total blocks

  ## Examples

      iex> Connections.get_stats()
      %{follows: 100, connections: 50, pending: 5, blocks: 3}
  """
  def get_stats do
    %{
      follows: get_total_follows_count(),
      connections: get_total_connections_count(),
      pending: get_total_pending_count(),
      blocks: get_total_blocks_count()
    }
  end

  # ===== FOLLOWS =====

  @doc """
  Creates a follow relationship.

  User A follows User B. No consent is required from User B.

  ## Parameters

  - `follower` - The user who is following (struct with uuid/id, or integer/UUID string)
  - `followed` - The user being followed (struct with uuid/id, or integer/UUID string)

  ## Returns

  - `{:ok, %Follow{}}` - Follow created successfully
  - `{:error, :blocked}` - Cannot follow due to block
  - `{:error, :self_follow}` - Cannot follow yourself
  - `{:error, %Ecto.Changeset{}}` - Validation error

  ## Examples

      iex> Connections.follow(current_user, target_user)
      {:ok, %Follow{}}

      iex> Connections.follow(user, user)
      {:error, :self_follow}
  """
  def follow(follower, followed) do
    follower_uuid = get_user_uuid(follower)
    followed_uuid = get_user_uuid(followed)

    cond do
      follower_uuid == followed_uuid ->
        {:error, :self_follow}

      blocked?(followed_uuid, follower_uuid) || blocked?(follower_uuid, followed_uuid) ->
        {:error, :blocked}

      following?(follower_uuid, followed_uuid) ->
        {:error, :already_following}

      true ->
        follower_id = resolve_user_id(follower)
        followed_id = resolve_user_id(followed)

        repo().transaction(fn ->
          case %Follow{}
               |> Follow.changeset(%{
                 follower_uuid: follower_uuid,
                 followed_uuid: followed_uuid,
                 follower_id: follower_id,
                 followed_id: followed_id
               })
               |> repo().insert() do
            {:ok, follow} ->
              log_follow_history(
                follower_uuid,
                followed_uuid,
                follower_id,
                followed_id,
                "follow"
              )

              follow

            {:error, changeset} ->
              repo().rollback(changeset)
          end
        end)
    end
  end

  @doc """
  Removes a follow relationship.

  ## Parameters

  - `follower` - The user who is following
  - `followed` - The user being followed

  ## Returns

  - `{:ok, %Follow{}}` - Follow removed successfully
  - `{:error, :not_following}` - No follow relationship exists
  """
  def unfollow(follower, followed) do
    follower_uuid = get_user_uuid(follower)
    followed_uuid = get_user_uuid(followed)

    case get_follow(follower_uuid, followed_uuid) do
      nil ->
        {:error, :not_following}

      follow ->
        repo().transaction(fn ->
          case repo().delete(follow) do
            {:ok, deleted} ->
              log_follow_history(
                follow.follower_uuid,
                follow.followed_uuid,
                follow.follower_id,
                follow.followed_id,
                "unfollow"
              )

              deleted

            {:error, changeset} ->
              repo().rollback(changeset)
          end
        end)
    end
  end

  @doc """
  Checks if user A is following user B.

  ## Examples

      iex> Connections.following?(user_a, user_b)
      true
  """
  def following?(follower, followed) do
    follower_uuid = get_user_uuid(follower)
    followed_uuid = get_user_uuid(followed)

    Follow
    |> where([f], f.follower_uuid == ^follower_uuid and f.followed_uuid == ^followed_uuid)
    |> repo().exists?()
  end

  @doc """
  Returns all followers of a user.

  ## Options

  - `:preload` - Preload the follower user (default: true)
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip

  ## Examples

      iex> Connections.list_followers(user)
      [%Follow{follower: %User{}}]
  """
  def list_followers(user, opts \\ []) do
    user_uuid = get_user_uuid(user)
    preload = Keyword.get(opts, :preload, true)

    query =
      Follow
      |> where([f], f.followed_uuid == ^user_uuid)
      |> order_by([f], desc: f.inserted_at)
      |> maybe_limit(opts[:limit])
      |> maybe_offset(opts[:offset])

    query = if preload, do: preload(query, [:follower]), else: query

    repo().all(query)
  end

  @doc """
  Returns all users that a user is following.

  ## Options

  - `:preload` - Preload the followed user (default: true)
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip

  ## Examples

      iex> Connections.list_following(user)
      [%Follow{followed: %User{}}]
  """
  def list_following(user, opts \\ []) do
    user_uuid = get_user_uuid(user)
    preload = Keyword.get(opts, :preload, true)

    query =
      Follow
      |> where([f], f.follower_uuid == ^user_uuid)
      |> order_by([f], desc: f.inserted_at)
      |> maybe_limit(opts[:limit])
      |> maybe_offset(opts[:offset])

    query = if preload, do: preload(query, [:followed]), else: query

    repo().all(query)
  end

  @doc """
  Returns the count of followers for a user.

  ## Examples

      iex> Connections.followers_count(user)
      42
  """
  def followers_count(user) do
    user_uuid = get_user_uuid(user)

    Follow
    |> where([f], f.followed_uuid == ^user_uuid)
    |> repo().aggregate(:count)
  end

  @doc """
  Returns the count of users that a user is following.

  ## Examples

      iex> Connections.following_count(user)
      100
  """
  def following_count(user) do
    user_uuid = get_user_uuid(user)

    Follow
    |> where([f], f.follower_uuid == ^user_uuid)
    |> repo().aggregate(:count)
  end

  # ===== CONNECTIONS =====

  @doc """
  Sends a connection request from requester to recipient.

  If recipient already has a pending request to requester, both requests
  are automatically accepted.

  ## Parameters

  - `requester` - The user sending the request
  - `recipient` - The user receiving the request

  ## Returns

  - `{:ok, %Connection{status: "pending"}}` - Request sent
  - `{:ok, %Connection{status: "accepted"}}` - Auto-accepted (mutual request)
  - `{:error, :blocked}` - Cannot connect due to block
  - `{:error, :self_connection}` - Cannot connect with yourself
  - `{:error, :already_connected}` - Already connected
  - `{:error, :pending_request}` - Already has pending request
  """
  def request_connection(requester, recipient) do
    requester_uuid = get_user_uuid(requester)
    recipient_uuid = get_user_uuid(recipient)

    cond do
      requester_uuid == recipient_uuid ->
        {:error, :self_connection}

      blocked?(requester_uuid, recipient_uuid) || blocked?(recipient_uuid, requester_uuid) ->
        {:error, :blocked}

      connected?(requester_uuid, recipient_uuid) ->
        {:error, :already_connected}

      true ->
        # Check if there's a pending request from recipient to requester
        case get_pending_request_between(recipient_uuid, requester_uuid) do
          %Connection{} = existing ->
            # Auto-accept the existing request (mutual request)
            # The accept_connection will log the "accepted" history entry
            accept_connection_with_actor(existing, requester_uuid)

          nil ->
            # Check if there's already a pending request from requester to recipient
            case get_pending_request_between(requester_uuid, recipient_uuid) do
              %Connection{} ->
                {:error, :pending_request}

              nil ->
                # Create new pending request
                requester_id = resolve_user_id(requester)
                recipient_id = resolve_user_id(recipient)

                create_pending_connection(
                  requester_uuid,
                  recipient_uuid,
                  requester_id,
                  recipient_id
                )
            end
        end
    end
  end

  @doc """
  Accepts a pending connection request.

  ## Parameters

  - `connection_or_id` - Connection struct or connection ID

  ## Returns

  - `{:ok, %Connection{status: "accepted"}}` - Request accepted
  - `{:error, :not_found}` - Connection not found
  - `{:error, :not_pending}` - Connection is not pending
  """
  def accept_connection(%Connection{status: "pending"} = connection) do
    # When called directly, the actor is the recipient (who accepts)
    accept_connection_with_actor(connection, connection.recipient_uuid)
  end

  def accept_connection(%Connection{}), do: {:error, :not_pending}

  def accept_connection(connection_id) when is_binary(connection_id) do
    case PhoenixKit.UUID.get(Connection, connection_id) do
      nil -> {:error, :not_found}
      connection -> accept_connection(connection)
    end
  end

  # Internal function that tracks the actor for history
  defp accept_connection_with_actor(%Connection{status: "pending"} = connection, actor_uuid) do
    # Resolve actor integer ID from the connection struct to avoid DB lookup
    actor_id =
      cond do
        actor_uuid == connection.requester_uuid -> connection.requester_id
        actor_uuid == connection.recipient_uuid -> connection.recipient_id
        true -> resolve_user_id(actor_uuid)
      end

    repo().transaction(fn ->
      case connection
           |> Connection.status_changeset(%{status: "accepted"})
           |> repo().update() do
        {:ok, updated} ->
          log_connection_history(
            connection.requester_uuid,
            connection.recipient_uuid,
            actor_uuid,
            connection.requester_id,
            connection.recipient_id,
            actor_id,
            "accepted"
          )

          updated

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  defp accept_connection_with_actor(%Connection{}, _actor_uuid), do: {:error, :not_pending}

  @doc """
  Rejects a pending connection request.

  ## Parameters

  - `connection_or_id` - Connection struct or connection ID

  ## Returns

  - `{:ok, %Connection{status: "rejected"}}` - Request rejected
  - `{:error, :not_found}` - Connection not found
  - `{:error, :not_pending}` - Connection is not pending
  """
  def reject_connection(%Connection{status: "pending"} = connection) do
    repo().transaction(fn ->
      # Log history before deleting (rejected connections are removed from main table)
      log_connection_history(
        connection.requester_uuid,
        connection.recipient_uuid,
        connection.recipient_uuid,
        connection.requester_id,
        connection.recipient_id,
        connection.recipient_id,
        "rejected"
      )

      # Delete instead of updating to rejected status
      case repo().delete(connection) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  def reject_connection(%Connection{}), do: {:error, :not_pending}

  def reject_connection(connection_id) when is_binary(connection_id) do
    case PhoenixKit.UUID.get(Connection, connection_id) do
      nil -> {:error, :not_found}
      connection -> reject_connection(connection)
    end
  end

  @doc """
  Removes an existing connection between two users.

  Either user can remove the connection.

  ## Parameters

  - `user_a` - First user
  - `user_b` - Second user

  ## Returns

  - `{:ok, %Connection{}}` - Connection removed
  - `{:error, :not_connected}` - No connection exists
  """
  def remove_connection(user_a, user_b) do
    user_a_uuid = get_user_uuid(user_a)
    user_b_uuid = get_user_uuid(user_b)

    case get_accepted_connection(user_a_uuid, user_b_uuid) do
      nil ->
        {:error, :not_connected}

      connection ->
        user_a_id = resolve_user_id(user_a)

        repo().transaction(fn ->
          # Log history - user_a is the actor (the one removing)
          log_connection_history(
            connection.requester_uuid,
            connection.recipient_uuid,
            user_a_uuid,
            connection.requester_id,
            connection.recipient_id,
            user_a_id,
            "removed"
          )

          case repo().delete(connection) do
            {:ok, deleted} -> deleted
            {:error, changeset} -> repo().rollback(changeset)
          end
        end)
    end
  end

  @doc """
  Checks if two users are connected (mutual connection exists).

  ## Examples

      iex> Connections.connected?(user_a, user_b)
      true
  """
  def connected?(user_a, user_b) do
    user_a_uuid = get_user_uuid(user_a)
    user_b_uuid = get_user_uuid(user_b)

    Connection
    |> where([c], c.status == "accepted")
    |> where(
      [c],
      (c.requester_uuid == ^user_a_uuid and c.recipient_uuid == ^user_b_uuid) or
        (c.requester_uuid == ^user_b_uuid and c.recipient_uuid == ^user_a_uuid)
    )
    |> repo().exists?()
  end

  @doc """
  Returns all connections for a user.

  ## Options

  - `:preload` - Preload the other user (default: true)
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip

  ## Examples

      iex> Connections.list_connections(user)
      [%Connection{requester: %User{}, recipient: %User{}}]
  """
  def list_connections(user, opts \\ []) do
    user_uuid = get_user_uuid(user)
    preload = Keyword.get(opts, :preload, true)

    query =
      Connection
      |> where([c], c.status == "accepted")
      |> where([c], c.requester_uuid == ^user_uuid or c.recipient_uuid == ^user_uuid)
      |> order_by([c], desc: c.responded_at)
      |> maybe_limit(opts[:limit])
      |> maybe_offset(opts[:offset])

    query = if preload, do: preload(query, [:requester, :recipient]), else: query

    repo().all(query)
  end

  @doc """
  Returns pending incoming connection requests for a user.

  ## Options

  - `:preload` - Preload the requester user (default: true)
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip
  """
  def list_pending_requests(user, opts \\ []) do
    user_uuid = get_user_uuid(user)
    preload = Keyword.get(opts, :preload, true)

    query =
      Connection
      |> where([c], c.recipient_uuid == ^user_uuid and c.status == "pending")
      |> order_by([c], desc: c.requested_at)
      |> maybe_limit(opts[:limit])
      |> maybe_offset(opts[:offset])

    query = if preload, do: preload(query, [:requester]), else: query

    repo().all(query)
  end

  @doc """
  Returns pending outgoing connection requests sent by a user.

  ## Options

  - `:preload` - Preload the recipient user (default: true)
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip
  """
  def list_sent_requests(user, opts \\ []) do
    user_uuid = get_user_uuid(user)
    preload = Keyword.get(opts, :preload, true)

    query =
      Connection
      |> where([c], c.requester_uuid == ^user_uuid and c.status == "pending")
      |> order_by([c], desc: c.requested_at)
      |> maybe_limit(opts[:limit])
      |> maybe_offset(opts[:offset])

    query = if preload, do: preload(query, [:recipient]), else: query

    repo().all(query)
  end

  @doc """
  Returns the count of connections for a user.

  ## Examples

      iex> Connections.connections_count(user)
      50
  """
  def connections_count(user) do
    user_uuid = get_user_uuid(user)

    Connection
    |> where([c], c.status == "accepted")
    |> where([c], c.requester_uuid == ^user_uuid or c.recipient_uuid == ^user_uuid)
    |> repo().aggregate(:count)
  end

  @doc """
  Returns the count of pending incoming connection requests for a user.

  ## Examples

      iex> Connections.pending_requests_count(user)
      5
  """
  def pending_requests_count(user) do
    user_uuid = get_user_uuid(user)

    Connection
    |> where([c], c.recipient_uuid == ^user_uuid and c.status == "pending")
    |> repo().aggregate(:count)
  end

  # ===== BLOCKS =====

  @doc """
  Blocks a user.

  Blocking removes any existing follows and connections between the users.

  ## Parameters

  - `blocker` - The user who is blocking
  - `blocked` - The user being blocked
  - `reason` - Optional reason for the block

  ## Returns

  - `{:ok, %Block{}}` - Block created successfully
  - `{:error, :self_block}` - Cannot block yourself
  - `{:error, :already_blocked}` - User is already blocked
  """
  def block(blocker, blocked, reason \\ nil) do
    blocker_uuid = get_user_uuid(blocker)
    blocked_uuid = get_user_uuid(blocked)

    cond do
      blocker_uuid == blocked_uuid ->
        {:error, :self_block}

      blocked?(blocker_uuid, blocked_uuid) ->
        {:error, :already_blocked}

      true ->
        blocker_id = resolve_user_id(blocker)
        blocked_id = resolve_user_id(blocked)

        repo().transaction(fn ->
          # Remove any existing follows (both directions) - log history for each
          remove_follows_between_with_history(blocker_uuid, blocked_uuid)

          # Remove any existing connections - log history
          remove_connections_between_with_history(blocker_uuid, blocked_uuid, blocker_id)

          # Create the block
          attrs = %{
            blocker_uuid: blocker_uuid,
            blocked_uuid: blocked_uuid,
            blocker_id: blocker_id,
            blocked_id: blocked_id,
            reason: reason
          }

          case %Block{} |> Block.changeset(attrs) |> repo().insert() do
            {:ok, block} ->
              log_block_history(
                blocker_uuid,
                blocked_uuid,
                blocker_id,
                blocked_id,
                "block",
                reason
              )

              block

            {:error, changeset} ->
              repo().rollback(changeset)
          end
        end)
    end
  end

  @doc """
  Removes a block.

  ## Parameters

  - `blocker` - The user who blocked
  - `blocked` - The user who was blocked

  ## Returns

  - `{:ok, %Block{}}` - Block removed
  - `{:error, :not_blocked}` - No block exists
  """
  def unblock(blocker, blocked) do
    blocker_uuid = get_user_uuid(blocker)
    blocked_uuid = get_user_uuid(blocked)

    case get_block(blocker_uuid, blocked_uuid) do
      nil ->
        {:error, :not_blocked}

      block ->
        repo().transaction(fn ->
          case repo().delete(block) do
            {:ok, deleted} ->
              log_block_history(
                block.blocker_uuid,
                block.blocked_uuid,
                block.blocker_id,
                block.blocked_id,
                "unblock",
                nil
              )

              deleted

            {:error, changeset} ->
              repo().rollback(changeset)
          end
        end)
    end
  end

  @doc """
  Checks if user A has blocked user B.

  ## Examples

      iex> Connections.blocked?(user_a, user_b)
      true
  """
  def blocked?(blocker, blocked) do
    blocker_uuid = get_user_uuid(blocker)
    blocked_uuid = get_user_uuid(blocked)

    Block
    |> where([b], b.blocker_uuid == ^blocker_uuid and b.blocked_uuid == ^blocked_uuid)
    |> repo().exists?()
  end

  @doc """
  Checks if user is blocked by other user.

  ## Examples

      iex> Connections.blocked_by?(user, other)
      true
  """
  def blocked_by?(user, other) do
    blocked?(other, user)
  end

  @doc """
  Returns all users blocked by a user.

  ## Options

  - `:preload` - Preload the blocked user (default: true)
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip
  """
  def list_blocked(user, opts \\ []) do
    user_uuid = get_user_uuid(user)
    preload = Keyword.get(opts, :preload, true)

    query =
      Block
      |> where([b], b.blocker_uuid == ^user_uuid)
      |> order_by([b], desc: b.inserted_at)
      |> maybe_limit(opts[:limit])
      |> maybe_offset(opts[:offset])

    query = if preload, do: preload(query, [:blocked]), else: query

    repo().all(query)
  end

  @doc """
  Checks if two users can interact (neither has blocked the other).

  ## Examples

      iex> Connections.can_interact?(user_a, user_b)
      true
  """
  def can_interact?(user_a, user_b) do
    user_a_uuid = get_user_uuid(user_a)
    user_b_uuid = get_user_uuid(user_b)

    not (blocked?(user_a_uuid, user_b_uuid) or blocked?(user_b_uuid, user_a_uuid))
  end

  # ===== RELATIONSHIP STATUS =====

  @doc """
  Gets the full relationship status between two users in one call.

  ## Parameters

  - `user_a` - First user
  - `user_b` - Second user

  ## Returns

  A map containing:
  - `:following` - Whether A follows B
  - `:followed_by` - Whether B follows A
  - `:connected` - Whether they have a mutual connection
  - `:connection_pending` - `:sent`, `:received`, or `nil`
  - `:blocked` - Whether A blocked B
  - `:blocked_by` - Whether B blocked A

  ## Examples

      iex> Connections.get_relationship(user_a, user_b)
      %{
        following: true,
        followed_by: false,
        connected: false,
        connection_pending: :sent,
        blocked: false,
        blocked_by: false
      }
  """
  def get_relationship(user_a, user_b) do
    user_a_uuid = get_user_uuid(user_a)
    user_b_uuid = get_user_uuid(user_b)

    %{
      following: following?(user_a_uuid, user_b_uuid),
      followed_by: following?(user_b_uuid, user_a_uuid),
      connected: connected?(user_a_uuid, user_b_uuid),
      connection_pending: get_connection_pending_status(user_a_uuid, user_b_uuid),
      blocked: blocked?(user_a_uuid, user_b_uuid),
      blocked_by: blocked?(user_b_uuid, user_a_uuid)
    }
  end

  # ===== PRIVATE HELPERS =====

  defp repo do
    PhoenixKit.Config.get_repo()
  end

  # Primary resolver: accepts struct, integer, or UUID string → returns UUID
  defp get_user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp get_user_uuid(%{id: id}) when is_integer(id), do: resolve_user_uuid(id)
  defp get_user_uuid(id) when is_integer(id), do: resolve_user_uuid(id)

  defp get_user_uuid(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> resolve_user_uuid(int_id)
      _ -> id
    end
  end

  # Dual-write helper: accepts struct, integer, or UUID string → returns integer ID
  # Only used when creating records that need integer columns populated.
  # Can be deleted when integer columns are dropped.
  defp resolve_user_id(%{id: id}) when is_integer(id), do: id
  defp resolve_user_id(id) when is_integer(id), do: id

  defp resolve_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} ->
        int_id

      _ ->
        # UUID string - resolve to integer user ID
        case Auth.get_user(id) do
          %{id: int_id} -> int_id
          nil -> nil
        end
    end
  end

  defp resolve_user_uuid(user_id) when is_integer(user_id) do
    import Ecto.Query, only: [from: 2]

    repo().one(from(u in PhoenixKit.Users.Auth.User, where: u.id == ^user_id, select: u.uuid))
  end

  defp get_follow(follower_uuid, followed_uuid) do
    Follow
    |> where([f], f.follower_uuid == ^follower_uuid and f.followed_uuid == ^followed_uuid)
    |> repo().one()
  end

  defp get_block(blocker_uuid, blocked_uuid) do
    Block
    |> where([b], b.blocker_uuid == ^blocker_uuid and b.blocked_uuid == ^blocked_uuid)
    |> repo().one()
  end

  defp get_pending_request_between(requester_uuid, recipient_uuid) do
    Connection
    |> where([c], c.requester_uuid == ^requester_uuid and c.recipient_uuid == ^recipient_uuid)
    |> where([c], c.status == "pending")
    |> repo().one()
  end

  defp get_accepted_connection(user_a_uuid, user_b_uuid) do
    Connection
    |> where([c], c.status == "accepted")
    |> where(
      [c],
      (c.requester_uuid == ^user_a_uuid and c.recipient_uuid == ^user_b_uuid) or
        (c.requester_uuid == ^user_b_uuid and c.recipient_uuid == ^user_a_uuid)
    )
    |> repo().one()
  end

  defp get_connection_pending_status(user_a_uuid, user_b_uuid) do
    # Check if user_a sent a pending request to user_b
    sent =
      Connection
      |> where([c], c.requester_uuid == ^user_a_uuid and c.recipient_uuid == ^user_b_uuid)
      |> where([c], c.status == "pending")
      |> repo().exists?()

    if sent do
      :sent
    else
      # Check if user_a received a pending request from user_b
      received =
        Connection
        |> where([c], c.requester_uuid == ^user_b_uuid and c.recipient_uuid == ^user_a_uuid)
        |> where([c], c.status == "pending")
        |> repo().exists?()

      if received, do: :received, else: nil
    end
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  # Total counts for statistics
  defp get_total_follows_count do
    Follow
    |> repo().aggregate(:count)
  end

  defp get_total_connections_count do
    Connection
    |> where([c], c.status == "accepted")
    |> repo().aggregate(:count)
  end

  defp get_total_pending_count do
    Connection
    |> where([c], c.status == "pending")
    |> repo().aggregate(:count)
  end

  defp get_total_blocks_count do
    Block
    |> repo().aggregate(:count)
  end

  # ===== HISTORY LOGGING =====

  defp log_follow_history(follower_uuid, followed_uuid, follower_id, followed_id, action) do
    %FollowHistory{}
    |> FollowHistory.changeset(%{
      follower_uuid: follower_uuid,
      followed_uuid: followed_uuid,
      follower_id: follower_id,
      followed_id: followed_id,
      action: action
    })
    |> repo().insert!()
  end

  defp log_connection_history(
         user_a_uuid,
         user_b_uuid,
         actor_uuid,
         user_a_id,
         user_b_id,
         actor_id,
         action
       ) do
    %ConnectionHistory{}
    |> ConnectionHistory.changeset(%{
      user_a_uuid: user_a_uuid,
      user_b_uuid: user_b_uuid,
      actor_uuid: actor_uuid,
      user_a_id: user_a_id,
      user_b_id: user_b_id,
      actor_id: actor_id,
      action: action
    })
    |> repo().insert!()
  end

  # Create a new pending connection request with history logging
  defp create_pending_connection(requester_uuid, recipient_uuid, requester_id, recipient_id) do
    repo().transaction(fn ->
      case %Connection{}
           |> Connection.changeset(%{
             requester_uuid: requester_uuid,
             recipient_uuid: recipient_uuid,
             requester_id: requester_id,
             recipient_id: recipient_id
           })
           |> repo().insert() do
        {:ok, connection} ->
          log_connection_history(
            requester_uuid,
            recipient_uuid,
            requester_uuid,
            requester_id,
            recipient_id,
            requester_id,
            "requested"
          )

          connection

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  defp log_block_history(blocker_uuid, blocked_uuid, blocker_id, blocked_id, action, reason) do
    %BlockHistory{}
    |> BlockHistory.changeset(%{
      blocker_uuid: blocker_uuid,
      blocked_uuid: blocked_uuid,
      blocker_id: blocker_id,
      blocked_id: blocked_id,
      action: action,
      reason: reason
    })
    |> repo().insert!()
  end

  # Remove follows between users with history logging
  defp remove_follows_between_with_history(user_a_uuid, user_b_uuid) do
    # Get follows in both directions
    follows =
      Follow
      |> where(
        [f],
        (f.follower_uuid == ^user_a_uuid and f.followed_uuid == ^user_b_uuid) or
          (f.follower_uuid == ^user_b_uuid and f.followed_uuid == ^user_a_uuid)
      )
      |> repo().all()

    # Log history for each and delete
    Enum.each(follows, fn follow ->
      log_follow_history(
        follow.follower_uuid,
        follow.followed_uuid,
        follow.follower_id,
        follow.followed_id,
        "unfollow"
      )

      repo().delete!(follow)
    end)
  end

  # Remove connections between users with history logging
  defp remove_connections_between_with_history(actor_uuid, user_b_uuid, actor_id) do
    # Get connection between users
    connections =
      Connection
      |> where(
        [c],
        (c.requester_uuid == ^actor_uuid and c.recipient_uuid == ^user_b_uuid) or
          (c.requester_uuid == ^user_b_uuid and c.recipient_uuid == ^actor_uuid)
      )
      |> repo().all()

    # Log history for each and delete
    Enum.each(connections, fn connection ->
      log_connection_history(
        connection.requester_uuid,
        connection.recipient_uuid,
        actor_uuid,
        connection.requester_id,
        connection.recipient_id,
        actor_id,
        "removed"
      )

      repo().delete!(connection)
    end)
  end
end
