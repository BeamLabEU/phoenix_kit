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

    alias PhoenixKit.Users.Auth
    alias PhoenixKit.Users.Auth.User
    alias PhoenixKit.Users.OAuthProvider
    alias PhoenixKit.Users.Referrals
    alias PhoenixKit.Users.Sessions.Revocation
    alias PhoenixKit.Utils.Routes

    require Logger

    @doc """
    Handles OAuth callback from Ueberauth.
    """
    def handle_oauth_callback(%Ueberauth.Auth{} = auth, opts \\ []) do
      oauth_data = extract_oauth_data(auth)
      track_geolocation = Keyword.get(opts, :track_geolocation, false)
      ip_address = Keyword.get(opts, :ip_address)
      referral_code = Keyword.get(opts, :referral_code)

      Revocation.transaction(fn ->
        with {:ok, user, _status} <-
               find_or_create_user(oauth_data, track_geolocation, ip_address),
             {:ok, _provider} <- link_oauth_provider(user, oauth_data),
             {:ok, user} <- maybe_fill_google_email(user, oauth_data),
             {:ok, user} <- maybe_save_oauth_avatar(user, oauth_data),
             :ok <- maybe_process_referral_code(user, referral_code) do
          user
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    @doc """
    Resolves the local account for an OAuth callback, creating one if needed.

    Resolution order matters, because the three cases carry different proof:

    1. **An existing link** (`provider` + `provider_uid`) is the strongest
       signal there is — this exact external identity was attached to this
       account before, and no email address is consulted.
    2. **A pre-existing local account with the same email** is the takeover
       case. Matching on the email string alone means whoever can get that
       address attached to a provider account signs in as its owner, so the
       provider must ASSERT it verified the address. Without that assertion the
       callback is refused with `{:error, :provider_email_unverified}`.
    3. **No local account** registers a new one — unless `allow_registration`
       is off, in which case the callback is refused with
       `{:error, :registration_disabled}`. Signing in to an existing account
       (cases 1 and 2) is never affected by that switch.

    The assertion requirement can be lifted with the `oauth_require_verified_email`
    setting (default `true`) for a deployment whose provider does not surface a
    verification claim; it is a deliberate, operator-visible decision rather
    than a silent default.
    """
    def find_or_create_user(oauth_data, track_geolocation \\ false, ip_address \\ nil) do
      cond do
        linked_user = user_by_provider_identity(oauth_data) ->
          found(linked_user)

        # A provider account with no (public/primary) email — GitHub allows
        # it — must fail here, not as a FunctionClauseError inside the lookup.
        not (is_binary(oauth_data.email) and oauth_data.email != "") ->
          {:error, :provider_email_missing}

        existing_user = Auth.get_user_by_email(oauth_data.email) ->
          attach_to_existing_user(existing_user, oauth_data)

        # `allow_registration` is the wide switch: no new accounts, by any
        # door. It hid the Register link and closed the password and
        # magic-link routes while this branch went on creating accounts, so
        # a provider account nobody here had seen before still arrived, was
        # registered, and was signed in — registration closed, account
        # created. Signing IN is untouched: the two branches above reach
        # accounts that already exist.
        not registration_open?() ->
          {:error, :registration_disabled}

        true ->
          case register_oauth_user(oauth_data, track_geolocation, ip_address) do
            {:ok, user} -> {:ok, user, :created}
            {:error, reason} -> {:error, reason}
          end
      end
    end

    defp registration_open?,
      do: PhoenixKit.Settings.get_boolean_setting("allow_registration", true)

    # The account this external identity is already attached to, if any.
    #
    # `(provider, provider_uid)` carries a UNIQUE index
    # (`phoenix_kit_oauth_providers_provider_uid_idx`, migration V16), so at most
    # one row can match; `limit: 1` is belt-and-braces against a database whose
    # chain predates it, not a real ambiguity.
    #
    # ⚠️ Note on what this branch means: it treats an EXISTING link as proof of
    # identity without consulting the email or any verification claim. That is
    # right for the shipped providers, whose uid is an immutable server-assigned
    # id — and it is NOT automatically right for a provider whose `sub`/`uid` a
    # user can choose or recycle. It also means link rows written by an earlier
    # release, when attaching happened on email equality alone, keep working:
    # this gate protects new attachments, it cannot retroactively re-verify old
    # ones. Auditing them is an operator task — see the release notes.
    defp user_by_provider_identity(%{provider: provider, provider_uid: provider_uid})
         when is_binary(provider) and is_binary(provider_uid) and provider_uid != "" do
      from(p in OAuthProvider,
        join: u in User,
        on: u.uuid == p.user_uuid,
        where: p.provider == ^provider and p.provider_uid == ^provider_uid,
        order_by: [asc: p.inserted_at],
        limit: 1,
        select: u
      )
      |> Repo.one()
    end

    defp user_by_provider_identity(_oauth_data), do: nil

    # A service user (`api_only`) signs in with an API key only: no provider identity may be
    # linked to it, by a stored link or by an address that happens to match.
    defp found(%User{api_only: true}), do: {:error, :api_only_account}
    defp found(%User{managed_by_members: true}), do: {:error, :managed_organization}
    defp found(%User{} = user), do: {:ok, user, :found}

    defp attach_to_existing_user(%User{api_only: true}, _oauth_data),
      do: {:error, :api_only_account}

    defp attach_to_existing_user(%User{managed_by_members: true}, _oauth_data),
      do: {:error, :managed_organization}

    defp attach_to_existing_user(%User{} = user, oauth_data) do
      if email_ownership_proven?(oauth_data) do
        {:ok, confirmed_user} = maybe_confirm_user(user)
        {:ok, confirmed_user, :found}
      else
        {:error, :provider_email_unverified}
      end
    end

    # True when the provider states it verified the address, or when the
    # operator has explicitly turned the requirement off.
    defp email_ownership_proven?(oauth_data) do
      not require_verified_email?() or provider_asserts_verified_email?(oauth_data)
    end

    defp require_verified_email? do
      PhoenixKit.Settings.get_boolean_setting("oauth_require_verified_email", true)
    end

    # Reads the provider's own verification claim out of the raw callback
    # payload. Each provider spells it differently, and an unrecognised shape
    # answers false — an assertion we cannot find is not an assertion.
    defp provider_asserts_verified_email?(%{provider: "github"} = oauth_data) do
      address = normalize_email(oauth_data[:email])

      oauth_data
      |> raw_user()
      |> fetch_claim(:emails)
      |> List.wrap()
      |> Enum.any?(fn entry ->
        is_map(entry) and
          normalize_email(fetch_claim(entry, :email)) == address and
          truthy?(fetch_claim(entry, :verified))
      end)
    end

    # Facebook's `verified` is an ACCOUNT-level flag, not a per-address one —
    # the Graph API surfaces no per-email verification in the basic scope. It is
    # the strongest signal the provider gives, and it is weaker than Google's or
    # GitHub's; a deployment that cares about the difference should not enable
    # Facebook sign-in for accounts that already exist locally.
    defp provider_asserts_verified_email?(%{provider: "facebook"} = oauth_data) do
      oauth_data |> raw_user() |> fetch_claim(:verified) |> truthy?()
    end

    # Google and any provider following the OpenID Connect claim name.
    defp provider_asserts_verified_email?(oauth_data) do
      truthy?(oauth_data |> raw_user() |> fetch_claim(:email_verified)) or
        truthy?(oauth_data |> raw_info() |> fetch_claim(:email_verified))
    end

    # `raw_info` shape varies by strategy and is not guaranteed to be a plain
    # map, so both accessors normalise to `%{}` rather than letting a struct or
    # a nil reach a lookup.
    defp raw_info(oauth_data) do
      case Map.get(oauth_data, :raw_info) do
        %{} = info when not is_struct(info) -> info
        _other -> %{}
      end
    end

    # The shipped strategies build `raw_info` with ATOM keys —
    # `%{token: ..., user: ...}` in ueberauth_google, ueberauth_github and
    # ueberauth_facebook — while the user payload nested inside it is decoded
    # JSON with STRING keys (`user["email"]`). Reading only one of the two
    # spellings is how a verification gate ends up never firing, so every claim
    # lookup here accepts both.
    defp raw_user(oauth_data) do
      case oauth_data |> raw_info() |> fetch_claim(:user) do
        %{} = user when not is_struct(user) -> user
        _other -> %{}
      end
    end

    defp fetch_claim(map, key) when is_map(map) and is_atom(key) do
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> Map.get(map, Atom.to_string(key))
      end
    end

    defp fetch_claim(_map, _key), do: nil

    defp truthy?(true), do: true
    defp truthy?("true"), do: true
    defp truthy?(_value), do: false

    defp normalize_email(email) when is_binary(email),
      do: email |> String.trim() |> String.downcase()

    defp normalize_email(_email), do: nil

    # Auto-confirm email for unconfirmed users logging in via OAuth.
    # Only when the provider ASSERTED it verified the address — the previous
    # comment here ("OAuth providers verify email ownership, so we can trust
    # it") was an assumption about every provider and every account type, and
    # confirming on it turned an unverified provider address into a confirmed
    # local account.
    defp maybe_confirm_user(%User{confirmed_at: nil} = user) do
      case Auth.confirm_user_from_external_proof(user) do
        {:ok, confirmed_user} ->
          PhoenixKit.Activity.log(%{
            action: "user.email_confirmed",
            module: "users",
            mode: "auto",
            actor_uuid: confirmed_user.uuid,
            resource_type: "user",
            resource_uuid: confirmed_user.uuid,
            metadata: %{"method" => "oauth", "actor_role" => "user"}
          })

          {:ok, confirmed_user}

        {:error, _changeset} ->
          {:ok, user}
      end
    end

    defp maybe_confirm_user(%User{} = user), do: {:ok, user}

    # Save OAuth avatar URL to user's custom_fields if available
    # This enables displaying the OAuth provider's avatar in the UI
    defp maybe_save_oauth_avatar(user, %{image: image}) when is_binary(image) and image != "" do
      # Only update if user doesn't already have a custom avatar
      case user.custom_fields do
        %{"avatar_file_uuid" => file_uuid} when is_binary(file_uuid) and file_uuid != "" ->
          # User has a custom avatar, don't override
          {:ok, user}

        _ ->
          # Save OAuth avatar URL for fallback display
          Auth.set_user_custom_field(user, "oauth_avatar_url", image)
      end
    end

    defp maybe_save_oauth_avatar(user, _oauth_data), do: {:ok, user}

    # A Google sign-in proves the address, so `google_email` starts filled
    # rather than waiting for the user to type what we already know. Only
    # while it is empty: a value set by hand is the user's own answer to
    # "where do we share with you", and a second Google account signing in
    # must not silently redirect their shares.
    defp maybe_fill_google_email(%User{google_email: current} = user, %{
           provider: "google",
           email: email
         })
         when is_binary(email) and email != "" do
      if is_binary(current) and String.trim(current) != "" do
        {:ok, user}
      else
        case Auth.update_user_profile(user, %{google_email: email}) do
          {:ok, updated} -> {:ok, updated}
          # Never fail a sign-in over a convenience prefill — a provider
          # address longer than the column, say. The user can still type one.
          {:error, %Ecto.Changeset{}} -> {:ok, user}
        end
      end
    end

    defp maybe_fill_google_email(user, _oauth_data), do: {:ok, user}

    @doc """
    Links an OAuth provider to a user account.
    """
    def link_oauth_provider(%User{} = user, oauth_data) when is_map(oauth_data) do
      Repo.transaction(fn ->
        current =
          Repo.one(from(u in User, where: u.uuid == ^user.uuid, lock: "FOR NO KEY UPDATE"))

        case current do
          %User{managed_by_members: true} -> Repo.rollback(:managed_organization)
          %User{api_only: true} -> Repo.rollback(:api_only_account)
          %User{hashed_password: hash} when hash == user.hashed_password -> :ok
          _ -> Repo.rollback(:account_changed)
        end

        case insert_oauth_provider(user, oauth_data) do
          {:ok, provider} -> provider
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end

    defp insert_oauth_provider(user, oauth_data) do
      attrs = %{
        user_uuid: user.uuid,
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
        on_conflict: {:replace_all_except, [:uuid, :user_uuid, :provider, :inserted_at]},
        conflict_target: [:user_uuid, :provider]
      )
    end

    @doc """
    Gets all OAuth providers for a user.
    """
    def get_user_oauth_providers(user_uuid) when is_binary(user_uuid) do
      from(p in OAuthProvider,
        where: p.user_uuid == ^user_uuid,
        order_by: [desc: p.inserted_at]
      )
      |> Repo.all()
    end

    @doc """
    Unlinks an OAuth provider from a user.
    """
    def unlink_oauth_provider(user_uuid, provider)
        when is_binary(user_uuid) and is_binary(provider) do
      case from(p in OAuthProvider, where: p.user_uuid == ^user_uuid and p.provider == ^provider)
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

      # NOT rate-limited here. `Auth.register_user/2` already checks the
      # registration buckets, and `register_user_with_geolocation/2` funnels
      # into it too — so a check at this level charges every OAuth signup TWICE
      # against a 3-per-email/10-per-IP budget, quietly turning it into 1 and 5.
      # (The gate work assumed this path was unlimited. It never was.)
      case do_register_oauth_user(attrs, track_geolocation, ip_address) do
        # Auto-confirm only on a provider assertion. A new account whose address
        # the provider did not vouch for goes through the ordinary confirmation
        # mail instead — registering is still allowed, but the address is not
        # treated as proven, so a squatted one cannot be laundered into a
        # confirmed local account.
        {:ok, user} ->
          if provider_asserts_verified_email?(oauth_data) do
            maybe_confirm_user(user)
          else
            deliver_oauth_confirmation(user)
            {:ok, user}
          end

        error ->
          error
      end
    end

    # The mail the comment above promises. Nothing else on the OAuth path sends
    # it — `Auth.register_user/2` does not, and only the registration controller
    # ever did — so before this the unvouched-for account was signed in with
    # "Successfully signed in!" and then bounced off every gate that honours
    # `require_email_confirmation` (default on) with an empty inbox and no way
    # back except guessing at /users/confirm.
    #
    # A delivery failure must not sink the sign-in: the account exists either
    # way and the user can ask for the mail again from the confirmation page.
    # Deliberately no `rescue` — this runs inside `handle_oauth_callback/2`'s
    # transaction, and the same call also inserts the confirm token, so
    # swallowing a raise there would leave a poisoned transaction that fails at
    # commit anyway. Mailer failures arrive as `{:error, _}`, which is handled.
    defp deliver_oauth_confirmation(%User{confirmed_at: nil} = user) do
      case Auth.deliver_user_confirmation_instructions(
             user,
             &Routes.url("/users/confirm/#{&1}")
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "PhoenixKit: could not send OAuth confirmation mail to #{user.email}: #{inspect(reason)}"
          )

          :ok
      end
    end

    defp deliver_oauth_confirmation(_user), do: :ok

    defp do_register_oauth_user(attrs, track_geolocation, ip_address) do
      if track_geolocation && ip_address do
        Auth.register_user_with_geolocation(attrs, ip_address)
      else
        Auth.register_user(attrs, ip_address)
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
        Referrals.record_signup_use(user, referral_code)
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
    alias PhoenixKit.Users.Auth.User
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
    def get_user_oauth_providers(user_uuid) when is_binary(user_uuid) do
      from(p in OAuthProvider,
        where: p.user_uuid == ^user_uuid,
        order_by: [desc: p.inserted_at]
      )
      |> Repo.all()
    end

    @doc """
    Unlinks an OAuth provider from a user.
    """
    def unlink_oauth_provider(user_uuid, provider)
        when is_binary(user_uuid) and is_binary(provider) do
      case from(p in OAuthProvider, where: p.user_uuid == ^user_uuid and p.provider == ^provider)
           |> Repo.one() do
        nil -> {:error, :not_found}
        provider_record -> Repo.delete(provider_record)
      end
    end
  end
end
