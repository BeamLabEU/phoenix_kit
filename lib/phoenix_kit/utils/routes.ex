defmodule PhoenixKit.Utils.Routes do
  @moduledoc """
  Utility functions for working with PhoenixKit routes and URLs.

  This module provides helpers for constructing URLs with the correct
  PhoenixKit prefix configured in the application.
  """

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper

  @default_locale Config.default_locale()

  # List of path prefixes that should NEVER have a locale added.
  # This should be kept in sync with @reserved_segments in LocaleExtractor plug.
  @reserved_prefixes ~w(/api /webhooks /assets /static /files /images /fonts /js /css /sitemap)

  @doc """
  Returns the configured PhoenixKit URL prefix.

  ## Examples

      iex> PhoenixKit.Utils.Routes.url_prefix()
      "/phoenix_kit"

  """
  @spec url_prefix() :: String.t()
  def url_prefix, do: Config.get_url_prefix()

  @doc """
  Returns `true` when `path` is safe to use as a local redirect / `return_to`
  target: a binary that begins with a single `/` but not `//` or `/\\` — both of
  which browsers resolve as protocol-relative, host-switching URLs. Use this to
  guard user-supplied redirect params against open-redirect attacks.

  ASCII control characters are rejected too. Browsers strip tab/CR/LF while
  parsing a URL, so `"/\\t/evil.example"` (from `?return_to=%2F%09%2Fevil.example`)
  becomes `//evil.example` — a cross-origin navigation — once it reaches
  `window.location`. `Phoenix.Controller.redirect/2` blocks those itself, but
  LiveView's `validate_local_url!` only rejects `\\\\` and a leading `//`, so a
  LiveView `redirect(socket, to: ...)` would otherwise pass it through.

  ## Examples

      iex> PhoenixKit.Utils.Routes.local_path?("/admin/dashboard")
      true
      iex> PhoenixKit.Utils.Routes.local_path?("//evil.com")
      false
      iex> PhoenixKit.Utils.Routes.local_path?("https://evil.com")
      false
      iex> PhoenixKit.Utils.Routes.local_path?("/\\t/evil.com")
      false

  """
  @spec local_path?(term()) :: boolean()
  def local_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.starts_with?(path, "/\\") and
      not contains_control_char?(path)
  end

  def local_path?(_), do: false

  # ASCII control chars (C0 + DEL). Checked bytewise: a control char is
  # single-byte in UTF-8 and can never appear inside a multi-byte sequence.
  defp contains_control_char?(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte <= 0x1F or byte == 0x7F end)
  end

  @doc """
  Resolves where to send a user once they are signed in and confirmed.

  Takes candidate destinations in priority order (e.g. a `?return_to=` param,
  then the session's `user_return_to`) and returns the first that passes
  `local_path?/1`. Falls back to the `after_login_path` setting, and finally
  to `"/"`.

  The setting is validated as a local path when saved, but is re-guarded here
  so a hand-edited DB row can't turn a post-auth redirect into an open
  redirect. Single source of truth for the post-auth landing page — used by
  the login flow (`signed_in_path/1`) and by both confirmation LiveViews.

  ## Examples

      iex> PhoenixKit.Utils.Routes.post_auth_path(["/checkout"])
      "/checkout"
      iex> PhoenixKit.Utils.Routes.post_auth_path(["https://evil.com", nil])
      "/"

  """
  @spec post_auth_path([term()]) :: String.t()
  def post_auth_path(candidates \\ []) when is_list(candidates) do
    Enum.find(candidates, &local_path?/1) || after_login_path()
  end

  defp after_login_path do
    path = PhoenixKit.Settings.get_setting("after_login_path", "/")

    if local_path?(path), do: path, else: "/"
  end

  # NOTE: Locale override logic below exists for the publishing component system integration.
  # Switch to the upcoming media/storage helpers once they land.
  def path(url_path, opts \\ [])

  def path("/" <> _ = url_path, opts) do
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_path = if url_prefix === "/", do: "", else: url_prefix

    cond do
      # Admin paths follow the same primary-prefixless rule as non-admin
      # paths (see `build_admin_path/3`). The dual-scope router emission
      # keeps `/phoenix_kit/admin/*` AND `/phoenix_kit/:locale/admin/*`
      # both reachable, so the emitted shape is purely cosmetic.
      admin_path?(url_path) ->
        locale = resolve_locale(opts)
        build_admin_path(base_path, url_path, locale)

      # Reserved paths (API, webhooks, assets) NEVER get a locale prefix.
      reserved_path?(url_path) ->
        "#{base_path}#{url_path}"

      true ->
        build_localized_path(base_path, url_path, opts)
    end
  end

  def path(_url_path, _opts) do
    raise """
    Url path must start with "/".
    """
  end

  defp build_localized_path(base_path, url_path, opts) do
    locale = resolve_locale(opts)
    build_path_with_locale(base_path, url_path, locale)
  end

  defp resolve_locale(opts) do
    case Keyword.fetch(opts, :locale) do
      {:ok, :none} -> :none
      {:ok, nil} -> determine_locale()
      {:ok, locale_value} -> locale_value
      :error -> determine_locale()
    end
  end

  defp build_path_with_locale(base_path, url_path, :none), do: "#{base_path}#{url_path}"

  defp build_path_with_locale(base_path, url_path, locale_value) do
    if default_locale?(locale_value) and prefixless_primary?() do
      "#{base_path}#{url_path}"
    else
      locale_prefixed_path(base_path, locale_value, url_path)
    end
  end

  # Builds a locale-prefixed URL (`/{locale}{url_path}`).
  #
  # The bare root (`url_path == "/"`) is special-cased to emit
  # `/{locale}` rather than `/{locale}/`: Phoenix routers do not match a
  # trailing slash, so a `/:locale` landing route declared by the parent
  # app would 404 on `/{locale}/`. Every other path keeps its leading
  # slash, so the concatenation is already correct.
  defp locale_prefixed_path(base_path, locale, "/"), do: "#{base_path}/#{locale}"
  defp locale_prefixed_path(base_path, locale, url_path), do: "#{base_path}/#{locale}#{url_path}"

  # Check if a path is an admin path.
  defp admin_path?(url_path), do: String.starts_with?(url_path, "/admin")

  # Admin paths follow the same primary-prefix rule as non-admin paths.
  # Both URL shapes (`/admin/*` and `/:locale/admin/*`) are emitted by the
  # admin route macros so either shape is routable; the choice between
  # them is the cosmetic site-wide setting controlled via
  # `Languages.default_language_no_prefix?/0`.
  #
  # The two shapes share one `live_session :phoenix_kit_admin`, so
  # switching locales inside admin stays on the WebSocket
  # (`push_navigate`) — no full-page reload. See `generate_admin_routes/2`
  # in `PhoenixKitWeb.Integration`.
  defp build_admin_path(base_path, url_path, :none), do: "#{base_path}#{url_path}"

  defp build_admin_path(base_path, url_path, locale) when is_binary(locale) do
    if default_locale?(locale) and prefixless_primary?() do
      "#{base_path}#{url_path}"
    else
      "#{base_path}/#{locale}#{url_path}"
    end
  end

  defp build_admin_path(base_path, url_path, _), do: "#{base_path}#{url_path}"

  # Reads the site-wide setting controlled by the Languages admin page.
  # Defers to the canonical boot-safe wrapper on `Languages` so all
  # URL-emission call sites (this module + `Users.Auth`) share one
  # rescue policy.
  defp prefixless_primary?, do: Languages.prefixless_primary_safe?()

  # Check if a path starts with one of the reserved prefixes.
  defp reserved_path?(path) do
    Enum.any?(@reserved_prefixes, &String.starts_with?(path, &1))
  end

  defp determine_locale do
    # Fall back to extracting base from Gettext locale
    # This is only used when locale is not explicitly passed to Routes.path
    # Gettext.get_locale/1 always returns a string
    locale = Gettext.get_locale(PhoenixKitWeb.Gettext)
    DialectMapper.extract_base(locale)
  end

  # Check if the given locale is the default language
  # Default locale doesn't need a prefix in URLs for cleaner URLs
  defp default_locale?(locale) do
    default = get_default_language_base()
    locale == default
  end

  defp get_default_language_base do
    # During mix tasks (like phoenix_kit.install), the database may not have
    # the settings table yet. We detect this by checking if we're in a mix task
    # context and fall back to "en" to avoid database errors.
    if mix_task_context?() do
      "en"
    else
      case Languages.get_default_language() do
        %{code: code} when is_binary(code) -> DialectMapper.extract_base(code)
        _ -> "en"
      end
    end
  rescue
    _ -> "en"
  catch
    # A connection-pool failure EXITS rather than raising, so `rescue` alone
    # never delivered the "path building works without a reachable database"
    # guarantee above. Seen as a flaky suite failure: the settings read is
    # ETS-cached, so a DB-less test only reached the pool on a cache miss —
    # which another test's settings write could cause at any time.
    :exit, _ -> "en"
  end

  # Detect if we're running in a mix task context where the database
  # may not be fully set up yet
  defp mix_task_context? do
    # Check if Mix is loaded and we're not in a running application context
    # The settings cache being unavailable is a reliable indicator
    case Process.get(:phoenix_kit_config_status) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Returns a locale-aware admin path. For non-primary locales the locale
  segment is always emitted. For the primary locale the shape follows
  the site-wide `default_language_no_prefix` setting
  (`Languages.default_language_no_prefix?/0`): prefixless when the
  setting is on, prefixed when off.

  Both URL shapes resolve at the router level — the admin route macros
  declare `/:locale/admin/*` AND `/admin/*` scopes — so either shape is
  routable. The two shapes share one `live_session :phoenix_kit_admin`,
  so locale switching across them stays on the WebSocket
  (`push_navigate`) without a full-page reload.

  ## Examples

      iex> Routes.admin_path("/admin/users", "uk")
      "/phoenix_kit/uk/admin/users"

      iex> Routes.admin_path("/admin/users", nil)
      "/phoenix_kit/admin/users"

  Primary-locale shape depends on the `default_language_no_prefix`
  setting (not shown as doctests because the result varies with
  runtime state):

      # setting OFF (default)
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/en/admin/users"

      # setting ON
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/admin/users"

  """
  def admin_path(url_path, locale) when is_binary(locale) do
    url_prefix = Config.get_url_prefix()
    base_prefix = if url_prefix == "/", do: "", else: url_prefix

    if default_locale?(locale) and prefixless_primary?() do
      "#{base_prefix}#{url_path}"
    else
      "#{base_prefix}/#{locale}#{url_path}"
    end
  end

  def admin_path(url_path, _locale), do: path(url_path)

  @doc """
  Returns a locale-aware path using locale from assigns.

  This function is specifically designed for use in component templates
  where the locale needs to be passed explicitly via assigns.

  Prefers base locale code for URL generation (current_locale_base),
  falls back to extracting base from full dialect code (current_locale).
  """
  def locale_aware_path(assigns, url_path) do
    # Prefer base code, fall back to extracting from full dialect
    locale =
      assigns[:current_locale_base] ||
        DialectMapper.extract_base(assigns[:current_locale] || @default_locale)

    path(url_path, locale: locale)
  end

  @doc """
  Returns the default locale (base code) from the Languages module.

  Extracts the base code from the default language (e.g., "en-US" becomes "en").
  Falls back to "en" if no default language is configured.

  ## Examples

      iex> Routes.get_default_admin_locale()
      "en"
  """
  def get_default_admin_locale do
    get_default_language_base()
  end

  @doc """
  Returns a full url with preconfigured prefix.

  This function first checks for a configured site URL in Settings,
  then automatically detects the correct URL from the running Phoenix
  application endpoint when possible, falling back to static configuration.
  This ensures that magic links and other email links work correctly in both
  development and production environments, with full control over the base URL
  through the Settings admin panel.
  """
  def url(url_path) do
    base_url = get_base_url_for_emails()
    full_path = path(url_path)

    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{full_path}"
  end

  @doc """
  The bare base URL (scheme + host, no trailing slash), same source `url/1` uses.

  For absolutizing a path that is **already** url-prefixed and locale-prefixed
  (e.g. a notification's `link`, built via `path/1`) — concatenate it onto this
  directly. Do NOT pass such a path to `url/1`, which re-applies `path/1` and
  would double-prefix it.
  """
  @spec base_url() :: String.t()
  def base_url, do: String.trim_trailing(get_base_url_for_emails(), "/")

  # Gets the base URL for email links.
  #
  # Priority:
  # 1. site_url setting from Settings (if configured)
  # 2. Dynamic URL from Phoenix endpoint
  # 3. Static configuration fallback
  #
  # This allows administrators to override the email link URLs through
  # the Settings panel, which is especially useful in production.
  defp get_base_url_for_emails do
    case PhoenixKit.Settings.get_setting("site_url", "") do
      "" ->
        PhoenixKit.Config.get_dynamic_base_url()

      site_url when is_binary(site_url) ->
        site_url
    end
  end

  @doc """
  Gets the base module name for the parent application.

  Reads from :phoenix_kit, :layouts_module config (e.g., MprojectWeb.Layouts -> MprojectWeb).

  ## Examples

      iex> PhoenixKit.Utils.Routes.phoenix_kit_app_base()
      "MprojectWeb"

  """
  @spec phoenix_kit_app_base() :: String.t()
  def phoenix_kit_app_base do
    case PhoenixKit.Config.get(:layouts_module) do
      {:ok, module} when is_atom(module) ->
        module
        |> Module.split()
        # Drop last segment (Layouts)
        |> Enum.slice(0..-2//1)
        |> Module.concat()

      _ ->
        "AppWeb"
    end
  end
end
