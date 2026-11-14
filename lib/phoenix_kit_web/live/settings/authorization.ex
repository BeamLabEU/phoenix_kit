defmodule PhoenixKitWeb.Live.Settings.Authorization do
  @moduledoc """
  Authorization settings management LiveView for PhoenixKit.

  Manages login page branding and authentication methods including
  magic links and OAuth provider configuration.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.EmailDomain
  alias PhoenixKit.Users.OAuthConfig
  alias PhoenixKit.Users.Passkeys
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Turnstile
  alias PhoenixKit.Utils.CssValue
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Settings.SecurityGate
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  require Logger

  # S009: the only OAuth setting keys this page renders as `type="password"`
  # inputs. The template never echoes the real value into `value=` (see
  # authorization.html.heex), so an untouched field submits blank on every
  # `validate_settings`/`save_settings` event — `preserve_unset_secrets/2`
  # is what keeps that blank from overwriting the real stored secret.
  # Deliberately NOT `Settings.restricted_setting_keys()`: that list also
  # covers `aws_access_key_id`/`aws_secret_access_key`, which this page
  # never renders.
  @oauth_secret_keys ~w(oauth_google_client_secret oauth_github_client_secret oauth_facebook_app_secret)

  # Not password-masked, always resubmitted with the real (typed) value, so
  # no `preserve_unset_secrets/2`-style handling is needed — only trimming,
  # for the same copy-paste-padding reason as `@oauth_secret_keys`.
  @oauth_id_keys ~w(oauth_google_client_id oauth_github_client_id oauth_facebook_app_id)

  # `settings.security` on top of the admin gate's own check (`SecurityGate`).
  def mount(params, session, socket) do
    if SecurityGate.allowed?(socket),
      do: do_mount(params, session, SecurityGate.attach(socket)),
      else: {:ok, SecurityGate.refuse(socket)}
  end

  defp do_mount(_params, _session, socket) do
    current_settings = Settings.list_all_settings()
    defaults = Settings.get_defaults()

    # Turnstile's secret belongs to its own form below and is never needed
    # here: kept out of the assigns altogether.
    merged_settings =
      defaults |> Map.merge(current_settings) |> Map.delete("turnstile_secret_key")

    changeset = Settings.change_settings(merged_settings)

    socket =
      socket
      |> assign(:page_title, gettext("Authorization"))
      |> assign(
        :page_subtitle,
        gettext("Manage login page branding and authentication methods")
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:settings, merged_settings)
      |> assign(:saved_settings, merged_settings)
      |> assign(:changeset, changeset)
      |> assign(:saving, false)
      |> assign(
        :project_title,
        merged_settings["project_title"] || PhoenixKit.Config.get(:project_title, "PhoenixKit")
      )
      # The domain passkeys are made for, named next to the switch.
      |> assign(:passkey_domain, Passkeys.relying_party().rp_id)
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_target, nil)
      # Resolved when the selector opens — the host hook may create a folder.
      |> assign(:branding_scope_folder, nil)

    {:ok, socket}
  end

  # The tab lives in the URL (`?tab=sessions`); see `UrlTabs`.
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(:active_tab, UrlTabs.active(params, tabs()))
      # Read on every tab change, so the counters are those of the moment the
      # tab was opened. Configuration and in-memory counters; no database.
      |> assign(:request_limits, RateLimiter.overview())
      # The switch, the site key and whether a secret is saved; never the secret.
      |> assign(:turnstile, Turnstile.config())
      |> assign(:email_domain_check, email_domain_check_state())

    {:noreply, socket}
  end

  defp tabs do
    [
      %{id: "branding", label: gettext("Login Page Branding"), icon: "hero-paint-brush"},
      %{id: "methods", label: gettext("Authentication Methods"), icon: "hero-key"},
      %{id: "sessions", label: gettext("Sessions"), icon: "hero-user-group"},
      %{id: "protection", label: gettext("Abuse protection"), icon: "hero-shield-check"}
    ]
  end

  # Its own form and its own keys (`turnstile_*`, `settings.security` like the
  # rest of this page: `SecurityGate` re-checks on every event). The secret is
  # in the event's params only; it is never assigned.
  def handle_event("save_turnstile", %{"turnstile" => params}, socket) when is_map(params) do
    result = Turnstile.save_config(params, actor_uuid: Actor.uuid(socket), source: "settings")
    socket = assign(socket, :turnstile, Turnstile.config())

    case result do
      {:ok, :saved} ->
        {:noreply, put_flash(socket, :info, gettext("Turnstile settings saved."))}

      {:ok, :unverified} ->
        {:noreply,
         put_flash(
           socket,
           :warning,
           gettext(
             "Turnstile settings saved, but Cloudflare could not be reached to check the secret key."
           )
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, turnstile_error(reason))}
    end
  end

  # Its own form too: one switch, written straight to its setting.
  def handle_event("save_email_check", params, socket) do
    enabled? = get_in(params, ["email_check", "enabled"]) == "true"

    case Settings.update_boolean_setting(EmailDomain.setting_key(), enabled?,
           actor_uuid: Actor.uuid(socket),
           source: "settings"
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:email_domain_check, email_domain_check_state())
         |> put_flash(:info, gettext("Email address check saved."))}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("The email address check could not be saved."))}
    end
  end

  def handle_event("refresh_request_limits", _params, socket) do
    {:noreply, assign(socket, :request_limits, RateLimiter.overview())}
  end

  def handle_event("validate_settings", %{"settings" => settings_params}, socket) do
    settings_params = preserve_unset_secrets(settings_params, socket.assigns.settings)
    changeset = Settings.validate_settings(settings_params)

    socket =
      socket
      |> assign(:settings, settings_params)
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save_settings", %{"settings" => settings_params}, socket) do
    socket = assign(socket, :saving, true)

    with :ok <- validate_background_color(settings_params),
         :ok <- validate_oauth_secret_formats(settings_params) do
      do_save_settings(socket, trim_oauth_secrets(settings_params))
    else
      {:error, message} ->
        {:noreply, socket |> assign(:saving, false) |> put_flash(:error, message)}
    end
  end

  @oauth_providers %{"google" => :google, "github" => :github, "facebook" => :facebook}
  @media_targets %{
    "logo" => :logo,
    "background" => :background,
    "background_mobile" => :background_mobile
  }

  def handle_event("test_oauth", %{"provider" => provider}, socket)
      when is_map_key(@oauth_providers, provider) do
    provider_atom = @oauth_providers[provider]
    credentials = oauth_credentials_from_settings(provider_atom, socket.assigns.settings)

    case OAuthConfig.test_connection(provider_atom, credentials) do
      {:ok, message} ->
        {:noreply, put_flash(socket, :info, message)}

      {:inconclusive, message} ->
        {:noreply, put_flash(socket, :warning, message)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("reload_oauth_config", _params, socket) do
    OAuthConfig.configure_providers()
    {:noreply, put_flash(socket, :info, gettext("OAuth configuration reloaded from database"))}
  end

  def handle_event("open_media_selector", %{"target" => target}, socket)
      when is_map_key(@media_targets, target) do
    {:noreply,
     socket
     |> assign(
       :branding_scope_folder,
       PhoenixKit.UploadsParentFolder.resolve(:branding, Actor.uuid(socket), nil)
     )
     |> assign(:show_media_selector, true)
     |> assign(:media_selection_target, @media_targets[target])}
  end

  def handle_event("clear_branding_image", %{"target" => target}, socket) do
    key =
      case target do
        "logo" -> "auth_logo_file_uuid"
        "background" -> "auth_background_image_file_uuid"
        "background_mobile" -> "auth_background_image_mobile_file_uuid"
      end

    settings = Map.put(socket.assigns.settings, key, "")
    {:noreply, assign(socket, :settings, settings)}
  end

  ## Media selector callbacks

  def handle_info({:media_selected, file_uuids}, socket) do
    file_uuid = List.first(file_uuids) || ""

    key =
      case socket.assigns.media_selection_target do
        :logo -> "auth_logo_file_uuid"
        :background -> "auth_background_image_file_uuid"
        :background_mobile -> "auth_background_image_mobile_file_uuid"
      end

    settings = Map.put(socket.assigns.settings, key, file_uuid)

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:show_media_selector, false)
     |> assign(:media_selection_target, nil)}
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> assign(:media_selection_target, nil)}
  end

  # Helper functions

  # The background colour lands in a `<style>` element on every public auth
  # page, so it is refused on write as well as sanitised on read
  # (`PhoenixKitWeb.Components.AuthPageWrapper`). Rejecting here is what tells
  # the operator their value was not stored; the read-side guard is what keeps
  # the page safe regardless of what is already in the table.
  defp validate_background_color(%{"auth_background_color" => value})
       when is_binary(value) and value != "" do
    if CssValue.color(value) == "" do
      {:error,
       "Background color must be a plain CSS color or gradient — " <>
         "for example #1e293b, rgb(30 41 59) or linear-gradient(135deg, #667eea, #764ba2)"}
    else
      :ok
    end
  end

  defp validate_background_color(_settings_params), do: :ok

  # Gate the save on secret *format* the same way `validate_background_color/1`
  # gates it on color format — runs on the RAW submitted params, before
  # `preserve_unset_secrets/2` fills a blank field back in with whatever is
  # already stored. That ordering matters: an admin saving an unrelated
  # field (say, project_title) must not suddenly be blocked because an
  # OAuth secret saved before this fix already happens to be short — this
  # only rejects a secret the admin is actively typing right now, never one
  # that is merely being carried forward untouched.
  defp validate_oauth_secret_formats(settings_params) do
    Enum.reduce_while(@oauth_secret_keys, :ok, fn key, :ok ->
      case OAuthConfig.validate_secret_format(provider_for_secret_key(key), settings_params[key]) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp provider_for_secret_key("oauth_google_client_secret"), do: :google
  defp provider_for_secret_key("oauth_github_client_secret"), do: :github
  defp provider_for_secret_key("oauth_facebook_app_secret"), do: :facebook

  # `validate_secret_format/2` trims before checking length, but that
  # trimmed value never made it to disk on its own — a copy-paste with
  # leading/trailing whitespace ("  GOCSPX-...  ") passed the format gate
  # and then got persisted padded, which is not what Google issued and
  # fails the real OAuth flow. Runs after validation (on the raw params),
  # right before the params reach `do_save_settings`, so it only ever
  # trims a value that already passed the length/blank checks. Client
  # IDs are not format-gated the same way, but a padded one fails a real
  # provider round trip identically, so they are trimmed here too.
  defp trim_oauth_secrets(settings_params) do
    Enum.reduce(@oauth_secret_keys ++ @oauth_id_keys, settings_params, fn key, params ->
      case Map.get(params, key) do
        value when is_binary(value) -> Map.put(params, key, String.trim(value))
        _value -> params
      end
    end)
  end

  # S009: the template never renders a real OAuth secret into `value=`
  # (view-source can't leak it), so an untouched password field arrives here
  # blank. Blindly assigning that would blank out `@settings` for the key on
  # the next `validate_settings` event and wipe the stored secret on the
  # next `save_settings` — this restores the currently-held value for any of
  # `@oauth_secret_keys` that comes in blank, while a non-blank incoming
  # value (the admin actively typing a new secret) always wins.
  defp preserve_unset_secrets(new_params, current_settings) do
    Enum.reduce(@oauth_secret_keys, new_params, fn key, params ->
      case Map.get(params, key) do
        value when value in [nil, ""] -> Map.put(params, key, Map.get(current_settings, key, ""))
        _value -> params
      end
    end)
  end

  defp do_save_settings(socket, settings_params) do
    settings_params = preserve_unset_secrets(settings_params, socket.assigns.settings)

    case Settings.update_settings(settings_params,
           actor_uuid: Actor.uuid(socket),
           source: "settings",
           scope: socket.assigns[:phoenix_kit_current_scope]
         ) do
      {:ok, updated_settings} ->
        OAuthConfig.configure_providers()

        changeset = Settings.change_settings(updated_settings)

        socket =
          socket
          |> assign(:settings, updated_settings)
          |> assign(:saved_settings, updated_settings)
          |> assign(:changeset, changeset)
          |> assign(:saving, false)
          |> put_flash(:info, gettext("Authorization settings updated successfully"))

        {:noreply, socket}

      {:error, errors} ->
        error_msg = format_error_message(errors)

        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, error_msg)

        {:noreply, socket}
    end
  end

  defp format_error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Map.values()
    |> List.flatten()
    |> Enum.join(", ")
  end

  # `enabled`: what the switch is saved as. `overridden`: the application
  # configuration switches the check off whatever the setting says.
  defp email_domain_check_state do
    %{
      enabled: Settings.get_boolean_setting(EmailDomain.setting_key(), true),
      overridden: Application.get_env(:phoenix_kit, :email_domain_check, true) == false
    }
  end

  defp turnstile_error(:site_key_required),
    do: gettext("Enter the site key before switching Turnstile on.")

  defp turnstile_error(:secret_key_required),
    do: gettext("Enter the secret key before switching Turnstile on.")

  defp turnstile_error(:invalid_secret),
    do: gettext("Cloudflare does not recognise this secret key. Nothing was saved.")

  defp turnstile_error(_reason), do: gettext("The Turnstile settings could not be saved.")

  @doc false
  def request_limit_label(:login), do: gettext("Sign-in (failed attempts)")
  def request_limit_label(:registration), do: gettext("Registration")
  def request_limit_label(:magic_link), do: gettext("Magic link")
  def request_limit_label(:password_reset), do: gettext("Password reset")
  def request_limit_label(:confirmation_resend), do: gettext("Confirmation email resend")

  @doc false
  def format_request_limit(%{limit: limit, window_ms: window_ms}) do
    gettext("%{limit} per %{window}", limit: limit, window: format_limit_window(window_ms))
  end

  @doc false
  # Rounded up: "resets in 0 min" would read as "now" for most of a minute.
  def format_limit_window(ms) when ms < 60_000,
    do: gettext("%{count} s", count: max(ceil(ms / 1000), 1))

  def format_limit_window(ms) when ms < 3_600_000 or rem(ms, 3_600_000) != 0,
    do: gettext("%{count} min", count: ceil(ms / 60_000))

  def format_limit_window(ms), do: gettext("%{count} h", count: div(ms, 3_600_000))

  def signed_preview_url(file_uuid, variant) do
    URLSigner.signed_url(file_uuid, variant)
  end

  def get_oauth_callback_url(settings, provider) do
    site_url = settings["site_url"] || "https://example.com"
    url_prefix = PhoenixKit.Config.get_url_prefix()
    # "/" is the sentinel Config.get_url_prefix/0 returns for "no prefix"
    # (see compute_url_prefix/0) — treat it the same as "" here, matching
    # Routes.path/2 and UeberAuth.get_default_base_path/0.
    base_prefix = if url_prefix == "/", do: "", else: url_prefix

    "#{site_url}#{base_prefix}/users/auth/#{provider}/callback"
  end

  # S009: the three OAuth secret inputs render `value=""` unconditionally
  # (see authorization.html.heex), so this placeholder is the only signal an
  # admin gets that a secret is already stored, without ever putting the
  # real value in the DOM.
  def oauth_secret_placeholder(current_value, unset_placeholder) do
    if current_value in [nil, ""] do
      unset_placeholder
    else
      gettext("A secret is already configured — leave blank to keep the current value")
    end
  end

  # Builds the credentials map OAuthConfig.test_connection/2 expects, from
  # the unsaved in-memory form state (`socket.assigns.settings`) rather than
  # the database — the "Test Credentials" button must validate what the
  # admin just typed, not the last-persisted values.
  defp oauth_credentials_from_settings(:google, settings) do
    %{
      client_id: trim_credential(settings["oauth_google_client_id"]),
      client_secret: trim_credential(settings["oauth_google_client_secret"])
    }
  end

  defp oauth_credentials_from_settings(:github, settings) do
    %{
      client_id: trim_credential(settings["oauth_github_client_id"]),
      client_secret: trim_credential(settings["oauth_github_client_secret"])
    }
  end

  defp oauth_credentials_from_settings(:facebook, settings) do
    %{
      app_id: trim_credential(settings["oauth_facebook_app_id"]),
      app_secret: trim_credential(settings["oauth_facebook_app_secret"])
    }
  end

  # Same padding concern as `trim_oauth_secrets/1`, but on the "Test
  # Credentials" read path: a copy-pasted secret with surrounding
  # whitespace must be tested with the same value that would actually be
  # persisted and sent to the provider, not the padded one.
  defp trim_credential(value) when is_binary(value), do: String.trim(value)
  defp trim_credential(value), do: value || ""

  @doc """
  Collapsible per-provider OAuth setup guide: the callback-URL box with a copy
  button, the provider-specific console steps (slot), and the reverse-proxy
  notice. One component instead of four hand-copied ~95-line blocks.
  """
  attr :callback_url, :string, required: true
  attr :copy_hint, :string, required: true, doc: "e.g. \"Copy this URL to Google Cloud Console\""
  slot :steps, required: true, doc: "provider-specific <li> instruction items"

  def oauth_setup_instructions(assigns) do
    ~H"""
    <div class="collapse collapse-arrow bg-base-200 mt-4">
      <input type="checkbox" class="peer" />
      <div class="collapse-title text-sm font-medium">
        {gettext("Setup Instructions")}
      </div>
      <div class="collapse-content text-sm space-y-4">
        <%!-- Callback URL --%>
        <div class="bg-base-100 border border-base-300 rounded-lg p-4">
          <div class="flex items-start gap-3">
            <.icon
              name="hero-information-circle"
              class="stroke-current shrink-0 h-5 w-5 text-info mt-0.5"
            />
            <div class="flex-1 min-w-0">
              <div class="text-sm font-semibold text-base-content mb-2">
                {gettext("Callback URL")}
              </div>
              <div class="flex items-center gap-2">
                <code class="flex-1 px-3 py-2 bg-base-200 text-base-content border border-base-300 rounded font-mono text-xs break-all">
                  {@callback_url}
                </code>
                <button
                  type="button"
                  class="btn btn-sm btn-square btn-outline"
                  onclick={"navigator.clipboard.writeText('#{@callback_url}')"}
                  title={gettext("Copy to clipboard")}
                >
                  <.icon name="hero-clipboard" class="h-4 w-4" />
                </button>
              </div>
              <div class="text-xs text-base-content/60 mt-2">{@copy_hint}</div>
            </div>
          </div>
        </div>

        <%!-- Provider-specific steps --%>
        <div class="space-y-3">
          <ol class="list-decimal list-inside space-y-2 text-base-content/80">
            {render_slot(@steps)}
          </ol>
        </div>

        <%!-- Reverse Proxy Notice --%>
        <div class="bg-base-200 border border-base-300 rounded-lg p-3 text-xs">
          <div class="flex items-start gap-2">
            <.icon name="hero-information-circle" class="h-4 w-4 text-info shrink-0 mt-0.5" />
            <div class="text-base-content/80">
              <strong class="text-base-content">
                {gettext("Reverse Proxy Users:")}
              </strong>
              {gettext("If behind nginx/apache, ensure")}
              <code class="px-1 py-0.5 bg-base-300 text-base-content rounded text-xs">
                X-Forwarded-Proto
              </code>
              {gettext("header is set to")}
              <code class="px-1 py-0.5 bg-base-300 text-base-content rounded text-xs">
                https
              </code>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
