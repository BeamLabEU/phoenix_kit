defmodule PhoenixKit.Users.Auth.UserToken do
  @moduledoc """
  User token schema for PhoenixKit authentication system.

  This schema handles various types of tokens used for user authentication and verification:

  ## Token Types

  - **Session tokens**: For maintaining user sessions (60 days validity)
  - **Email confirmation tokens**: For account verification (7 days validity)
  - **Password reset tokens**: For secure password recovery (1 hour validity)
  - **Email change tokens**: For confirming new email addresses (7 days validity)
  - **Magic link tokens**: For passwordless authentication (15 minutes validity per industry security standards)

  ## Security Features

  - Tokens are hashed using SHA256 before storage
  - Different expiry policies for different token types
  - Secure random token generation (48 bytes for enhanced security)
  - Context-based token management for isolation
  - Short-lived magic links (15 minutes) minimize security exposure
  """
  use Ecto.Schema
  import Ecto.Query
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Utils.SessionFingerprint

  @hash_algorithm :sha256
  # 48 bytes = ~64 chars after base64 - enhanced security for passwordless auth
  @rand_size 48

  # It is very important to keep the reset password token expiry short,
  # since someone with access to the email may take over the account.
  @reset_password_validity_in_hours 1
  @confirm_validity_in_days 7
  @change_email_validity_in_days 7
  @session_validity_in_days 60
  # Magic links expire in 15 minutes for security (actual verification in MagicLink module)
  @magic_link_validity_in_minutes 15

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_users_tokens" do
    field :id, :integer, read_after_writes: true
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :ip_address, :string
    field :user_agent_hash, :string

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Generates a token that will be stored in a signed place,
  such as session or cookie. As they are signed, those
  tokens do not need to be hashed.

  The reason why we store session tokens in the database, even
  though Phoenix already provides a session cookie, is because
  Phoenix' default session cookies are not persisted, they are
  simply signed and potentially encrypted. This means they are
  valid indefinitely, unless you change the signing/encryption
  salt.

  Therefore, storing them allows individual user
  sessions to be expired. The token system can also be extended
  to store additional data, such as the device used for logging in.
  You could then use this information to display all valid sessions
  and devices in the UI and allow users to explicitly expire any
  session they deem invalid.

  ## Session Fingerprinting

  The token can optionally include session fingerprinting data to prevent
  session hijacking. Pass a `fingerprint` option with `ip_address` and
  `user_agent_hash` to enable this feature.

  ## Options

    * `:fingerprint` - A `%SessionFingerprint{}` struct with `:ip_address` and `:user_agent_hash` fields

  ## Examples

      # Without fingerprinting (backward compatible)
      {token, user_token} = build_session_token(user)

      # With fingerprinting
      fingerprint = SessionFingerprint.create_fingerprint(conn)
      {token, user_token} = build_session_token(user, fingerprint: fingerprint)

  """
  def build_session_token(user, opts \\ []) do
    token = :crypto.strong_rand_bytes(@rand_size)
    fingerprint = Keyword.get(opts, :fingerprint)
    {ip_address, user_agent_hash} = extract_fingerprint_attrs(fingerprint)

    user_token = %UserToken{
      token: token,
      context: "session",
      user_uuid: user.uuid,
      ip_address: ip_address,
      user_agent_hash: user_agent_hash
    }

    {token, user_token}
  end

  defp extract_fingerprint_attrs(%SessionFingerprint{} = fp) do
    {fp.ip_address, fp.user_agent_hash}
  end

  defp extract_fingerprint_attrs(%{} = fp) do
    {fp[:ip_address] || fp["ip_address"], fp[:user_agent_hash] || fp["user_agent_hash"]}
  end

  defp extract_fingerprint_attrs(_), do: {nil, nil}

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any.

  The token is valid if it matches the value in the database and it has
  not expired (after @session_validity_in_days).
  """
  def verify_session_token_query(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  @doc """
  Builds a token and its hash to be delivered to the user's email.

  The non-hashed token is sent to the user email while the
  hashed part is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access. Furthermore, if the user changes
  their email in the system, the tokens sent to the previous email are no longer
  valid.

  Users can easily adapt the existing code to provide other types of delivery methods,
  for example, by phone numbers.
  """
  def build_email_token(user, context) do
    build_hashed_token(user, context, user.email)
  end

  @doc """
  Generates a token for email-based operations without requiring a user struct.

  This is useful for pre-registration flows like magic link registration where
  the user doesn't exist yet.

  ## Examples

      iex> build_email_token_for_context("user@example.com", "magic_link_registration")
      {"encoded_token", %UserToken{}}
  """
  def build_email_token_for_context(email, context)
      when is_binary(email) and is_binary(context) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: email,
       user_uuid: nil
     }}
  end

  defp build_hashed_token(user, context, sent_to) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{
       token: hashed_token,
       context: context,
       sent_to: sent_to,
       user_uuid: user.uuid
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any.

  The given token is valid if it matches its hashed counterpart in the
  database and the user email has not changed. This function also checks
  if the token is being used within a certain period, depending on the
  context. The default contexts supported by this function are either
  "confirm", for account confirmation emails, and "reset_password",
  for resetting the password. For verifying requests to change the email,
  see `verify_change_email_token_query/2`.
  """
  def verify_email_token_query(token, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        {amount, unit} = validity_for_context(context)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            join: user in assoc(token, :user),
            where: token.inserted_at > ago(^amount, ^unit) and token.sent_to == user.email,
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  defp validity_for_context("confirm"), do: {@confirm_validity_in_days, "day"}
  defp validity_for_context("reset_password"), do: {@reset_password_validity_in_hours, "hour"}
  # Magic link expires in 15 minutes per industry security standards
  defp validity_for_context("magic_link"), do: {@magic_link_validity_in_minutes, "minute"}

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the user found by the token, if any.

  This is used to validate requests to change the user
  email. It is different from `verify_email_token_query/2` precisely because
  `verify_email_token_query/2` validates the email has not changed, which is
  the starting point by this function.

  The given token is valid if it matches its hashed counterpart in the
  database and if it has not expired (after @change_email_validity_in_days).
  The context must always start with "change:".
  """
  def verify_change_email_token_query(token, "change:" <> _ = context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            where: token.inserted_at > ago(@change_email_validity_in_days, "day")

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Returns the token struct for the given token value and context.
  """
  def by_token_and_context_query(token, context) do
    from UserToken, where: [token: ^token, context: ^context]
  end

  @doc """
  Gets all tokens for the given user for the given contexts.
  """
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_uuid == ^user.uuid
  end

  def by_user_and_contexts_query(user, [_ | _] = contexts) do
    from t in UserToken, where: t.user_uuid == ^user.uuid and t.context in ^contexts
  end
end
