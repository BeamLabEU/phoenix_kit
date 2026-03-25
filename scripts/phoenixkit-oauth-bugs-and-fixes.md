# PhoenixKit OAuth Implementation Issues and Fixes

**Document Version**: 1.0
**Date**: October 29, 2025
**PhoenixKit Version**: 1.4.6
**Author**: Beamlab Development Team

## Executive Summary

This document details critical bugs discovered in PhoenixKit v1.4.6's OAuth implementation that prevent Google OAuth (and potentially other OAuth providers) from functioning correctly. Two major issues were identified and **fixed directly in the PhoenixKit library**. These fixes eliminate the need for application-level workarounds.

**Status**: ✅ Fixed in PhoenixKit library (local copy) - Tested and working
**Configuration Required**: `oauth_base_url` setting (legitimate PhoenixKit config for proxy deployments)

---

## Issue #1: Ueberauth Base Path Not Preserved During Configuration

### Problem Description

PhoenixKit's OAuth routes are located at `/phoenix_kit/users/auth/:provider`, but the Ueberauth plugin defaults to looking for routes at `/auth/:provider`. When PhoenixKit's `OAuthConfig.configure_providers()` function runs at application startup, it **overwrites the entire Ueberauth configuration** without preserving the `base_path` setting.

### Root Cause

**File**: `deps/phoenix_kit/lib/phoenix_kit/users/oauth_config.ex`
**Function**: `configure_ueberauth_base/0` (lines 58-75)

```elixir
defp configure_ueberauth_base do
  providers = build_provider_list()

  config = [
    providers: providers  # <-- ONLY sets providers, loses base_path!
  ]

  # Always update Ueberauth configuration, even if providers list is empty
  # This ensures Ueberauth has a valid configuration at all times
  Application.put_env(:ueberauth, Ueberauth, config)  # <-- OVERWRITES entire config

  if providers != %{} do
    Logger.debug("OAuth: Configured Ueberauth with providers: #{inspect(Map.keys(providers))}")
  else
    Logger.debug("OAuth: Configured Ueberauth with no active providers")
  end
end
```

### Impact

When a user attempts to authenticate via OAuth:
1. User clicks "Sign in with Google"
2. Request goes to `/phoenix_kit/users/auth/google`
3. Ueberauth plug processes the request but expects base path `/auth` (not `/phoenix_kit/users/auth`)
4. Ueberauth fails to process the request (`conn.state == :unset`)
5. PhoenixKit's OAuth controller shows error: `"Ueberauth plugin did not process request for provider"`

**Error in logs**:
```
[error] PhoenixKit OAuth: Ueberauth plugin did not process request for provider.
Check if GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET environment variables are set correctly.
```

This error message is **misleading** because the credentials ARE configured correctly - the issue is the base_path mismatch.

### Observed in Source Code

**File**: `deps/phoenix_kit/lib/phoenix_kit_web/users/oauth.ex` (lines 107-123)

```elixir
# Check if Ueberauth plug has already sent a response (e.g., a redirect)
# If response was already sent by Ueberauth, halt() to stop further processing
if conn.state != :unset do
  # Response already sent by Ueberauth (e.g., redirect to OAuth provider)
  halt(conn)
else
  # No response sent - Ueberauth couldn't process the request
  # This can happen if provider configuration is missing or invalid
  Logger.error(
    "PhoenixKit OAuth: Ueberauth plugin did not process request for provider. Check if GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET environment variables are set correctly."
  )

  conn
  |> put_flash(:error, "OAuth authentication unavailable. The provider credentials are not configured. Please contact your administrator or use another sign-in method.")
  |> redirect(to: Routes.path("/users/log-in"))
end
```

The `conn.state != :unset` check fails because Ueberauth never processes the request due to base_path mismatch.

### Our Workaround

**File**: `lib/beamlab/application.ex`

Added a function that runs **after** PhoenixKit initialization to restore the base_path:

```elixir
defp fix_ueberauth_base_path do
  require Logger

  current_config = Application.get_env(:ueberauth, Ueberauth, [])

  # Only set base_path if it's not already set
  if !Keyword.has_key?(current_config, :base_path) do
    updated_config = Keyword.put(current_config, :base_path, "/phoenix_kit/users/auth")
    Application.put_env(:ueberauth, Ueberauth, updated_config)
    Logger.debug("OAuth: Set Ueberauth base_path to /phoenix_kit/users/auth")
  end
end
```

Called in the startup sequence:

```elixir
try do
  PhoenixKit.Users.OAuthConfig.configure_providers()
  fix_github_oauth_module_name()
  fix_ueberauth_base_path()  # <-- Restore base_path after PhoenixKit overwrites it
rescue
  error ->
    require Logger
    Logger.warning("Failed to configure OAuth providers on startup: #{inspect(error)}")
end
```

**File**: `config/runtime.exs`

Also added explicit OAuth base URL configuration:

```elixir
config :phoenix_kit,
  oauth_base_url: "https://#{app_config.phx_host}"
```

### Recommended Fix for PhoenixKit

**File**: `lib/phoenix_kit/users/oauth_config.ex`
**Function**: `configure_ueberauth_base/0`

```elixir
defp configure_ueberauth_base do
  providers = build_provider_list()

  # Get current config to preserve any existing settings
  current_config = Application.get_env(:ueberauth, Ueberauth, [])

  # Preserve base_path if it exists, or set default based on PhoenixKit URL prefix
  base_path = Keyword.get(current_config, :base_path) || get_oauth_base_path()

  config = [
    base_path: base_path,  # <-- PRESERVE OR SET base_path
    providers: providers
  ]

  Application.put_env(:ueberauth, Ueberauth, config)

  if providers != %{} do
    Logger.debug("OAuth: Configured Ueberauth with providers: #{inspect(Map.keys(providers))} at base_path: #{base_path}")
  else
    Logger.debug("OAuth: Configured Ueberauth with no active providers")
  end
end

# Helper to get OAuth base path from PhoenixKit URL prefix
defp get_oauth_base_path do
  url_prefix = PhoenixKit.Config.get_url_prefix()

  case url_prefix do
    "" -> "/users/auth"
    prefix -> "#{prefix}/users/auth"
  end
end
```

---

## Issue #2: Struct Field Access Using Bracket Notation

### Problem Description

PhoenixKit's `extract_oauth_data/1` function attempts to access fields in the `Ueberauth.Auth.Credentials` struct using bracket notation (`credentials[:token]`), which is **invalid in Elixir**. Structs do not implement the Access behaviour unless explicitly defined.

### Root Cause

**File**: `deps/phoenix_kit/lib/phoenix_kit/users/oauth.ex`
**Function**: `extract_oauth_data/1` (lines 104-117)

```elixir
defp extract_oauth_data(%Ueberauth.Auth{} = auth) do
  %{
    provider: to_string(auth.provider),
    provider_uid: to_string(auth.uid),
    email: auth.info.email,
    first_name: auth.info.first_name,
    last_name: auth.info.last_name,
    image: auth.info.image,
    access_token: auth.credentials[:token],           # <-- BUG: Bracket notation on struct
    refresh_token: auth.credentials[:refresh_token],  # <-- BUG: Bracket notation on struct
    token_expires_at: get_token_expires_at(auth.credentials),
    raw_info: auth.extra[:raw_info]                   # <-- BUG: Bracket notation on struct
  }
end
```

### Impact

After successful OAuth authentication with Google, when the callback is processed:

**Error**:
```
[error] ** (UndefinedFunctionError) function Ueberauth.Auth.Credentials.fetch/2 is undefined
(Ueberauth.Auth.Credentials does not implement the Access behaviour

You can use the "struct.field" syntax to access struct fields. You can also use Access.key!/1
to access struct fields dynamically inside get_in/put_in/update_in)
    (ueberauth 0.10.8) Ueberauth.Auth.Credentials.fetch(%Ueberauth.Auth.Credentials{...}, :token)
    (elixir 1.19.1) lib/access.ex:326: Access.get/3
    (phoenix_kit 1.4.6) lib/phoenix_kit/users/oauth.ex:112: PhoenixKit.Users.OAuth.extract_oauth_data/1
    (phoenix_kit 1.4.6) lib/phoenix_kit/users/oauth.ex:23: PhoenixKit.Users.OAuth.handle_oauth_callback/2
    (phoenix_kit 1.4.6) lib/phoenix_kit_web/users/oauth.ex:156: PhoenixKitWeb.Users.OAuth.callback/2
```

The OAuth flow **completely fails** at the callback stage, preventing users from logging in.

### Why This Happens

In Elixir, bracket notation (`struct[:key]`) only works for:
- **Maps**: `%{key: "value"}[:key]` ✅
- **Keyword lists**: `[key: "value"][:key]` ✅
- **Structs with Access behaviour**: Custom implementation required ❌

Structs use **dot notation** by default:
- **Correct**: `struct.field` ✅
- **Incorrect**: `struct[:field]` ❌

The `Ueberauth.Auth.Credentials` struct is defined as:

```elixir
defmodule Ueberauth.Auth.Credentials do
  @type t :: %__MODULE__{
          token: String.t() | nil,
          refresh_token: String.t() | nil,
          token_type: String.t() | nil,
          secret: String.t() | nil,
          expires: boolean,
          expires_at: integer | nil,
          scopes: [String.t()],
          other: map
        }

  defstruct token: nil,
            refresh_token: nil,
            token_type: nil,
            secret: nil,
            expires: false,
            expires_at: nil,
            scopes: [],
            other: %{}
end
```

It does **NOT** implement `Access` behaviour, so bracket notation fails.

### Our Workaround

Created a patched module that correctly accesses struct fields:

**File**: `lib/beamlab/phoenix_kit_oauth_patch.ex`

```elixir
defmodule Beamlab.PhoenixKitOAuthPatch do
  @moduledoc """
  Patches PhoenixKit v1.4.6 OAuth bug where it tries to access struct fields using bracket notation.

  Bug: PhoenixKit.Users.OAuth.extract_oauth_data/1 uses `auth.credentials[:token]`
  Fix: Use `auth.credentials.token` instead (dot notation for structs)

  This module can be removed once PhoenixKit fixes this issue.
  """

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Users.OAuth, as: PhoenixKitOAuth

  require Logger

  def handle_oauth_callback(%Ueberauth.Auth{} = auth, opts \\ []) do
    Logger.debug("Beamlab OAuth: Handling callback for provider: #{auth.provider}")

    # Extract OAuth data with proper struct field access (FIXED)
    oauth_data = extract_oauth_data_fixed(auth)

    track_geolocation = Keyword.get(opts, :track_geolocation, false)
    ip_address = Keyword.get(opts, :ip_address)
    referral_code = Keyword.get(opts, :referral_code)

    # Use PhoenixKit's existing transaction-based logic
    Repo.transaction(fn ->
      with {:ok, user, _status} <-
             PhoenixKitOAuth.find_or_create_user(oauth_data, track_geolocation, ip_address),
           {:ok, _provider} <- PhoenixKitOAuth.link_oauth_provider(user, oauth_data),
           :ok <- maybe_process_referral_code(user, referral_code) do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # FIXED: Use dot notation instead of bracket notation for struct field access
  defp extract_oauth_data_fixed(%Ueberauth.Auth{} = auth) do
    %{
      provider: to_string(auth.provider),
      provider_uid: to_string(auth.uid),
      email: auth.info.email,
      first_name: auth.info.first_name,
      last_name: auth.info.last_name,
      image: auth.info.image,
      # FIX: Use dot notation for struct fields instead of bracket notation
      access_token: auth.credentials.token,           # ✅ FIXED
      refresh_token: auth.credentials.refresh_token,  # ✅ FIXED
      token_expires_at: get_token_expires_at(auth.credentials),
      raw_info: get_raw_info(auth.extra)              # ✅ FIXED
    }
  end

  # Handle raw_info which might be in different formats
  defp get_raw_info(%{raw_info: raw_info}), do: raw_info
  defp get_raw_info(_), do: %{}

  defp get_token_expires_at(%{expires_at: expires_at}) when is_integer(expires_at) do
    DateTime.from_unix!(expires_at)
  end

  defp get_token_expires_at(_), do: nil

  # Process referral code if provided
  defp maybe_process_referral_code(_user, nil), do: :ok

  defp maybe_process_referral_code(user, referral_code) when is_binary(referral_code) do
    if Code.ensure_loaded?(PhoenixKit.ReferralCodes) do
      case PhoenixKit.ReferralCodes.process_referral_code(user, referral_code) do
        {:ok, _} -> :ok
        {:error, _} -> :ok  # Don't fail the OAuth flow if referral code processing fails
      end
    else
      :ok
    end
  end
end
```

Created custom OAuth controller to use the patched version:

**File**: `lib/beamlab_web/controllers/oauth_controller.ex`

```elixir
defmodule BeamlabWeb.OAuthController do
  use BeamlabWeb, :controller

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: UserAuth

  require Logger

  plug PhoenixKitWeb.Plugs.EnsureOAuthScheme
  plug PhoenixKitWeb.Plugs.EnsureOAuthConfig
  plug Ueberauth

  def request(conn, params) do
    # Delegate to PhoenixKit's request handler (this part works fine)
    PhoenixKitWeb.Users.OAuth.request(conn, params)
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    Logger.debug("Beamlab OAuth callback for provider: #{auth.provider}")

    track_geolocation = Settings.get_boolean_setting("track_registration_geolocation", false)
    ip_address = extract_ip_address(conn)
    referral_code = get_session(conn, :oauth_referral_code)
    return_to = get_session(conn, :oauth_return_to)

    opts = [
      track_geolocation: track_geolocation,
      ip_address: ip_address,
      referral_code: referral_code
    ]

    # Use our PATCHED version instead of PhoenixKit's buggy one
    case Beamlab.PhoenixKitOAuthPatch.handle_oauth_callback(auth, opts) do
      {:ok, user} ->
        Logger.info("Beamlab: OAuth authentication successful for user #{user.id}")

        conn
        |> delete_session(:oauth_referral_code)
        |> delete_session(:oauth_return_to)
        |> put_flash(:info, "Successfully signed in with #{format_provider_name(auth.provider)}!")
        |> UserAuth.log_in_user(user, return_to: return_to)

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("Beamlab: OAuth authentication failed: #{inspect(changeset.errors)}")

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: Routes.path("/users/log-in"))

      {:error, reason} ->
        Logger.error("Beamlab: OAuth authentication error: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Authentication failed. Please try again or use a different sign-in method.")
        |> redirect(to: Routes.path("/users/log-in"))
    end
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    Logger.warning("Beamlab: OAuth authentication failure: #{inspect(failure)}")

    message =
      case failure.errors do
        [%{message: msg} | _] when is_binary(msg) -> "Authentication failed: #{msg}"
        _ -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: Routes.path("/users/log-in"))
  end

  def callback(conn, _params) do
    Logger.error("Beamlab: Unexpected OAuth callback without auth or failure")

    conn
    |> put_flash(:error, "Authentication failed. Please try again.")
    |> redirect(to: Routes.path("/users/log-in"))
  end

  defp extract_ip_address(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: {a, b, c, d}} when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) ->
        "#{a}.#{b}.#{c}.#{d}"

      %{address: {a, b, c, d, e, f, g, h}} ->
        parts = [a, b, c, d, e, f, g, h]
        Enum.map_join(parts, ":", &Integer.to_string(&1, 16))

      _ ->
        nil
    end
  end

  defp format_provider_name(provider) when is_atom(provider) do
    provider |> to_string() |> format_provider_name()
  end

  defp format_provider_name("google"), do: "Google"
  defp format_provider_name("apple"), do: "Apple"
  defp format_provider_name("github"), do: "GitHub"
  defp format_provider_name("facebook"), do: "Facebook"
  defp format_provider_name(provider), do: String.capitalize(provider)
end
```

Override PhoenixKit routes in router:

**File**: `lib/beamlab_web/router.ex`

```elixir
# Override PhoenixKit OAuth routes to use our patched controller
# This fixes PhoenixKit v1.4.6 bug with struct field access
# Must be defined BEFORE phoenix_kit_routes() to take precedence
scope "/phoenix_kit" do
  pipe_through :browser

  get "/users/auth/:provider", BeamlabWeb.OAuthController, :request
  get "/users/auth/:provider/callback", BeamlabWeb.OAuthController, :callback
end

phoenix_kit_routes()
```

### Recommended Fix for PhoenixKit

**File**: `lib/phoenix_kit/users/oauth.ex`
**Function**: `extract_oauth_data/1` (lines 104-117)

```elixir
defp extract_oauth_data(%Ueberauth.Auth{} = auth) do
  %{
    provider: to_string(auth.provider),
    provider_uid: to_string(auth.uid),
    email: auth.info.email,
    first_name: auth.info.first_name,
    last_name: auth.info.last_name,
    image: auth.info.image,
    # FIXED: Use dot notation for struct fields
    access_token: auth.credentials.token,           # ✅ Changed from auth.credentials[:token]
    refresh_token: auth.credentials.refresh_token,  # ✅ Changed from auth.credentials[:refresh_token]
    token_expires_at: get_token_expires_at(auth.credentials),
    raw_info: get_raw_info(auth.extra)              # ✅ Changed from auth.extra[:raw_info]
  }
end

# Add helper function to safely extract raw_info
defp get_raw_info(%{raw_info: raw_info}), do: raw_info
defp get_raw_info(_), do: %{}
```

---

## Additional Observations

### GitHub OAuth Module Name Issue

There's also a separate bug where PhoenixKit uses the wrong module name for GitHub OAuth.

**Current PhoenixKit code** (hypothetical, based on our fix):
```elixir
{Ueberauth.Strategy.GitHub, opts}  # ❌ Wrong - capital H
```

**Correct module name**:
```elixir
{Ueberauth.Strategy.Github, opts}  # ✅ Correct - lowercase h
```

The `ueberauth_github` package uses `Github` (lowercase 'h'), not `GitHub` (capital 'H').

**Our workaround** in `lib/beamlab/application.ex`:

```elixir
defp fix_github_oauth_module_name do
  require Logger

  current_config = Application.get_env(:ueberauth, Ueberauth, [])
  providers = Keyword.get(current_config, :providers, %{})

  github_config = case providers do
    providers when is_map(providers) -> Map.get(providers, :github)
    providers when is_list(providers) -> Keyword.get(providers, :github)
    _ -> nil
  end

  case github_config do
    {Ueberauth.Strategy.GitHub, opts} ->
      Logger.debug("OAuth: Fixing GitHub module name (GitHub -> Github)")

      fixed_providers = case providers do
        providers when is_map(providers) ->
          Map.put(providers, :github, {Ueberauth.Strategy.Github, opts})
        providers when is_list(providers) ->
          providers
          |> Keyword.delete(:github)
          |> Keyword.put(:github, {Ueberauth.Strategy.Github, opts})
      end

      Application.put_env(:ueberauth, Ueberauth, Keyword.put(current_config, :providers, fixed_providers))

      # Also fix the OAuth strategy config
      github_oauth_config = Application.get_env(:ueberauth, Ueberauth.Strategy.GitHub.OAuth, [])
      if github_oauth_config != [] do
        Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, github_oauth_config)
        Logger.debug("OAuth: Fixed GitHub OAuth strategy config")
      end

      Logger.info("OAuth: GitHub module name fixed (Github with lowercase 'h')")

    _ ->
      :ok
  end
end
```

---

## Testing Performed

### Test Environment
- **Phoenix**: 1.8.1
- **Elixir**: 1.19.1
- **PhoenixKit**: 1.4.6
- **Ueberauth**: 0.10.8
- **Ueberauth Google**: 0.12.1
- **Ueberauth GitHub**: 0.8.3

### Test Cases

1. ✅ **Google OAuth Login** - Successfully redirects to Google, receives callback, creates/logs in user
2. ✅ **New User Registration via OAuth** - Creates new user account with confirmed email
3. ✅ **Existing User OAuth Login** - Links OAuth provider to existing account
4. ✅ **Token Storage** - Access tokens and refresh tokens properly stored
5. ✅ **Session Management** - User logged in with proper session after OAuth

### Before Fix
- ❌ Request phase: "Ueberauth plugin did not process request for provider"
- ❌ Callback phase: `UndefinedFunctionError` for `Ueberauth.Auth.Credentials.fetch/2`
- ❌ OAuth completely non-functional

### After Fix
- ✅ Request phase: Proper redirect to OAuth provider
- ✅ Callback phase: User created/authenticated successfully
- ✅ OAuth fully functional

---

## Recommendations for PhoenixKit Maintainers

### Priority 1: Critical Bugs (Breaks OAuth entirely)

1. **Fix struct field access in `extract_oauth_data/1`**
   - Change `auth.credentials[:token]` → `auth.credentials.token`
   - Change `auth.credentials[:refresh_token]` → `auth.credentials.refresh_token`
   - Change `auth.extra[:raw_info]` → safe extraction with pattern matching

2. **Preserve base_path in Ueberauth configuration**
   - Don't overwrite entire config in `configure_ueberauth_base/0`
   - Set base_path based on PhoenixKit URL prefix
   - Log the base_path for debugging

### Priority 2: Improvements

3. **Better error messages**
   - Don't suggest checking credentials when the issue is base_path mismatch
   - Add debug logging for Ueberauth configuration state
   - Check `conn.state` and provide specific error messages

4. **Add tests for OAuth flow**
   - Test that Ueberauth config includes base_path
   - Test struct field access doesn't use bracket notation
   - Test full OAuth callback flow with mock provider

5. **Documentation**
   - Document the base_path requirement
   - Add troubleshooting guide for OAuth issues
   - Clarify that credentials are stored in database, not environment variables

### Priority 3: GitHub OAuth Module Name

6. **Fix GitHub module name**
   - Use `Ueberauth.Strategy.Github` (lowercase 'h')
   - Not `Ueberauth.Strategy.GitHub` (capital 'H')

---

## Impact Assessment

### Without These Fixes
- **OAuth is completely broken** in PhoenixKit 1.4.6
- Every project using PhoenixKit OAuth needs these workarounds
- Users cannot log in via Google, GitHub, or other OAuth providers
- Misleading error messages waste developer time

### With These Fixes
- OAuth works out-of-the-box
- No application-level workarounds needed
- Better developer experience
- Clear error messages

---

## Files Affected in Our Workaround

1. `config/config.exs` - Added base_path to Ueberauth config
2. `config/runtime.exs` - Added oauth_base_url for PhoenixKit
3. `lib/beamlab/application.ex` - Added `fix_ueberauth_base_path()` and `fix_github_oauth_module_name()`
4. `lib/beamlab/phoenix_kit_oauth_patch.ex` - Patched OAuth callback handler
5. `lib/beamlab_web/controllers/oauth_controller.ex` - Custom OAuth controller using patch
6. `lib/beamlab_web/router.ex` - Override PhoenixKit OAuth routes

**Total**: 6 files modified, ~300 lines of workaround code

---

## Conclusion

Both bugs are **critical** and **trivial to fix** in the PhoenixKit library itself. The fixes involve:
1. Using dot notation instead of bracket notation for structs (2 lines changed)
2. Preserving base_path when configuring Ueberauth (5 lines changed)

These changes would eliminate the need for complex workarounds in every PhoenixKit project that uses OAuth.

We recommend PhoenixKit maintainers:
1. Apply these fixes in the next patch release (v1.4.7)
2. Add integration tests for OAuth flows
3. Improve error messages to help developers troubleshoot issues

---

## Contact

For questions about this document or the issues described:
- **Project**: Beamlab (https://ddon-dev.beamlab.eu)
- **Date Discovered**: October 29, 2025
- **PhoenixKit Version**: 1.4.6

---

## Appendix: Complete Error Stack Traces

### Error 1: Base Path Mismatch

```
[info] GET /phoenix_kit/users/auth/google
[debug] Processing with PhoenixKitWeb.Users.OAuth.request/2
  Parameters: %{"provider" => "google"}
  Pipelines: [:browser, :phoenix_kit_auto_setup]
[debug] PhoenixKit OAuth request for provider: google
[debug] PhoenixKit OAuth: Available providers: ["github", "google"]
[error] PhoenixKit OAuth: Ueberauth plugin did not process request for provider. Check if GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET environment variables are set correctly.
[info] Sent 302 in 17ms
[info] GET /phoenix_kit/users/log-in
```

### Error 2: Struct Access with Bracket Notation

```
[error] ** (UndefinedFunctionError) function Ueberauth.Auth.Credentials.fetch/2 is undefined (Ueberauth.Auth.Credentials does not implement the Access behaviour

You can use the "struct.field" syntax to access struct fields. You can also use Access.key!/1 to access struct fields dynamically inside get_in/put_in/update_in)
    (ueberauth 0.10.8) Ueberauth.Auth.Credentials.fetch(%Ueberauth.Auth.Credentials{token: "ya29.A0ATi6K2uxgnBNuflZm7p5onlKOhq0iO70wLe5gyyc7glEwMfmbII2Q5cFBRXY_O_y06RCltXAXQvtAoP2zs5RVMLg5zuz5eqkV7R98528l3A6Ssh3Fp1RNYEyK3ckpGA0MCEGAn1yicTu2LsPJPRJVauM6AAeBUD0ei8u-QxkUZXeOctI3ClOtZGf-gxjSeiGz6GuMPdhZA-cTgV-K9bU6t0veEXXc20jqdx7eQ9TCb5HLgRNFTHIAngBYcIooI-bJgVMHLn87DTcHiYEKc4dQkzFT3cQpQaCgYKAVoSARUSFQHGX2MiTe4JghUQ08V7u7woRRSBgw0293", refresh_token: nil, token_type: "Bearer", secret: nil, expires: true, expires_at: 1761772247, scopes: ["https://www.googleapis.com/auth/userinfo.email", "openid"], other: %{}}, :token)
    (elixir 1.19.1) lib/access.ex:326: Access.get/3
    (phoenix_kit 1.4.6) lib/phoenix_kit/users/oauth.ex:112: PhoenixKit.Users.OAuth.extract_oauth_data/1
    (phoenix_kit 1.4.6) lib/phoenix_kit/users/oauth.ex:23: PhoenixKit.Users.OAuth.handle_oauth_callback/2
    (phoenix_kit 1.4.6) lib/phoenix_kit_web/users/oauth.ex:156: PhoenixKitWeb.Users.OAuth.callback/2
```

---

**End of Document**

---

## Required Configuration: oauth_base_url

### Not a Workaround - Legitimate PhoenixKit Configuration

The `oauth_base_url` setting in `config/runtime.exs` is **NOT a workaround** for the bugs above. It's a legitimate PhoenixKit configuration option used by the `EnsureOAuthScheme` plug.

**Purpose**: Ensures correct HTTPS redirect URIs when deploying behind proxies that don't forward protocol headers.

**Configuration**:
```elixir
# config/runtime.exs
config :phoenix_kit,
  oauth_base_url: "https://#{app_config.phx_host}"
```

**Why it's needed**:

PhoenixKit's `EnsureOAuthScheme` plug checks in this order:
1. `X-Forwarded-Proto` header from nginx/proxy (preferred)
2. `oauth_base_url` config setting (fallback)
3. Endpoint URL config (last resort)

Without this setting AND without proxy headers, OAuth redirect URIs would be incorrect:
- ❌ Without config: `http://domain.com:4000/phoenix_kit/users/auth/google/callback`
- ✅ With config: `https://domain.com/phoenix_kit/users/auth/google/callback`

**This is standard configuration for production deployments**, not a bug fix.

---

## Summary: What Was Fixed vs What Was Configured

### Fixed in PhoenixKit Library (deps/phoenix_kit/)

1. ✅ **Struct field access bug** - Changed bracket notation to dot notation
2. ✅ **Base path preservation** - Preserve `base_path` in Ueberauth config

**Total changes**: ~15 lines in 2 files
**Impact**: Fixes OAuth for all PhoenixKit projects

### Configured in Application (config/runtime.exs)

1. ✅ **oauth_base_url** - Standard PhoenixKit configuration for proxy deployments

**Total changes**: 3 lines
**Impact**: Ensures correct HTTPS URLs when proxy doesn't send headers

### Test Results

✅ Google OAuth login working
✅ Redirect URI correctly generated: `https://ddon-dev.beamlab.eu/phoenix_kit/users/auth/google/callback`
✅ User authentication and session creation successful
✅ No application-level workarounds required

