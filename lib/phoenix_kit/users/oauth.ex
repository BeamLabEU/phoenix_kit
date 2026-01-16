if Code.ensure_loaded?(Ueberauth) do
  defmodule PhoenixKit.Users.OAuth do
    @moduledoc """
    OAuth authentication context for PhoenixKit.

    Handles OAuth authentication flows for external providers like Google, Apple, GitHub.

    This module requires the Ueberauth library to be installed. If Ueberauth is not available,
    a fallback module with basic functionality will be used instead.
    """

    import Ecto.Query, warn: false
    alias PhoenixKit.RepoHelper, as: Repo

    alias PhoenixKit.Modules.Referrals
    alias PhoenixKit.Users.Auth
    alias PhoenixKit.Users.Auth.User
    alias PhoenixKit.Users.OAuthProvider

    @doc """
    Handles OAuth callback from Ueberauth.
    """
    def handle_oauth_callback(%Ueberauth.Auth{} = auth, opts \\ []) do
      oauth_data = extract_oauth_data(auth)
      track_geolocation = Keyword.get(opts, :track_geolocation, false)
      ip_address = Keyword.get(opts, :ip_address)
      referral_code = Keyword.get(opts, :referral_code)

      Repo.transaction(fn ->
        with {:ok, user, _status} <-
               find_or_create_user(oauth_data, track_geolocation, ip_address),
             {:ok, _provider} <- link_oauth_provider(user, oauth_data),
             {:ok, user} <- maybe_save_oauth_avatar(user, oauth_data),
             :ok <- maybe_process_referral_code(user, referral_code) do
          user
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    @doc """
    Finds an existing user by email or creates a new one from OAuth data.
    """
    def find_or_create_user(oauth_data, track_geolocation \\ false, ip_address \\ nil) do
      case Auth.get_user_by_email(oauth_data.email) do
        %User{} = user ->
          # Auto-confirm email for existing users logging in via OAuth
          {:ok, confirmed_user} = maybe_confirm_user(user)
          {:ok, confirmed_user, :found}

        nil ->
          case register_oauth_user(oauth_data, track_geolocation, ip_address) do
            {:ok, user} -> {:ok, user, :created}
            {:error, reason} -> {:error, reason}
          end
      end
    end

    # Auto-confirm email for unconfirmed users logging in via OAuth.
    # OAuth providers verify email ownership, so we can trust it.
    defp maybe_confirm_user(%User{confirmed_at: nil} = user) do
      case Auth.admin_confirm_user(user) do
        {:ok, confirmed_user} -> {:ok, confirmed_user}
        {:error, _changeset} -> {:ok, user}
      end
    end

    defp maybe_confirm_user(%User{} = user), do: {:ok, user}

    # Save OAuth avatar URL to user's custom_fields if available
    # This enables displaying the OAuth provider's avatar in the UI
    defp maybe_save_oauth_avatar(user, %{image: image}) when is_binary(image) and image != "" do
      # Only update if user doesn't already have a custom avatar
      case user.custom_fields do
        %{"avatar_file_id" => file_id} when is_binary(file_id) and file_id != "" ->
          # User has a custom avatar, don't override
          {:ok, user}

        _ ->
          # Save OAuth avatar URL for fallback display
          Auth.set_user_custom_field(user, "oauth_avatar_url", image)
      end
    end

    defp maybe_save_oauth_avatar(user, _oauth_data), do: {:ok, user}

    @doc """
    Links an OAuth provider to a user account.
    """
    def link_oauth_provider(%User{} = user, oauth_data) when is_map(oauth_data) do
      attrs = %{
        user_id: user.id,
        provider: oauth_data.provider,
        provider_uid: oauth_data.provider_uid,
        provider_email: oauth_data.email,
        access_token: oauth_data[:access_token],
        refresh_token: oauth_data[:refresh_token],
        token_expires_at: oauth_data[:token_expires_at],
        raw_data: build_raw_data(oauth_data)
      }

      %OAuthProvider{}
      |> OAuthProvider.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :user_id, :provider, :inserted_at]},
        conflict_target: [:user_id, :provider]
      )
    end

    @doc """
    Gets all OAuth providers for a user.
    """
    def get_user_oauth_providers(user_id) when is_integer(user_id) do
      from(p in OAuthProvider,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at]
      )
      |> Repo.all()
    end

    @doc """
    Unlinks an OAuth provider from a user.
    """
    def unlink_oauth_provider(user_id, provider)
        when is_integer(user_id) and is_binary(provider) do
      case from(p in OAuthProvider, where: p.user_id == ^user_id and p.provider == ^provider)
           |> Repo.one() do
        nil -> {:error, :not_found}
        provider_record -> Repo.delete(provider_record)
      end
    end

    # Private functions

    defp extract_oauth_data(%Ueberauth.Auth{} = auth) do
      %{
        provider: to_string(auth.provider),
        provider_uid: to_string(auth.uid),
        email: auth.info.email,
        first_name: auth.info.first_name,
        last_name: auth.info.last_name,
        image: auth.info.image,
        # FIXED: Use dot notation for struct fields (structs don't implement Access behaviour)
        access_token: auth.credentials.token,
        refresh_token: auth.credentials.refresh_token,
        token_expires_at: get_token_expires_at(auth.credentials),
        raw_info: get_raw_info(auth.extra)
      }
    end

    # Helper to safely extract raw_info from extra struct
    defp get_raw_info(%{raw_info: raw_info}), do: raw_info
    defp get_raw_info(_), do: %{}

    defp get_token_expires_at(%{expires_at: expires_at}) when is_integer(expires_at) do
      DateTime.from_unix!(expires_at)
    end

    defp get_token_expires_at(_), do: nil

    defp register_oauth_user(oauth_data, track_geolocation, ip_address) do
      attrs = %{
        email: oauth_data.email,
        password: generate_random_password(),
        first_name: oauth_data.first_name,
        last_name: oauth_data.last_name
      }

      result =
        if track_geolocation && ip_address do
          Auth.register_user_with_geolocation(attrs, ip_address)
        else
          Auth.register_user(attrs, ip_address)
        end

      # Auto-confirm email for OAuth users (providers verify email ownership)
      case result do
        {:ok, user} -> maybe_confirm_user(user)
        error -> error
      end
    end

    defp generate_random_password do
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 32)
    end

    defp build_raw_data(oauth_data) do
      %{
        image: oauth_data[:image],
        raw_info: serialize_raw_info(oauth_data[:raw_info])
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})
    end

    defp serialize_raw_info(nil), do: %{}

    defp serialize_raw_info(raw_info) when is_map(raw_info) do
      Enum.into(raw_info, %{}, fn {key, value} ->
        {key, serialize_value(value)}
      end)
    end

    defp serialize_raw_info(raw_info), do: raw_info

    # Serialize OAuth2.AccessToken if present
    defp serialize_value(%OAuth2.AccessToken{} = token) do
      %{
        access_token: token.access_token,
        refresh_token: token.refresh_token,
        expires_at: token.expires_at,
        token_type: token.token_type,
        other_params: token.other_params
      }
    end

    defp serialize_value(value), do: value

    defp maybe_process_referral_code(_user, nil), do: :ok

    defp maybe_process_referral_code(user, referral_code) when is_binary(referral_code) do
      if Code.ensure_loaded?(Referrals) do
        case Referrals.get_code_by_string(referral_code) do
          nil -> :ok
          code -> Referrals.use_code(code.code, user.id)
        end
      end

      :ok
    end
  end
else
  # Fallback module when Ueberauth is not loaded
  defmodule PhoenixKit.Users.OAuth do
    @moduledoc """
    Fallback OAuth context module when Ueberauth is not installed.

    This module provides basic OAuth provider management without authentication capabilities.
    To enable full OAuth authentication, install the required dependencies.
    """

    import Ecto.Query, warn: false
    alias PhoenixKit.RepoHelper, as: Repo
    alias PhoenixKit.Users.OAuthProvider

    @doc """
    Returns an error when OAuth callback is attempted without Ueberauth.
    """
    def handle_oauth_callback(_auth, _opts \\ []) do
      {:error, :ueberauth_not_loaded}
    end

    @doc """
    Gets all OAuth providers for a user.
    """
    def get_user_oauth_providers(user_id) when is_integer(user_id) do
      from(p in OAuthProvider,
        where: p.user_id == ^user_id,
        order_by: [desc: p.inserted_at]
      )
      |> Repo.all()
    end

    @doc """
    Unlinks an OAuth provider from a user.
    """
    def unlink_oauth_provider(user_id, provider)
        when is_integer(user_id) and is_binary(provider) do
      case from(p in OAuthProvider, where: p.user_id == ^user_id and p.provider == ^provider)
           |> Repo.one() do
        nil -> {:error, :not_found}
        provider_record -> Repo.delete(provider_record)
      end
    end
  end
end
