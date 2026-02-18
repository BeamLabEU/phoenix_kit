defmodule PhoenixKit.Users.Sessions do
  @moduledoc """
  Context for managing user sessions in PhoenixKit.

  This module provides functions for listing, viewing, and managing active user sessions.
  It's primarily used by the admin interface to monitor and control user sessions.

  ## Functions

  - `list_active_sessions/0` - Get all currently active sessions
  - `list_user_sessions/1` - Get all active sessions for a specific user
  - `get_session_info/1` - Get detailed information about a specific session
  - `revoke_session/1` - Revoke a specific session token
  - `revoke_user_sessions/1` - Revoke all sessions for a specific user
  - `count_active_sessions/0` - Get total count of active sessions

  ## Session Information

  Each session includes:
  - User information (id, email, status)
  - Session creation time
  - Session token (first 8 chars for identification)
  - Session age and validity status
  """

  import Ecto.Query, warn: false
  alias PhoenixKit.Admin.Events
  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Users.Auth.{User, UserToken}

  @session_validity_in_days 60

  @doc """
  Lists all currently active sessions with user information.

  Returns a list of maps containing session and user details.

  ## Examples

      iex> list_active_sessions()
      [
        %{
          token_id: "019b5704-3680-7b95-...",
          token_preview: "abc12345",
          user: %User{uuid: "019b5704-...", email: "user@example.com"},
          created_at: ~N[2024-01-01 12:00:00],
          expires_at: ~N[2024-03-02 12:00:00],
          is_current: false
        }
      ]

  """
  def list_active_sessions do
    from(token in UserToken,
      where: token.context == "session",
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      join: user in User,
      on: token.user_uuid == user.uuid,
      select: %{
        token_id: token.uuid,
        token_preview: fragment("encode(substring(?, 1, 4), 'hex')", token.token),
        user_uuid: user.uuid,
        user_email: user.email,
        user_is_active: user.is_active,
        user_confirmed_at: user.confirmed_at,
        created_at: token.inserted_at,
        expires_at: fragment("? + interval '60 days'", token.inserted_at)
      },
      order_by: [desc: token.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(&format_session_info/1)
  end

  @doc """
  Lists all active sessions for a specific user.

  ## Examples

      iex> list_user_sessions(%User{uuid: "019b5704-..."})
      [%{token_id: "019b5704-...", user: %User{}, created_at: ~N[...], ...}]

  """
  def list_user_sessions(%User{uuid: user_uuid}) do
    from(token in UserToken,
      where: token.context == "session",
      where: token.user_uuid == ^user_uuid,
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      join: user in User,
      on: token.user_uuid == user.uuid,
      select: %{
        token_id: token.uuid,
        token_preview: fragment("encode(substring(?, 1, 4), 'hex')", token.token),
        user_uuid: user.uuid,
        user_email: user.email,
        user_is_active: user.is_active,
        user_confirmed_at: user.confirmed_at,
        created_at: token.inserted_at,
        expires_at: fragment("? + interval '60 days'", token.inserted_at)
      },
      order_by: [desc: token.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(&format_session_info/1)
  end

  @doc """
  Gets detailed information about a specific session by token ID.

  ## Examples

      iex> get_session_info("019b5704-3680-7b95-...")
      %{token_id: "019b5704-...", user: %User{}, created_at: ~N[...], ...}

      iex> get_session_info("019b5704-0000-0000-...")
      nil

  """
  def get_session_info(token_uuid) when is_binary(token_uuid) do
    from(token in UserToken,
      where: token.uuid == ^token_uuid,
      where: token.context == "session",
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      join: user in User,
      on: token.user_uuid == user.uuid,
      select: %{
        token_id: token.uuid,
        token_preview: fragment("encode(substring(?, 1, 4), 'hex')", token.token),
        user_uuid: user.uuid,
        user_email: user.email,
        user_is_active: user.is_active,
        user_confirmed_at: user.confirmed_at,
        created_at: token.inserted_at,
        expires_at: fragment("? + interval '60 days'", token.inserted_at)
      }
    )
    |> Repo.one()
    |> case do
      nil -> nil
      session_data -> format_session_info(session_data)
    end
  end

  @doc """
  Revokes a specific session by token ID.

  Returns :ok if successful, {:error, :not_found} if session doesn't exist.

  ## Examples

      iex> revoke_session("019b5704-3680-7b95-...")
      :ok

      iex> revoke_session("019b5704-0000-0000-...")
      {:error, :not_found}

  """
  def revoke_session(token_uuid) when is_binary(token_uuid) do
    case Repo.delete_all(
           from(token in UserToken,
             where: token.uuid == ^token_uuid and token.context == "session"
           )
         ) do
      {1, _} ->
        # Broadcast session revocation event
        Events.broadcast_session_revoked(token_uuid)
        :ok

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Revokes all sessions for a specific user.

  Returns the number of sessions revoked.

  ## Examples

      iex> revoke_user_sessions(%User{uuid: "019b5704-..."})
      3

  """
  def revoke_user_sessions(%User{uuid: user_uuid}) do
    {count, _} =
      Repo.delete_all(
        from(token in UserToken,
          where: token.user_uuid == ^user_uuid and token.context == "session"
        )
      )

    # Broadcast user sessions revocation event
    if count > 0 do
      Events.broadcast_user_sessions_revoked(user_uuid, count)
    end

    count
  end

  @doc """
  Counts the total number of active sessions.

  ## Examples

      iex> count_active_sessions()
      15

  """
  def count_active_sessions do
    from(token in UserToken,
      where: token.context == "session",
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      select: count(token.uuid)
    )
    |> Repo.one()
  end

  @doc """
  Gets session statistics including total, unique users, expired sessions etc.

  ## Examples

      iex> get_session_stats()
      %{
        total_active: 15,
        unique_users: 8,
        expired_sessions: 5,
        sessions_today: 3
      }

  """
  def get_session_stats do
    now = DateTime.utc_now()
    today_start = %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}

    # Active sessions
    active_query =
      from(token in UserToken,
        where: token.context == "session",
        where: token.inserted_at > ago(@session_validity_in_days, "day")
      )

    total_active = Repo.aggregate(active_query, :count, :uuid)
    unique_users = Repo.aggregate(active_query, :count, :user_uuid, distinct: true)

    # Sessions created today
    sessions_today =
      from(token in UserToken,
        where: token.context == "session",
        where: token.inserted_at >= ^today_start,
        select: count(token.uuid)
      )
      |> Repo.one()

    # Expired sessions (for cleanup reference)
    expired_sessions =
      from(token in UserToken,
        where: token.context == "session",
        where: token.inserted_at <= ago(@session_validity_in_days, "day"),
        select: count(token.uuid)
      )
      |> Repo.one()

    %{
      total_active: total_active,
      unique_users: unique_users,
      expired_sessions: expired_sessions,
      sessions_today: sessions_today
    }
  end

  # Private helper to format session information
  defp format_session_info(session_data) do
    %{
      token_id: session_data.token_id,
      token_preview: session_data.token_preview,
      user_uuid: session_data.user_uuid,
      user_email: session_data.user_email,
      user_is_active: session_data.user_is_active,
      user_confirmed_at: session_data.user_confirmed_at,
      created_at: session_data.created_at,
      expires_at: session_data.expires_at,
      age_in_days: calculate_age_in_days(session_data.created_at),
      is_expired: session_expired?(session_data.created_at)
    }
  end

  defp calculate_age_in_days(created_at) do
    DateTime.diff(DateTime.utc_now(), created_at, :day)
  end

  defp session_expired?(created_at) do
    DateTime.diff(DateTime.utc_now(), created_at, :day) >= @session_validity_in_days
  end
end
