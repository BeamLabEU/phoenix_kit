defmodule PhoenixKit.Users.MagicLinkRegistration do
  @moduledoc """
  Two-step user registration via Magic Link email.

  Flow:
  1. User enters email
  2. Receives magic link via email
  3. Clicks link to complete registration with profile details
  """

  import Ecto.Query, warn: false
  alias PhoenixKit.RepoHelper, as: Repo

  alias PhoenixKit.Config
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{User, UserToken}
  alias PhoenixKit.Utils.Routes

  @magic_link_registration_context "magic_link_registration"

  @doc """
  Sends a registration magic link to the specified email address.
  """
  def send_registration_link(email) when is_binary(email) do
    email = String.trim(email) |> String.downcase()

    if valid_email?(email) do
      case Auth.get_user_by_email(email) do
        %User{} ->
          {:error, :email_already_exists}

        nil ->
          generate_and_send_token(email)
      end
    else
      {:error, :invalid_email}
    end
  end

  @doc """
  Verifies a magic link registration token.
  """
  def verify_registration_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(:sha256, decoded_token)
        expiry_minutes = get_expiry_minutes()

        query =
          from t in UserToken,
            where:
              t.token == ^hashed_token and
                t.context == ^@magic_link_registration_context and
                t.inserted_at > ago(^expiry_minutes, "minute"),
            select: t

        case Repo.one(query) do
          %UserToken{sent_to: email} = _token ->
            {:ok, email}

          nil ->
            {:error, :invalid_token}
        end

      :error ->
        {:error, :invalid_token}
    end
  end

  @doc """
  Completes user registration using a magic link token.
  """
  def complete_registration(token, attrs, ip_address \\ nil)
      when is_binary(token) and is_map(attrs) do
    case verify_registration_token(token) do
      {:ok, email} ->
        case Auth.get_user_by_email(email) do
          %User{} ->
            delete_registration_token(token)
            {:error, :email_already_exists}

          nil ->
            do_complete_registration(email, attrs, ip_address, token)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a registration token.
  """
  def delete_registration_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(:sha256, decoded_token)

        query =
          from t in UserToken,
            where: t.token == ^hashed_token and t.context == ^@magic_link_registration_context

        Repo.delete_all(query)
        :ok

      :error ->
        :ok
    end
  end

  @doc """
  Generates a registration magic link URL.
  """
  def registration_link_url(token) when is_binary(token) do
    Routes.url("/users/register/verify/#{token}")
  end

  @doc """
  Cleans up expired registration tokens.
  """
  def cleanup_expired_tokens do
    expiry_minutes = get_expiry_minutes()

    query =
      from t in UserToken,
        where:
          t.context == ^@magic_link_registration_context and
            t.inserted_at <= ago(^expiry_minutes, "minute")

    {deleted_count, _} = Repo.delete_all(query)
    deleted_count
  end

  # Private functions

  defp generate_and_send_token(email) do
    {token, user_token} =
      UserToken.build_email_token_for_context(email, @magic_link_registration_context)

    case Repo.insert(user_token) do
      {:ok, _} ->
        registration_url = registration_link_url(token)

        case send_registration_email(email, registration_url) do
          {:ok, _} ->
            {:ok, email, token}

          {:error, reason} ->
            delete_registration_token(token)
            {:error, reason}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp do_complete_registration(email, attrs, ip_address, token) do
    {referral_code, attrs} = Map.pop(attrs, "referral_code")

    attrs =
      attrs
      |> Map.put("email", email)
      |> Map.put("confirmed_at", NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    track_geolocation = Settings.get_boolean_setting("track_registration_geolocation", false)

    result =
      if track_geolocation && ip_address do
        Auth.register_user_with_geolocation(attrs, ip_address)
      else
        Auth.register_user(attrs, ip_address)
      end

    case result do
      {:ok, user} ->
        if referral_code do
          process_referral_code(user, referral_code)
        end

        delete_registration_token(token)
        {:ok, user}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp send_registration_email(email, registration_url) do
    temp_user = %{email: email}
    Auth.UserNotifier.deliver_magic_link_registration(temp_user, registration_url)
  end

  defp process_referral_code(user, referral_code) when is_binary(referral_code) do
    if Code.ensure_loaded?(PhoenixKit.Modules.ReferralCodes) do
      case PhoenixKit.Modules.ReferralCodes.get_code_by_string(referral_code) do
        nil -> :ok
        code -> PhoenixKit.Modules.ReferralCodes.use_code(code.code, user.id)
      end
    end

    :ok
  end

  defp valid_email?(email) when is_binary(email) do
    String.match?(email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
  end

  def get_expiry_minutes do
    Config.get(:magic_link_for_registration_expiry_minutes, 30)
  end
end
