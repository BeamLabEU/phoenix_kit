defmodule PhoenixKit.Users.MagicLink do
  @moduledoc """
  Magic Link authentication system for PhoenixKit.

  Magic Link provides passwordless authentication where users receive a secure
  link via email that allows them to log in without entering a password.

  ## Features

  - **Passwordless Authentication**: Users log in with just their email
  - **Secure Token System**: Uses existing UserToken infrastructure
  - **Time-Limited Links**: Magic links expire after a configurable period
  - **Optional Integration**: Works alongside existing password authentication
  - **Email Verification**: Links are sent to the user's email address
  - **Auto-Confirmation**: Unconfirmed users are automatically confirmed upon magic link use

  ## Usage

      # Generate and send magic link
      case PhoenixKit.Users.MagicLink.generate_magic_link(email) do
        {:ok, user, token} ->
          # Send email with magic link
          PhoenixKit.Mailer.send_magic_link_email(user, token)
          {:ok, user}

        {:error, :user_not_found} ->
          # Handle unknown email
          {:error, :invalid_email}
      end

      # Verify magic link token
      case PhoenixKit.Users.MagicLink.verify_magic_link(token) do
        {:ok, user} ->
          # Log user in
          {:ok, user}

        {:error, :invalid_token} ->
          # Handle invalid/expired token
          {:error, :expired_link}
      end

  ## Security Considerations

  - Magic link tokens are single-use (automatically deleted after use)
  - Short expiry time (default: 15 minutes) to minimize exposure
  - Tokens are hashed before storage in database
  - Email address verification ensures link goes to correct recipient
  - Integration with existing user session management

  ## Configuration

  Magic link expiry can be configured in your application:

      # config/config.exs
      config :phoenix_kit, PhoenixKit.Users.MagicLink,
        expiry_minutes: 15  # Default: 15 minutes
  """

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{User, UserToken}
  alias PhoenixKit.Utils.Routes

  import Ecto.Query

  @magic_link_context "magic_link"
  @default_expiry_minutes 15

  @doc """
  Generates a magic link for the given email address.

  Returns `{:ok, user, token}` if the user exists, or `{:error, :user_not_found}`
  if no user is found with that email.

  ## Examples

      iex> PhoenixKit.Users.MagicLink.generate_magic_link("user@example.com")
      {:ok, %User{}, "magic_link_token_here"}

      iex> PhoenixKit.Users.MagicLink.generate_magic_link("nonexistent@example.com")
      {:error, :user_not_found}
  """
  def generate_magic_link(email) when is_binary(email) do
    email = String.trim(email) |> String.downcase()

    case Auth.get_user_by_email(email) do
      %User{} = user ->
        # Revoke any existing magic link tokens for this user
        revoke_magic_links(user)

        # Generate new magic link token
        {token, user_token} = UserToken.build_email_token(user, @magic_link_context)

        case repo().insert(user_token) do
          {:ok, _} ->
            {:ok, user, token}

          {:error, changeset} ->
            {:error, changeset}
        end

      nil ->
        # Perform a fake token generation to prevent timing attacks
        # This takes similar time as real token generation
        _fake_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        {:error, :user_not_found}
    end
  end

  @doc """
  Verifies a magic link token and returns the associated user.

  The token is automatically deleted after successful verification (single-use).

  If the user's email is not yet confirmed, this function will automatically
  confirm the user, since clicking the magic link proves email ownership.

  Returns `{:ok, user}` if the token is valid, or `{:error, :invalid_token}`
  if the token is invalid, expired, or already used.

  ## Examples

      iex> PhoenixKit.Users.MagicLink.verify_magic_link("valid_token")
      {:ok, %User{}}

      iex> PhoenixKit.Users.MagicLink.verify_magic_link("invalid_token")
      {:error, :invalid_token}
  """
  def verify_magic_link(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(:sha256, decoded_token)
        expiry_minutes = get_expiry_minutes()

        # Create query specifically for magic links with minute-based expiry
        query =
          from token in UserToken,
            join: user in assoc(token, :user),
            where:
              token.token == ^hashed_token and
                token.context == ^@magic_link_context and
                token.inserted_at > ago(^expiry_minutes, "minute") and
                token.sent_to == user.email,
            select: {user, token}

        case repo().one(query) do
          {user, user_token} ->
            # Delete the token to make it single-use
            repo().delete(user_token)

            # Auto-confirm user on magic link authentication
            confirm_user_if_needed(user)

          nil ->
            {:error, :invalid_token}
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Revokes all active magic link tokens for a user.

  This is useful when:
  - Generating a new magic link (only one should be active)
  - User logs in via other means (invalidate pending magic links)
  - Security concerns require invalidating all passwordless access

  ## Examples

      iex> PhoenixKit.Users.MagicLink.revoke_magic_links(user)
      :ok
  """
  def revoke_magic_links(%User{} = user) do
    query =
      from t in UserToken,
        where: t.user_id == ^user.id and t.context == ^@magic_link_context

    repo().delete_all(query)
    :ok
  end

  @doc """
  Checks if magic link authentication is enabled for the application.

  This can be used in controllers and views to conditionally show magic link UI.

  ## Examples

      iex> PhoenixKit.Users.MagicLink.enabled?()
      true
  """
  def enabled? do
    # Magic link is always available as it uses existing token infrastructure
    true
  end

  @doc """
  Gets the number of active magic link tokens for a user.

  Useful for debugging or administrative interfaces.

  ## Examples

      iex> PhoenixKit.Users.MagicLink.active_magic_links_count(user)
      1
  """
  def active_magic_links_count(%User{} = user) do
    expiry_minutes = get_expiry_minutes()

    query =
      from t in UserToken,
        where:
          t.user_id == ^user.id and
            t.context == ^@magic_link_context and
            t.inserted_at > ago(^expiry_minutes, "minute")

    repo().aggregate(query, :count)
  end

  @doc """
  Generates a magic link URL for the given token.

  This is a convenience function to construct the full URL that should be
  included in magic link emails.

  ## Examples

      iex> PhoenixKit.Users.MagicLink.magic_link_url("token123")
      "http://localhost:4000{prefix}/users/magic-link/token123"

      # Where {prefix} is the configured PhoenixKit URL prefix
  """
  def magic_link_url(token) when is_binary(token) do
    Routes.url("/users/magic-link/#{token}")
  end

  @doc """
  Cleans up expired magic link tokens.

  This function can be called periodically (e.g., via a scheduled job) to
  remove expired tokens from the database.

  Returns the number of tokens deleted.

  ## Examples

      iex> PhoenixKit.Users.MagicLink.cleanup_expired_tokens()
      5  # 5 expired tokens were deleted
  """
  def cleanup_expired_tokens do
    expiry_minutes = get_expiry_minutes()

    query =
      from t in UserToken,
        where:
          t.context == ^@magic_link_context and
            t.inserted_at <= ago(^expiry_minutes, "minute")

    {deleted_count, _} = repo().delete_all(query)
    deleted_count
  end

  # Get configured expiry time in minutes
  defp get_expiry_minutes do
    Application.get_env(:phoenix_kit, __MODULE__, [])
    |> Keyword.get(:expiry_minutes, @default_expiry_minutes)
  end

  # Auto-confirm user if not yet confirmed
  # If user can click the magic link, they have proven email ownership
  defp confirm_user_if_needed(%User{confirmed_at: nil} = user) do
    case Auth.admin_confirm_user(user) do
      {:ok, confirmed_user} -> {:ok, confirmed_user}
      {:error, _changeset} -> {:ok, user}
    end
  end

  defp confirm_user_if_needed(%User{} = user), do: {:ok, user}

  # Get configured repo module
  defp repo do
    Application.get_env(:phoenix_kit, :repo) ||
      raise """
      No repo configured for PhoenixKit. Please add to your config:

      config :phoenix_kit, repo: YourApp.Repo
      """
  end
end
