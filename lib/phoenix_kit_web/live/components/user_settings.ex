defmodule PhoenixKitWeb.Live.Components.UserSettings do
  @moduledoc """
  Reusable LiveComponent for user settings management.

  Provides profile, email, password, and OAuth settings in a self-contained
  component that can be embedded in any LiveView.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Live.Components.UserSettings}
        id="user-settings"
        user={@current_user}
      />

  ## Required assigns

    * `user` — the current user struct
    * `id` — unique component ID

  ## Optional assigns

    * `sections` — list of sections to display: `:identity`, `:custom_fields`, `:email`, `:password`, `:oauth`, `:notifications`, `:sessions`
      (default: all). `:profile` is accepted as a legacy alias that expands to `[:identity, :custom_fields]`
    * `email_confirm_url_fn` — `(token -> url)` for email confirmation links
      (default: `&Routes.url("/profile/settings/confirm-email/\#{&1}")`)
    * `return_to` — where OAuth redirect returns to (default:
      `Routes.user_settings_path/1`, i.e. `/profile/settings` unless the
      `user_settings_path` setting points elsewhere)
    * `current_session_token` — raw session token of the acting browser, used
      by the `:sessions` section to mark the current device and to keep it
      signed in on "sign out other sessions". Without it, no session is
      flagged current and "sign out others" revokes every session.

  ## Parent notifications

  Sends `{:phoenix_kit_user_updated, updated_user}` to the parent LiveView
  when user data changes (profile, avatar, email, password).
  """
  use PhoenixKitWeb, :live_component

  import PhoenixKitWeb.Components.Core.IntegrationsUI, only: [integration_status_badge: 1]

  require Logger

  alias PhoenixKit.Dashboard.Registry, as: TabRegistry
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Notifications.Prefs, as: NotificationPrefs
  alias PhoenixKit.Notifications.Types, as: NotificationTypes
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.AvatarCrop
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.LoginAttempts
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.TimeZone
  alias PhoenixKitWeb.Components.MediaCanvasViewer
  alias PhoenixKitWeb.Components.ProfileSettingsTabs

  # `:integrations` deliberately NOT in the default list — unlike every
  # other section it needs the independent `integrations` permission the
  # component has no way to check itself (no scope assign), so a caller must
  # opt in explicitly via `sections` once it has verified access. See
  # `PhoenixKitWeb.Live.Users.ProfileSettings` for the reference caller.
  @default_sections [
    :identity,
    :start_page,
    :custom_fields,
    :email,
    :password,
    :oauth,
    :notifications,
    :sessions,
    # Last on the page: a reset is the thing you reach for when something
    # is wrong, not part of the daily settings people scroll through.
    :etcher
  ]

  # The per-user annotation settings a reset clears. Two of them live on the
  # user row (the palette and the ink the toolbar saves); the rest —
  # background dots, connector anchors, which tools are on the bar, how much
  # of the style panel is open, the per-tool colours — are Etcher's own
  # localStorage answers, cleared in the browser (see the `EtcherReset`
  # hook). Resetting one without the other would leave someone half-fixed,
  # which is the whole reason this is a single button.
  @etcher_user_keys ~w(etcher_colors etcher_line_params)

  @doc """
  The section list rendered when a caller doesn't pass `sections` — does NOT
  include `:integrations` (see the module attribute comment above). A caller
  that wants that section appended should build on this list rather than
  hardcoding a copy, so the two can't drift.
  """
  @spec default_sections() :: [atom()]
  def default_sections, do: @default_sections

  # Picking a file no longer sets it on the spot: the crop editor opens on
  # the picked image first, so the person frames it once instead of
  # set-then-crop-then-set-again. Pressing Save without touching anything
  # accepts the default fit; Cancel discards the pick and the old avatar
  # never changed. Nothing persists until the Save in the editor.
  @impl true
  def update(%{action: :set_avatar, file_uuid: file_uuid}, socket) do
    {:ok,
     socket
     |> assign(:show_avatar_selector, false)
     |> assign(:pending_avatar_uuid, file_uuid)
     |> assign(:pending_avatar_crop, nil)
     |> assign(:show_avatar_crop, true)}
  end

  def update(%{action: :avatar_selector_closed}, socket) do
    {:ok, assign(socket, :show_avatar_selector, false)}
  end

  def update(assigns, socket) do
    user = assigns[:user] || socket.assigns[:user]
    sections = assigns[:sections] || socket.assigns[:sections] || @default_sections

    # Expand legacy :profile into fine-grained sections for backward compatibility
    sections =
      Enum.flat_map(sections, fn
        :profile -> [:identity, :custom_fields]
        other -> [other]
      end)

    email_confirm_url_fn =
      assigns[:email_confirm_url_fn] || socket.assigns[:email_confirm_url_fn] ||
        (&Routes.url("/profile/settings/confirm-email/#{&1}"))

    return_to =
      assigns[:return_to] || socket.assigns[:return_to] || Routes.user_settings_path()

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:user, user)
      |> assign(:sections, sections)
      |> assign(
        :show_google_email,
        Map.get(
          assigns,
          :show_google_email,
          ProfileSettingsTabs.google_email_shown?()
        )
      )
      |> assign(:email_confirm_url_fn, email_confirm_url_fn)
      |> assign(:return_to, return_to)
      |> assign_new(:profile_success_message, fn -> nil end)
      |> assign_new(:email_success_message, fn -> assigns[:email_success_message] end)
      |> assign_new(:email_error_message, fn -> assigns[:email_error_message] end)
      |> assign_new(:password_success_message, fn -> nil end)
      |> assign_new(:password_error_message, fn -> nil end)
      |> assign_new(:oauth_success_message, fn -> nil end)
      |> assign_new(:oauth_error_message, fn -> nil end)
      |> assign_new(:avatar_success_message, fn -> nil end)
      |> assign_new(:avatar_error_message, fn -> nil end)
      |> assign_new(:current_password, fn -> nil end)
      |> assign_new(:email_form_current_password, fn -> nil end)
      |> assign_new(:current_email, fn -> user.email end)
      |> assign_new(:email_form, fn -> to_form(Auth.change_user_email(user)) end)
      |> assign_new(:password_form, fn -> to_form(Auth.change_user_password(user)) end)
      |> assign_new(:profile_form, fn -> to_form(Auth.change_user_profile(user)) end)
      |> assign(
        :timezone_options,
        [
          {"Use System Default", nil}
          | TimeZone.options(selected: user.user_timezone)
        ]
      )
      |> assign_new(:browser_timezone_name, fn -> nil end)
      |> assign_new(:browser_timezone_offset, fn -> nil end)
      |> assign_new(:timezone_mismatch_warning, fn -> nil end)
      |> assign_new(:start_page_message, fn -> nil end)
      |> assign_new(:etcher_reset_message, fn -> nil end)
      # Plain assign, not assign_new: reads the user row handed in, so a
      # toggle elsewhere (another tab, an admin) shows after any update.
      |> assign(:viewer_open_annotating, MediaCanvasViewer.open_annotating?(user))
      |> assign(:viewer_invert_two_finger_pan, MediaCanvasViewer.invert_two_finger_pan?(user))
      |> assign_start_page()
      |> assign_new(:trigger_submit, fn -> false end)
      |> assign_new(:oauth_providers, fn -> OAuth.get_user_oauth_providers(user.uuid) end)
      |> assign_new(:oauth_available, fn -> OAuthAvailability.oauth_available?() end)
      |> assign_new(:available_providers, fn ->
        oauth_providers = OAuth.get_user_oauth_providers(user.uuid)
        get_available_oauth_providers(oauth_providers)
      end)
      |> assign_new(:custom_field_definitions, fn ->
        CustomFields.list_user_accessible_field_definitions()
      end)
      |> assign_new(:last_uploaded_avatar_uuid, fn -> nil end)
      |> assign_new(:show_avatar_selector, fn -> false end)
      |> assign_new(:show_avatar_crop, fn -> false end)
      |> assign_new(:pending_avatar_crop, fn -> nil end)
      |> assign_new(:pending_avatar_uuid, fn -> nil end)
      |> assign_new(:show_email_form, fn -> false end)
      |> assign_new(:show_password_form, fn -> false end)
      |> assign_new(:show_notification_prefs, fn -> false end)
      |> assign_new(:notification_types, fn -> NotificationTypes.list() end)
      |> assign_new(:notification_prefs, fn -> NotificationPrefs.get(user) end)
      |> assign_new(:notification_success_message, fn -> nil end)
      |> assign_new(:current_session_token, fn -> assigns[:current_session_token] end)
      |> assign_new(:session_success_message, fn -> nil end)

    socket =
      assign_new(socket, :sessions, fn ->
        load_sessions(socket.assigns.user, socket.assigns.current_session_token)
      end)

    socket =
      assign_new(socket, :recent_login_attempts, fn ->
        if :sessions in sections,
          do: LoginAttempts.recent_for_user(socket.assigns.user, limit: 5),
          else: []
      end)

    socket =
      assign_new(socket, :integration_connections, fn ->
        if :integrations in sections,
          do: load_integration_connections(socket.assigns.user.uuid),
          else: []
      end)

    {:ok, socket}
  end

  # Event handlers

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.user
      |> Auth.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket,
       email_form: email_form,
       email_form_current_password: password,
       email_success_message: nil,
       email_error_message: nil
     )}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.user

    case Auth.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          socket.assigns.email_confirm_url_fn
        )

        socket =
          socket
          |> assign(
            :email_success_message,
            gettext("A link to confirm your email change has been sent to the new address.")
          )
          |> assign(email_form_current_password: nil)

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:email_form, to_form(Map.put(changeset, :action, :insert)))
          |> assign(:email_success_message, nil)
          |> assign(:email_error_message, nil)

        {:noreply, socket}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.user
      |> Auth.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket,
       password_form: password_form,
       current_password: password,
       password_success_message: nil,
       password_error_message: nil
     )}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.user

    case Auth.update_user_password(user, password, user_params,
           except_token: socket.assigns.current_session_token
         ) do
      {:ok, user} ->
        password_form =
          user
          |> Auth.change_user_password(user_params)
          |> to_form()

        send(self(), {:phoenix_kit_user_updated, user})

        socket =
          socket
          |> assign(trigger_submit: true, password_form: password_form)
          |> assign(:password_success_message, gettext("Password changed successfully."))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(password_form: to_form(changeset))
          |> assign(:password_success_message, nil)

        {:noreply, socket}
    end
  end

  def handle_event("validate_profile", params, socket) do
    user_params =
      case params do
        %{"user" => user_params} -> user_params
        %{"profile_form" => %{"user" => user_params}} -> user_params
        _ -> %{}
      end

    merged_params = merge_custom_fields(params, user_params)

    profile_form =
      socket.assigns.user
      |> Auth.change_user_profile(merged_params)
      |> Map.put(:action, :validate)
      |> to_form()

    socket =
      socket
      |> assign(profile_form: profile_form)
      |> assign(:profile_success_message, nil)
      |> assign(:email_error_message, nil)
      |> assign(:oauth_error_message, nil)
      |> assign(:avatar_error_message, nil)
      |> check_timezone_mismatch(user_params["user_timezone"])

    {:noreply, socket}
  end

  def handle_event("update_profile", params, socket) do
    user_params =
      case params do
        %{"user" => user_params} -> user_params
        %{"profile_form" => %{"user" => user_params}} -> user_params
        _ -> %{}
      end

    user = socket.assigns.user

    merged_params = merge_custom_fields_for_save(params, user_params, user)

    case Auth.update_user_profile(user, merged_params) do
      {:ok, updated_user} ->
        send(self(), {:phoenix_kit_user_updated, updated_user})

        socket =
          socket
          |> assign(:user, updated_user)
          |> assign(:profile_success_message, gettext("Profile updated successfully"))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:profile_form, to_form(Map.put(changeset, :action, :insert)))
          |> assign(:profile_success_message, nil)

        {:noreply, socket}
    end
  end

  def handle_event("connect_oauth_provider", %{"provider" => provider}, socket) do
    return_to = socket.assigns.return_to
    oauth_url = Routes.url("/users/auth/#{provider}?return_to=#{return_to}")

    socket =
      socket
      |> assign(:oauth_info_message, "Redirecting to #{format_provider_name(provider)}...")
      |> redirect(external: oauth_url)

    {:noreply, socket}
  end

  def handle_event("disconnect_oauth_provider", %{"provider" => provider}, socket) do
    user = socket.assigns.user

    if can_disconnect_provider?(user, provider) do
      case OAuth.unlink_oauth_provider(user.uuid, provider) do
        {:ok, _} ->
          oauth_providers = OAuth.get_user_oauth_providers(user.uuid)
          available_providers = get_available_oauth_providers(oauth_providers)

          socket =
            socket
            |> assign(:oauth_providers, oauth_providers)
            |> assign(:available_providers, available_providers)
            |> assign(
              :oauth_success_message,
              gettext("%{provider} account disconnected successfully",
                provider: format_provider_name(provider)
              )
            )
            |> assign(:oauth_error_message, nil)

          {:noreply, socket}

        {:error, :not_found} ->
          socket =
            assign(socket, :oauth_error_message, gettext("Provider not found"))
            |> assign(:oauth_success_message, nil)

          {:noreply, socket}

        {:error, _reason} ->
          socket =
            assign(
              socket,
              :oauth_error_message,
              gettext("Failed to disconnect provider. Please try again.")
            )
            |> assign(:oauth_success_message, nil)

          {:noreply, socket}
      end
    else
      warning_message =
        if user.hashed_password == nil do
          gettext(
            "Cannot disconnect %{provider}. This is your only sign-in method. Please set a password or connect another provider first.",
            provider: format_provider_name(provider)
          )
        else
          gettext(
            "Cannot disconnect %{provider}. Please ensure you have at least one sign-in method available.",
            provider: format_provider_name(provider)
          )
        end

      socket =
        assign(socket, :oauth_error_message, warning_message)
        |> assign(:oauth_success_message, nil)

      {:noreply, socket}
    end
  end

  def handle_event("open_avatar_selector", _params, socket) do
    {:noreply, assign(socket, :show_avatar_selector, true)}
  end

  # ---- non-destructive avatar crop -----------------------------------------
  #
  # The crop is data in custom_fields["avatar_crop"], never a new image file:
  # the editor below adjusts four numbers, and rendering applies them as CSS.
  # See PhoenixKit.Users.AvatarCrop.

  def handle_event("open_avatar_crop", _params, socket) do
    # A stale DOM click can arrive after the avatar was removed; with no
    # file there is nothing to crop, and rendering the modal would call
    # URLSigner.signed_url(nil, ...) and take the LiveView down.
    if get_in(socket.assigns.user.custom_fields, ["avatar_file_uuid"]) do
      {:noreply,
       socket
       |> assign(:show_avatar_crop, true)
       |> assign(:pending_avatar_uuid, nil)
       |> assign(:pending_avatar_crop, AvatarCrop.from_user(socket.assigns.user))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_avatar_crop", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_avatar_crop, false)
     |> assign(:pending_avatar_crop, nil)
     |> assign(:pending_avatar_uuid, nil)}
  end

  # Pushed by the AvatarCrop hook at the end of every gesture (drag release,
  # zoom change), so "Save" always persists what the person is looking at.
  def handle_event("avatar_crop_changed", params, socket) do
    {:noreply, assign(socket, :pending_avatar_crop, AvatarCrop.normalize(params))}
  end

  def handle_event("save_avatar_crop", _params, socket) do
    crop = socket.assigns.pending_avatar_crop

    cond do
      # A freshly picked file: the file and its framing land together. An
      # untouched editor saves no crop at all — the default fit IS the
      # uncropped avatar (see AvatarCrop.drop_identity/1).
      uuid = socket.assigns.pending_avatar_uuid ->
        persist_new_avatar(socket, uuid, AvatarCrop.drop_identity(crop))

      crop ->
        # Same identity rule on the adjust path: zooming back out to the
        # default fit and saving IS a reset.
        persist_avatar_crop(
          socket,
          AvatarCrop.drop_identity(crop),
          gettext("Avatar crop updated!")
        )

      true ->
        {:noreply, assign(socket, :show_avatar_crop, false)}
    end
  end

  # Back to the uncropped avatar. Storing nil rather than deleting the key:
  # update_user_fields merges custom fields, and a merged nil reads as
  # "no crop" everywhere while needing no delete plumbing.
  def handle_event("reset_avatar_crop", _params, socket) do
    persist_avatar_crop(socket, nil, gettext("Avatar crop reset."))
  end

  def handle_event("toggle_email_form", _params, socket) do
    {:noreply, assign(socket, :show_email_form, not socket.assigns.show_email_form)}
  end

  def handle_event("toggle_password_form", _params, socket) do
    {:noreply, assign(socket, :show_password_form, not socket.assigns.show_password_form)}
  end

  # Pushed by the TimezoneDetector hook on mount and on every change of the
  # select. The browser is the only party that knows where the person actually
  # is, so this is the input the mismatch check compares against.
  def handle_event("browser_timezone_detected", %{"name" => name} = params, socket)
      when is_binary(name) do
    {:noreply,
     socket
     |> assign(:browser_timezone_name, name)
     |> assign(:browser_timezone_offset, params["offset"])
     |> check_timezone_mismatch(nil)}
  end

  def handle_event("browser_timezone_detected", _params, socket), do: {:noreply, socket}

  # Adopt the zone the browser reported. Writes the IANA identifier, never the
  # offset: the identifier is the whole point, and it is what keeps the account
  # right across the next DST change.
  def handle_event("use_browser_timezone", _params, socket) do
    case socket.assigns[:browser_timezone_name] do
      name when is_binary(name) ->
        case Auth.update_user_profile(socket.assigns.user, %{"user_timezone" => name}) do
          {:ok, updated_user} ->
            send(self(), {:phoenix_kit_user_updated, updated_user})

            {:noreply,
             socket
             |> assign(:user, updated_user)
             |> assign(:profile_form, to_form(Auth.change_user_profile(updated_user)))
             |> assign(:timezone_mismatch_warning, nil)
             |> assign(:profile_success_message, gettext("Timezone set to %{zone}.", zone: name))}

          {:error, changeset} ->
            {:noreply, assign(socket, :profile_form, to_form(changeset))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_notification_prefs", _params, socket) do
    {:noreply,
     assign(socket, :show_notification_prefs, not socket.assigns.show_notification_prefs)}
  end

  def handle_event("update_start_page", %{"start_page" => path}, socket) do
    user = socket.assigns.user
    chosen = if path == "", do: nil, else: path

    case Auth.update_user_start_page(user, chosen) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:user, updated)
         |> assign(:start_page, chosen)
         |> assign(:start_page_message, gettext("Saved."))}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :start_page_message, message)}

      _ ->
        {:noreply, assign(socket, :start_page_message, gettext("Could not save that."))}
    end
  end

  # Put the annotation tools back to how they ship. Both halves go: the
  # palette and ink saved on the user row, and Etcher's own browser-side
  # answers (see @etcher_user_keys). The push is what reaches the second
  # half — the LiveView has no way to touch localStorage itself — and it
  # rides the same socket, so the browser clears its copy in the same
  # round trip that cleared the row.
  def handle_event("reset_etcher_settings", _params, socket) do
    # Both keys, whether or not they were ever written: `jsonb - key` is a
    # no-op when the key was never there, so the common case (someone who
    # only ever touched the panel) costs a write and changes nothing. The
    # row is what `:not_found` is about — a deleted account mid-click — and
    # there is nothing left to reset there either, so it reads as done.
    updated =
      Enum.reduce(@etcher_user_keys, socket.assigns.user, fn key, current ->
        case Auth.delete_user_custom_field(current, key) do
          {:ok, fresh} -> fresh
          {:error, :not_found} -> current
        end
      end)

    {:noreply,
     socket
     |> assign(:user, updated)
     |> assign(:etcher_reset_message, gettext("Annotation settings reset."))
     |> Phoenix.LiveView.push_event("phoenix_kit:etcher-reset", %{})}
  end

  # The "open media ready to annotate" switch. One per-user flag on the
  # user row, read by MediaCanvasViewer at viewer-open (see
  # `open_annotating?/1` there — that module owns the key and the
  # default). Written through `merge_user_custom_fields`, never a
  # whole-map replace: a stale struct here must not resurrect old values
  # of every other key.
  def handle_event("toggle_viewer_open_annotating", _params, socket) do
    next = not socket.assigns.viewer_open_annotating

    case Auth.merge_user_custom_fields(
           socket.assigns.user,
           %{MediaCanvasViewer.open_annotating_key() => next},
           ensure_definitions: false
         ) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:user, updated)
         |> assign(:viewer_open_annotating, next)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # The "invert two-finger pan" switch — same shape as the one above: one
  # per-user flag, owned and read by MediaCanvasViewer at viewer-open
  # (`invert_two_finger_pan?/1`), merged rather than replaced.
  def handle_event("toggle_viewer_invert_two_finger_pan", _params, socket) do
    next = not socket.assigns.viewer_invert_two_finger_pan

    case Auth.merge_user_custom_fields(
           socket.assigns.user,
           %{MediaCanvasViewer.invert_two_finger_pan_key() => next},
           ensure_definitions: false
         ) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:user, updated)
         |> assign(:viewer_invert_two_finger_pan, next)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("update_notification_prefs", params, socket) do
    user = socket.assigns.user

    # The form renders one hidden "false" + one checkbox "true" per type key
    # under `params["notification_prefs"]`. Only the types registered right
    # now are honored; any stray keys from the form are dropped so malformed
    # submissions can't sneak data into custom_fields.
    #
    # This page renders only BASE type toggles (no sub-types), so it MUST write
    # via `merge/2` — a full-replace `update/2` here would drop every sub-type
    # preference the user set on the dedicated Notification Settings page.
    raw = params["notification_prefs"] || %{}
    valid_keys = Enum.map(socket.assigns.notification_types, & &1.key)

    prefs =
      valid_keys
      |> Enum.map(fn key -> {key, Map.get(raw, key) == "true"} end)
      |> Map.new()

    case NotificationPrefs.merge(user, prefs) do
      {:ok, updated_user} ->
        send(self(), {:phoenix_kit_user_updated, updated_user})

        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:notification_prefs, NotificationPrefs.get(updated_user))
         |> assign(:notification_success_message, gettext("Notification preferences saved."))}

      {:error, _changeset} ->
        {:noreply,
         assign(
           socket,
           :notification_success_message,
           gettext("Failed to save notification preferences.")
         )}
    end
  end

  def handle_event("revoke_session", %{"uuid" => token_uuid}, socket) do
    user = socket.assigns.user

    message =
      case Sessions.revoke_user_session(user, token_uuid) do
        :ok -> gettext("Signed out of that session.")
        {:error, :not_found} -> gettext("That session is no longer active.")
      end

    {:noreply,
     socket
     |> assign(:sessions, load_sessions(user, socket.assigns.current_session_token))
     |> assign(:session_success_message, message)}
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    user = socket.assigns.user
    Sessions.revoke_other_user_sessions(user, socket.assigns.current_session_token)

    {:noreply,
     socket
     |> assign(:sessions, load_sessions(user, socket.assigns.current_session_token))
     |> assign(:session_success_message, gettext("Signed out of all other sessions."))}
  end

  # The pages this person may actually land on: their own visible, top-level
  # admin tabs. Built per viewer rather than from a fixed list, so a tab they
  # cannot reach is never offered — and a preference is re-derived on every
  # render, so one naming a page they have since lost simply stops being
  # selected rather than stranding them.
  defp assign_start_page(socket) do
    # `:user` is this component's assign for the current user — the parent
    # passes `user={@phoenix_kit_current_user}` and nothing else. Reading the
    # parent's name here got nil, built an ANONYMOUS scope, and the picker
    # offered only the one tab that needs no permission.
    user = socket.assigns[:user]
    scope = socket.assigns[:phoenix_kit_current_scope] || Scope.for_user(user)

    options =
      scope
      |> admin_tab_options()
      |> Enum.uniq_by(&elem(&1, 1))

    socket
    |> assign(:start_page_options, options)
    |> assign(:start_page, Auth.user_start_page(user))
  end

  defp admin_tab_options(scope) do
    for tab <- TabRegistry.get_admin_tabs(scope: scope),
        is_nil(tab.parent),
        # Registered paths are MIXED — modules declare relative ones
        # ("dashboards") while core resolves some already ("/admin/settings").
        # `resolve_path/2` handles both and passes an absolute one through;
        # hand-prefixing produced "/admin/admin/notifications" and collapsed
        # the rest into one entry when they deduped.
        resolved = Tab.resolve_path(tab, :admin).path,
        # A parameterized path is a route, not a destination.
        not String.contains?(to_string(resolved), ":"),
        label = Tab.localized_label(tab),
        is_binary(label) do
      {label, resolved}
    end
  rescue
    _ -> []
  end

  # Private helpers

  # Effective on/off for one notification type: the user's saved choice where
  # they made one, the type's own default where they never touched it. Shared
  # by the checkbox state and the "N of M enabled" summary so the collapsed
  # line can never disagree with what opening the section shows.
  defp notification_enabled?(prefs, type) do
    case Map.get(prefs, type.key) do
      true -> true
      false -> false
      _ -> type.default
    end
  end

  # Never the stored `identifier`: it is attacker-controlled, and on this page
  # it would only ever be the reader's own address anyway.
  defp failed_attempt_source(attempt) do
    case Enum.reject([attempt.browser, attempt.os], &(is_nil(&1) or &1 == "")) do
      [] -> gettext("from an unrecognized device")
      parts -> gettext("from %{device}", device: Enum.join(parts, " on "))
    end
  end

  defp load_sessions(user, current_token) do
    Sessions.list_user_device_sessions(user, current_token)
  end

  # Summary only — full add/edit/remove happens on the dedicated page
  # (`Live.Integrations.MyIntegrations`/`MyIntegrationForm`, linked from the
  # section below), so this just needs enough to render a compact list.
  defp load_integration_connections(user_uuid) do
    providers = Providers.for_scope(:personal)
    providers_by_key = Map.new(providers, &{&1.key, &1})
    provider_keys = Enum.map(providers, & &1.key)

    provider_keys
    |> Integrations.load_all_connections(owner: {:user, user_uuid})
    |> Enum.flat_map(fn {provider_key, connections} ->
      Enum.map(connections, fn %{uuid: uuid, name: name, data: data} ->
        %{provider: providers_by_key[provider_key], uuid: uuid, name: name, data: data}
      end)
    end)
  end

  defp device_label(%{browser: b, os: o}) when is_binary(b) and is_binary(o), do: "#{b} · #{o}"
  defp device_label(%{browser: b}) when is_binary(b), do: b
  defp device_label(%{os: o}) when is_binary(o), do: o
  defp device_label(_), do: gettext("Unknown device")

  defp session_meta_line(session) do
    [session.location, session.ip_address, last_active_label(session)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp last_active_label(%{is_current: true}), do: gettext("Active now")
  defp last_active_label(%{last_active: nil}), do: nil

  defp last_active_label(%{last_active: last_active}) do
    time = UtilsDate.format_time_with_user_format(last_active)

    case DateTime.diff(DateTime.utc_now(), last_active, :day) do
      days when days <= 0 ->
        gettext("Active today at %{time}", time: time)

      1 ->
        gettext("Active yesterday at %{time}", time: time)

      _ ->
        gettext("Active %{date} at %{time}",
          date: UtilsDate.format_date_with_user_format(last_active),
          time: time
        )
    end
  end

  # Compare what the browser reports against what the account has saved, and
  # warn only when the two would actually render different clock times.
  #
  # Comparing identifiers alone would nag people who are legitimately not in
  # their home zone for the afternoon; comparing the *effective offset right
  # now* flags only the case that makes timestamps wrong on screen. A saved
  # legacy offset is always worth replacing, though — it cannot follow the next
  # DST change even when it happens to be right today.
  defp check_timezone_mismatch(socket, selected_timezone) do
    browser_name = socket.assigns[:browser_timezone_name]

    saved =
      selected_timezone ||
        get_in(socket.assigns.profile_form.params, ["user_timezone"]) ||
        socket.assigns.user.user_timezone

    assign(socket, :timezone_mismatch_warning, timezone_warning(browser_name, saved))
  end

  # Nothing detected yet (hook not mounted, or a browser with no Intl support).
  defp timezone_warning(nil, _saved), do: nil

  # Three distinct situations, and they need different sentences. Collapsing
  # them once produced "this account stores a fixed UTC offset" for someone
  # whose account stored nothing at all — that was the SITE default being
  # described as the person's own setting.
  defp timezone_warning(browser_name, saved) do
    cond do
      not TimeZone.identifier?(browser_name) ->
        nil

      # No preference of their own: times follow the site default, which may
      # well be right. Offered, not scolded.
      saved in [nil, ""] ->
        unless TimeZone.effectively_same?(browser_name, Settings.get_setting("time_zone", "0")) do
          gettext(
            "Your browser reports %{zone}. You have not set a timezone, so times are shown using the site default.",
            zone: browser_name
          )
        end

      TimeZone.legacy_offset?(saved) ->
        gettext(
          "Your browser reports %{zone}. This account still stores a fixed UTC offset, which cannot follow daylight saving — it will drift by an hour at the next change.",
          zone: browser_name
        )

      TimeZone.same_group?(browser_name, saved) ->
        nil

      true ->
        gettext(
          "Your browser reports %{browser}, but this account is set to %{saved}. Times on this site will be shown in %{saved}.",
          browser: browser_name,
          saved: saved
        )
    end
  end

  defp get_available_oauth_providers(oauth_providers) do
    connected = Enum.map(oauth_providers, & &1.provider)
    all_providers = ["google", "github"]

    all_providers
    |> Enum.reject(&(&1 in connected))
    |> Enum.filter(&provider_enabled?/1)
  end

  defp provider_enabled?("google"), do: OAuthAvailability.provider_enabled?(:google)
  defp provider_enabled?("github"), do: OAuthAvailability.provider_enabled?(:github)
  defp provider_enabled?(_), do: false

  defp can_disconnect_provider?(user, _provider) do
    has_password = user.hashed_password != nil
    oauth_count = length(OAuth.get_user_oauth_providers(user.uuid))
    has_password or oauth_count > 1
  end

  defp extract_custom_fields(params) do
    get_in(params, ["profile_form", "user", "custom_fields"])
  end

  defp merge_custom_fields(params, user_params) do
    case extract_custom_fields(params) do
      custom_fields when is_map(custom_fields) ->
        Map.put(user_params, "custom_fields", custom_fields)

      _ ->
        user_params
    end
  end

  # Merges form custom fields on top of all existing user custom fields for persistence.
  # Ensures fields not present in the form (e.g. avatar_file_uuid, programmatic fields)
  # are preserved when saving.
  defp merge_custom_fields_for_save(params, user_params, user) do
    existing = user.custom_fields || %{}

    case extract_custom_fields(params) do
      form_fields when is_map(form_fields) ->
        Map.put(user_params, "custom_fields", Map.merge(existing, form_fields))

      _ when map_size(existing) > 0 ->
        Map.put(user_params, "custom_fields", existing)

      _ ->
        user_params
    end
  end

  defp persist_new_avatar(socket, file_uuid, crop) do
    user = socket.assigns.user

    case Auth.update_user_fields(user, %{"avatar_file_uuid" => file_uuid, "avatar_crop" => crop}) do
      {:ok, updated_user} ->
        send(self(), {:phoenix_kit_user_updated, updated_user})

        PhoenixKit.Activity.log(%{
          action: "user.avatar_changed",
          module: "users",
          mode: "manual",
          actor_uuid: updated_user.uuid,
          resource_type: "user",
          resource_uuid: updated_user.uuid,
          metadata: %{
            "avatar_from" => get_in(user.custom_fields, ["avatar_file_uuid"]) || "",
            "avatar_to" => file_uuid,
            "cropped" => crop != nil,
            "actor_role" => "user"
          }
        })

        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:show_avatar_crop, false)
         |> assign(:pending_avatar_crop, nil)
         |> assign(:pending_avatar_uuid, nil)
         |> assign(:last_uploaded_avatar_uuid, file_uuid)
         |> assign(:avatar_success_message, gettext("Avatar updated successfully!"))
         |> assign(:avatar_error_message, nil)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:show_avatar_crop, false)
         |> assign(:pending_avatar_uuid, nil)
         |> assign(:avatar_error_message, gettext("Failed to update avatar"))
         |> assign(:avatar_success_message, nil)}
    end
  end

  defp persist_avatar_crop(socket, crop, success_message) do
    user = socket.assigns.user

    case Auth.update_user_fields(user, %{"avatar_crop" => crop}) do
      {:ok, updated_user} ->
        send(self(), {:phoenix_kit_user_updated, updated_user})

        PhoenixKit.Activity.log(%{
          action: "user.avatar_crop_changed",
          module: "users",
          mode: "manual",
          actor_uuid: updated_user.uuid,
          resource_type: "user",
          resource_uuid: updated_user.uuid,
          metadata: %{
            "cropped" => crop != nil,
            "actor_role" => "user"
          }
        })

        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:show_avatar_crop, false)
         |> assign(:pending_avatar_crop, nil)
         |> assign(:pending_avatar_uuid, nil)
         |> assign(:avatar_success_message, success_message)
         |> assign(:avatar_error_message, nil)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:show_avatar_crop, false)
         |> assign(:avatar_error_message, gettext("Failed to update avatar crop"))
         |> assign(:avatar_success_message, nil)}
    end
  end

  defp format_provider_name("google"), do: "Google"
  defp format_provider_name("apple"), do: "Apple"
  defp format_provider_name("github"), do: "GitHub"
  defp format_provider_name(provider), do: String.capitalize(provider)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm max-w-4xl mx-auto">
      <div class="card-body">
        <%!-- Identity Section (avatar, name, username, timezone) --%>
        <%= if :identity in @sections do %>
          <div>
            <%!-- Success Message --%>
            <%= if @profile_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@profile_success_message}</span>
              </div>
            <% end %>

            <%!-- Avatar Upload Messages --%>
            <%= if @last_uploaded_avatar_uuid do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>Avatar uploaded successfully!</span>
              </div>
            <% end %>
            <%= if @avatar_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@avatar_error_message}</span>
              </div>
            <% end %>

            <%!-- Identity Form with Avatar --%>
            <.simple_form
              for={@profile_form}
              id={"#{@id}-profile-form"}
              phx-submit="update_profile"
              phx-change="validate_profile"
              phx-target={@myself}
            >
              <div class="flex flex-col gap-6 lg:flex-row lg:gap-4 lg:items-start">
                <%!-- Avatar Section --%>
                <div class="flex flex-col items-center gap-2 mx-auto lg:mx-0">
                  <%!-- The shared component: same cascade as everywhere else,
                       and the "xl" size loads the medium (800px) variant — the
                       old inline <img> here loaded the 150px thumbnail into
                       this 160px circle, which is what made it blurry. --%>
                  <.user_avatar user={@user} size="xl" class="border-2 border-primary" />
                  <button
                    type="button"
                    phx-click="open_avatar_selector"
                    phx-target={@myself}
                    class="btn btn-primary w-40"
                  >
                    <.icon name="hero-photo" class="w-5 h-5" /> Browse Media
                  </button>
                  <button
                    :if={get_in(@user.custom_fields, ["avatar_file_uuid"])}
                    type="button"
                    id={"#{@id}-avatar-crop-open"}
                    phx-click="open_avatar_crop"
                    phx-target={@myself}
                    class="btn btn-ghost btn-sm w-40"
                  >
                    <.icon name="hero-viewfinder-circle" class="w-4 h-4" /> {gettext("Adjust Crop")}
                  </button>
                </div>

                <%!-- Name Fields --%>
                <div class="flex-1 grid grid-cols-1 lg:grid-cols-2 gap-3 w-full">
                  <.input
                    field={@profile_form[:first_name]}
                    type="text"
                    label="First Name"
                  />
                  <.input
                    field={@profile_form[:last_name]}
                    type="text"
                    label="Last Name"
                  />
                  <div class="col-span-1 lg:col-span-2">
                    <.input
                      field={@profile_form[:username]}
                      type="text"
                      label="Username"
                    />
                  </div>
                </div>
              </div>

              <%!-- Timezone Section.                                          --%>
              <%!--                                                             --%>
              <%!-- phx-hook is load-bearing and was silently lost once before   --%>
              <%!-- (c2a52872, swapping <.input type="select"> for <.select>),   --%>
              <%!-- which left the id, the server-side mismatch check and this   --%>
              <%!-- whole block intact but never fed. If the "Browser detected"  --%>
              <%!-- line stops appearing, look here first.                       --%>
              <div
                id={"#{@id}-timezone-detector"}
                phx-hook="TimezoneDetector"
                phx-target={@myself}
                data-event="browser_timezone_detected"
              >
                <.select
                  field={@profile_form[:user_timezone]}
                  label="Personal Timezone"
                  options={@timezone_options}
                />

                <%= if assigns[:timezone_mismatch_warning] do %>
                  <div class="alert alert-warning text-sm mt-2">
                    <.icon
                      name="hero-exclamation-triangle"
                      class="stroke-current shrink-0 h-4 w-4"
                    />
                    <div class="flex-1">
                      <div class="font-semibold">{gettext("Check your timezone")}</div>
                      <div class="text-xs">
                        {@timezone_mismatch_warning}
                      </div>
                    </div>
                    <%!-- The button the original never had: its handler existed --%>
                    <%!-- from the first commit but nothing ever rendered a       --%>
                    <%!-- phx-click for it.                                       --%>
                    <button
                      type="button"
                      phx-click="use_browser_timezone"
                      phx-target={@myself}
                      class="btn btn-sm btn-warning"
                    >
                      {gettext("Use %{zone}", zone: @browser_timezone_name)}
                    </button>
                  </div>
                <% end %>

                <%= if assigns[:browser_timezone_name] do %>
                  <div class="text-xs text-base-content/60 mt-1">
                    {gettext("Browser detected: %{zone}", zone: @browser_timezone_name)}
                  </div>
                <% end %>
              </div>

              <%!-- Google address. Separate from the sign-in email on purpose: --%>
              <%!-- it is where we SHARE (a Drive file, a calendar invite), not --%>
              <%!-- an identity, so it is optional and nothing authenticates    --%>
              <%!-- against it. Left empty, a Gmail sign-in address is used.    --%>
              <div :if={@show_google_email}>
                <.input
                  field={@profile_form[:google_email]}
                  type="email"
                  label={gettext("Google Email")}
                />
                <div class="text-xs text-base-content/60 mt-1">
                  {gettext(
                    "Used when something is shared with you through Google. Leave empty to use your account email."
                  )}
                </div>
              </div>

              <:actions>
                <div class="ml-auto">
                  <.button phx-disable-with="Updating..." class="btn-primary">
                    Update Profile
                  </.button>
                </div>
              </:actions>
            </.simple_form>

            <.live_component
              module={PhoenixKitWeb.Live.Components.UserMediaSelectorModal}
              id={"#{@id}-avatar-media-selector"}
              show={@show_avatar_selector}
              mode={:single}
              selected_uuids={[]}
              phoenix_kit_current_user={@user}
              on_select={{PhoenixKitWeb.Live.Components.UserSettings, @id, :set_avatar}}
            />

            <%!-- Non-destructive crop editor. Drag to position, slider or
                 wheel to zoom — the AvatarCrop hook previews with the same
                 math the avatar component renders with, and the original
                 image is never touched. --%>
            <.modal
              :if={@show_avatar_crop}
              show={@show_avatar_crop}
              on_close="close_avatar_crop"
              id={"#{@id}-avatar-crop-modal"}
              max_width="md"
            >
              <:title>{gettext("Adjust Avatar Crop")}</:title>
              <div
                id={"#{@id}-avatar-crop-editor"}
                phx-hook="AvatarCrop"
                phx-target={@myself}
                phx-update="ignore"
                data-crop={Phoenix.json_library().encode!(@pending_avatar_crop || %{})}
                data-max-zoom={AvatarCrop.max_zoom()}
                class="flex flex-col items-center gap-4 py-2"
              >
                <div
                  data-crop-frame
                  class="relative w-64 h-64 rounded-full overflow-hidden bg-neutral cursor-grab touch-none select-none ring-2 ring-primary ring-offset-2"
                >
                  <img
                    data-crop-img
                    src={
                      URLSigner.signed_url(
                        @pending_avatar_uuid || get_in(@user.custom_fields, ["avatar_file_uuid"]),
                        "large"
                      )
                    }
                    alt=""
                    draggable="false"
                    class="absolute max-w-none pointer-events-none"
                  />
                </div>
                <div class="flex items-center gap-3 w-64">
                  <.icon name="hero-magnifying-glass-minus" class="w-4 h-4 opacity-60" />
                  <input
                    data-crop-zoom
                    type="range"
                    min="1"
                    max={AvatarCrop.max_zoom()}
                    step="0.01"
                    value="1"
                    class="range range-primary range-xs flex-1"
                    aria-label={gettext("Zoom")}
                  />
                  <.icon name="hero-magnifying-glass-plus" class="w-4 h-4 opacity-60" />
                </div>
              </div>
              <:actions>
                <%!-- Nothing to reset on a fresh pick — the default fit
                     already is the uncropped image. --%>
                <button
                  :if={is_nil(@pending_avatar_uuid)}
                  type="button"
                  id={"#{@id}-avatar-crop-reset"}
                  phx-click="reset_avatar_crop"
                  phx-target={@myself}
                  class="btn btn-ghost btn-sm mr-auto"
                >
                  {gettext("Reset")}
                </button>
                <button
                  type="button"
                  id={"#{@id}-avatar-crop-cancel"}
                  phx-click="close_avatar_crop"
                  phx-target={@myself}
                  class="btn btn-sm"
                >
                  {gettext("Cancel")}
                </button>
                <%!-- data-crop-save-btn: the AvatarCrop hook flushes its
                     pending state on this click (capture phase, so the
                     flush is pushed before the phx-click), closing the
                     window where a debounced wheel-zoom would be lost. --%>
                <button
                  type="button"
                  id={"#{@id}-avatar-crop-save"}
                  data-crop-save-btn
                  phx-click="save_avatar_crop"
                  phx-target={@myself}
                  class="btn btn-primary btn-sm"
                >
                  {gettext("Save Crop")}
                </button>
              </:actions>
            </.modal>

            <%= if Enum.any?([:custom_fields, :email, :password, :oauth], & &1 in @sections) do %>
              <div class="divider"></div>
            <% end %>
          </div>
        <% end %>

        <%!-- Custom Fields Section --%>
        <%= if :custom_fields in @sections and length(@custom_field_definitions) > 0 do %>
          <div>
            <.simple_form
              for={@profile_form}
              id={"#{@id}-custom-fields-form"}
              phx-submit="update_profile"
              phx-change="validate_profile"
              phx-target={@myself}
            >
              <%= if :identity in @sections do %>
                <div class="divider text-sm text-base-content/60">Additional Information</div>
              <% else %>
                <h2 class="text-lg font-semibold mb-2">Additional Information</h2>
              <% end %>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
                <%= for field <- @custom_field_definitions do %>
                  <% field_name = "profile_form[user][custom_fields][#{field["key"]}]" %>
                  <% field_value =
                    get_in(@user.custom_fields, [field["key"]]) || field["default"] || "" %>
                  <div class="col-span-1 lg:col-span-2">
                    <%!-- Same guard the admin edit form carries: a map or a
                         list under a definition cannot be edited by any field
                         type, and handing one to an input raises
                         `Phoenix.HTML.Safe` on a map and flattens a list into
                         one run. Read-only and with no `name`, so nothing is
                         submitted for the key and the save path's merge keeps
                         the stored value (issue #780). --%>
                    <%= if CustomFields.structured_value?(field_value) do %>
                      <.input
                        name={nil}
                        type="text"
                        label={field["label"]}
                        value={CustomFields.printable(field_value)}
                        class="font-mono text-sm"
                        readonly
                      />
                      <div class="label">
                        <span class="fieldset-label text-xs text-base-content/60">
                          Structured value, stored by a feature rather than typed here — read-only.
                        </span>
                      </div>
                    <% else %>
                      <%= case field["type"] do %>
                        <% "select" -> %>
                          <.select
                            name={field_name}
                            label={field["label"]}
                            options={
                              Enum.map(field["options"] || [], fn opt ->
                                if is_binary(opt),
                                  do: {opt, opt},
                                  else: {opt["label"], opt["value"]}
                              end)
                            }
                            value={field_value}
                            required={field["required"]}
                          />
                        <% "textarea" -> %>
                          <.textarea
                            name={field_name}
                            label={field["label"]}
                            value={field_value}
                            required={field["required"]}
                          />
                        <% "number" -> %>
                          <.input
                            name={field_name}
                            type="number"
                            label={field["label"]}
                            value={field_value}
                            required={field["required"]}
                          />
                        <% "email" -> %>
                          <.input
                            name={field_name}
                            type="email"
                            label={field["label"]}
                            value={field_value}
                            required={field["required"]}
                          />
                        <% "url" -> %>
                          <.input
                            name={field_name}
                            type="url"
                            label={field["label"]}
                            value={field_value}
                            required={field["required"]}
                          />
                        <% "date" -> %>
                          <.input
                            name={field_name}
                            type="date"
                            label={field["label"]}
                            value={field_value}
                            required={field["required"]}
                          />
                        <% "boolean" -> %>
                          <.checkbox
                            name={field_name}
                            checked={field_value == true || field_value == "true"}
                            label={field["label"]}
                          />
                        <% _ -> %>
                          <.input
                            name={field_name}
                            type="text"
                            label={field["label"]}
                            value={field_value}
                            required={field["required"]}
                          />
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <:actions>
                <div class="ml-auto">
                  <.button phx-disable-with="Updating..." class="btn-primary">
                    Update Custom Fields
                  </.button>
                </div>
              </:actions>
            </.simple_form>
            <%= if Enum.any?([:email, :password, :oauth], & &1 in @sections) do %>
              <div class="divider"></div>
            <% end %>
          </div>
        <% end %>

        <%!-- Email Section --%>
        <%= if :email in @sections do %>
          <div>
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-envelope" class="w-5 h-5 text-primary" /> Email Address
              </h2>
              <button
                type="button"
                phx-click="toggle_email_form"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                <.icon
                  name={if @show_email_form, do: "hero-x-mark", else: "hero-pencil"}
                  class="w-4 h-4"
                />
                {if @show_email_form, do: "Cancel", else: "Change Email"}
              </button>
            </div>

            <div class="text-sm text-base-content/60 mb-4">{@current_email}</div>

            <%= if @email_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@email_success_message}</span>
              </div>
            <% end %>
            <%= if @email_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@email_error_message}</span>
              </div>
            <% end %>

            <%= if @show_email_form do %>
              <.simple_form
                for={@email_form}
                id={"#{@id}-email-form"}
                phx-submit="update_email"
                phx-change="validate_email"
                phx-target={@myself}
              >
                <.input
                  field={@email_form[:email]}
                  type="email"
                  label="New Email"
                  required
                />
                <.input
                  field={@email_form[:current_password]}
                  name="current_password"
                  id={"#{@id}-current-password-for-email"}
                  type="password"
                  label="Current Password"
                  value={@email_form_current_password}
                  required
                />
                <:actions>
                  <div class="ml-auto">
                    <.button phx-disable-with="Changing..." class="btn-primary">
                      Update Email
                    </.button>
                  </div>
                </:actions>
              </.simple_form>
            <% end %>
          </div>
        <% end %>

        <%= if :email in @sections and Enum.any?([:password, :oauth], & &1 in @sections) do %>
          <div class="divider"></div>
        <% end %>

        <%!-- Password Section --%>
        <%= if :password in @sections do %>
          <div>
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-lock-closed" class="w-5 h-5 text-primary" /> Password
              </h2>
              <button
                type="button"
                phx-click="toggle_password_form"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                <.icon
                  name={if @show_password_form, do: "hero-x-mark", else: "hero-pencil"}
                  class="w-4 h-4"
                />
                {if @show_password_form, do: "Cancel", else: "Change Password"}
              </button>
            </div>

            <div class="text-sm text-base-content/60 mb-4">••••••••</div>

            <%= if @password_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@password_success_message}</span>
              </div>
            <% end %>
            <%= if @password_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@password_error_message}</span>
              </div>
            <% end %>

            <%= if @show_password_form do %>
              <.simple_form
                for={@password_form}
                id={"#{@id}-password-form"}
                action={Routes.path("/users/log-in?_action=password_updated")}
                method="post"
                phx-change="validate_password"
                phx-submit="update_password"
                phx-trigger-action={@trigger_submit}
                phx-target={@myself}
              >
                <input
                  name={@password_form[:email].name}
                  type="hidden"
                  id={"#{@id}-hidden-user-email"}
                  value={@current_email}
                />
                <.input
                  field={@password_form[:password]}
                  type="password"
                  label="New Password"
                  required
                />
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  label="Confirm New Password"
                />
                <.input
                  field={@password_form[:current_password]}
                  name="current_password"
                  type="password"
                  label="Current Password"
                  id={"#{@id}-current-password-for-password"}
                  value={@current_password}
                  required
                />
                <:actions>
                  <div class="ml-auto">
                    <.button phx-disable-with="Changing..." class="btn-primary">
                      Update Password
                    </.button>
                  </div>
                </:actions>
              </.simple_form>
            <% end %>
          </div>
        <% end %>

        <%!-- OAuth Section --%>
        <%= if :oauth in @sections and @oauth_available do %>
          <div class="divider"></div>
          <div>
            <h2 class="text-lg font-semibold flex items-center gap-2 mb-4">
              <.icon name="hero-link" class="w-5 h-5 text-primary" /> Connected Accounts
            </h2>

            <%= if @oauth_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@oauth_success_message}</span>
              </div>
            <% end %>
            <%= if @oauth_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@oauth_error_message}</span>
              </div>
            <% end %>

            <%!-- Connected Providers --%>
            <%= if length(@oauth_providers) > 0 do %>
              <div class="space-y-2 mb-4">
                <%= for provider <- @oauth_providers do %>
                  <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                    <div class="flex items-center gap-3">
                      <%= case provider.provider do %>
                        <% "google" -> %>
                          <.icon name="hero-globe-alt" class="w-5 h-5" />
                        <% "apple" -> %>
                          <.icon name="hero-device-phone-mobile" class="w-5 h-5" />
                        <% "github" -> %>
                          <.icon name="hero-code-bracket" class="w-5 h-5" />
                        <% _ -> %>
                          <.icon name="hero-link" class="w-5 h-5" />
                      <% end %>
                      <div>
                        <span class="font-medium">{format_provider_name(provider.provider)}</span>
                        <div class="text-xs text-base-content/60">
                          {provider.provider_email || @current_email}
                        </div>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="disconnect_oauth_provider"
                      phx-target={@myself}
                      phx-value-provider={provider.provider}
                      class="btn btn-sm btn-outline btn-error"
                      data-confirm="Are you sure you want to disconnect this account? You won't be able to sign in with it anymore."
                    >
                      Disconnect
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Available Providers --%>
            <%= if length(@available_providers) > 0 do %>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <%= for provider <- @available_providers do %>
                  <button
                    type="button"
                    phx-click="connect_oauth_provider"
                    phx-target={@myself}
                    phx-value-provider={provider}
                    class="btn btn-outline"
                  >
                    <.icon name="hero-plus" class="w-4 h-4 mr-1" />
                    Connect {format_provider_name(provider)}
                  </button>
                <% end %>
              </div>
            <% end %>

            <%!-- Password Warning for OAuth-only Users --%>
            <%= if length(@oauth_providers) > 0 and @user.hashed_password == nil do %>
              <div class="alert alert-warning text-sm mt-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <div>
                  <div class="font-semibold">No Password Set</div>
                  <div class="text-xs">
                    You signed up using OAuth. Consider setting a password above as a backup sign-in method.
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Notifications Section --%>
        <%!-- Start page. Somebody who lives in one module should not have to
        navigate out of the admin home every morning; core has no per-user
        preference store, so this rides in `custom_fields` under a reserved
        key, exactly as `preferred_locale` does. --%>
        <%= if :start_page in @sections and @start_page_options != [] do %>
          <div class="divider"></div>
          <div>
            <h2 class="text-lg font-semibold flex items-center gap-2 mb-3">
              <.icon name="hero-home" class="w-5 h-5 text-primary" /> {gettext("Start page")}
            </h2>
            <p class="text-sm text-base-content/60 mb-3">
              {gettext("Where to go after you sign in.")}
            </p>
            <form
              phx-submit="update_start_page"
              phx-target={@myself}
              class="flex flex-wrap items-end gap-2"
            >
              <label class="form-control min-w-64">
                <select name="start_page" class="select select-bordered select-sm">
                  <option value="">{gettext("The admin home")}</option>
                  <option
                    :for={{label, path} <- @start_page_options}
                    value={path}
                    selected={@start_page == path}
                  >
                    {label}
                  </option>
                </select>
              </label>
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
              <span :if={@start_page_message} class="text-sm text-success">
                {@start_page_message}
              </span>
            </form>
          </div>
        <% end %>

        <%= if :notifications in @sections and @notification_types != [] do %>
          <%= if Enum.any?([:identity, :custom_fields, :email, :password, :oauth], & &1 in @sections) do %>
            <div class="divider"></div>
          <% end %>
          <div>
            <%!-- Collapsed behind a toggle like Email and Password above: a --%>
            <%!-- row of checkboxes per registered type is the longest block --%>
            <%!-- on the page, and it pushed Active Sessions off-screen for  --%>
            <%!-- everyone, including the majority who never change a        --%>
            <%!-- preference. The summary line carries the state that used   --%>
            <%!-- to need scrolling to read.                                 --%>
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-bell" class="w-5 h-5 text-primary" /> {gettext("Notifications")}
              </h2>
              <button
                type="button"
                phx-click="toggle_notification_prefs"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                <.icon
                  name={if @show_notification_prefs, do: "hero-x-mark", else: "hero-pencil"}
                  class="w-4 h-4"
                />
                {if @show_notification_prefs,
                  do: gettext("Cancel"),
                  else: gettext("Manage Notifications")}
              </button>
            </div>

            <%!-- Mirrors the current-email line under the Email heading: the --%>
            <%!-- one fact worth seeing without opening the section.          --%>
            <div class="text-sm text-base-content/60 mb-4">
              {gettext("%{enabled} of %{total} notification types enabled",
                enabled:
                  Enum.count(@notification_types, &notification_enabled?(@notification_prefs, &1)),
                total: length(@notification_types)
              )}
            </div>

            <%!-- Outside the toggle, so the confirmation is still visible if --%>
            <%!-- the section is collapsed after a save.                      --%>
            <%= if @notification_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@notification_success_message}</span>
              </div>
            <% end %>

            <%= if @show_notification_prefs do %>
              <p class="text-sm text-base-content/60 mb-4">
                {gettext(
                  "Pick which notification types you want to receive. Unchecked types are muted — activities still record in the audit log but no bell notification is created for you."
                )}
              </p>

              <form
                phx-submit="update_notification_prefs"
                phx-target={@myself}
                class="space-y-3"
              >
                <%= for type <- @notification_types do %>
                  <%!-- Use <.checkbox>, not a hand-rolled label+input: it owns the
                       hidden-false fallback and centers the box against the first
                       text line. The nudge this used to carry (`mt-1` on a
                       checkbox-sm) sat the box below the label's centerline. --%>
                  <.checkbox
                    name={"notification_prefs[#{type.key}]"}
                    checked={notification_enabled?(@notification_prefs, type)}
                    label={type.label}
                    class="checkbox-sm"
                    wrapper_class="p-3 rounded-lg border border-base-300 hover:bg-base-200/40 transition-colors"
                  >
                    <:description :if={type.description not in [nil, ""]}>
                      {type.description}
                    </:description>
                  </.checkbox>
                <% end %>

                <div class="flex justify-end pt-2">
                  <button type="submit" class="btn btn-primary btn-sm">
                    {gettext("Save preferences")}
                  </button>
                </div>
              </form>
            <% end %>
          </div>
        <% end %>

        <%!-- Active Sessions Section --%>
        <%= if :sessions in @sections do %>
          <%= if Enum.any?([:identity, :custom_fields, :email, :password, :oauth, :notifications], & &1 in @sections) do %>
            <div class="divider"></div>
          <% end %>
          <div>
            <h2 class="text-lg font-semibold flex items-center gap-2 mb-4">
              <.icon name="hero-computer-desktop" class="w-5 h-5 text-primary" />
              {gettext("Active Sessions")}
            </h2>

            <%= if @session_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@session_success_message}</span>
              </div>
            <% end %>

            <p class="text-sm text-base-content/60 mb-4">
              {gettext(
                "Devices currently signed in to your account. If you don't recognize one, sign it out."
              )}
            </p>

            <div class="space-y-2">
              <%= for session <- @sessions do %>
                <div class="flex items-center justify-between gap-3 p-3 rounded-lg border border-base-300">
                  <div class="flex items-start gap-3 min-w-0">
                    <.icon
                      name="hero-computer-desktop"
                      class="w-5 h-5 mt-0.5 shrink-0 text-base-content/50"
                    />
                    <div class="min-w-0">
                      <div class="font-medium text-sm">
                        {device_label(session)}
                        <span :if={session.is_current} class="badge badge-primary badge-sm ml-1">
                          {gettext("This device")}
                        </span>
                        <span :if={session.active_role} class="badge badge-ghost badge-sm ml-1">
                          {gettext("Acting as %{role}", role: session.active_role)}
                        </span>
                      </div>
                      <div class="text-xs text-base-content/60 truncate">
                        {session_meta_line(session)}
                      </div>
                    </div>
                  </div>
                  <button
                    :if={not session.is_current}
                    type="button"
                    phx-click="revoke_session"
                    phx-value-uuid={session.token_uuid}
                    phx-target={@myself}
                    class="btn btn-ghost btn-xs text-error shrink-0"
                  >
                    {gettext("Sign out")}
                  </button>
                </div>
              <% end %>
            </div>

            <div :if={Enum.count(@sessions, &(not &1.is_current)) > 0} class="flex justify-end pt-3">
              <button
                type="button"
                phx-click="revoke_other_sessions"
                phx-target={@myself}
                data-confirm={gettext("Sign out of all other sessions?")}
                class="btn btn-outline btn-error btn-sm"
              >
                {gettext("Sign out other sessions")}
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Failed sign-ins. Sits under Active Sessions because the two
             answer the same question from opposite sides: who got in, and who
             tried and did not. Only rendered when there is something to show
             — an empty "no failed attempts" panel is noise on every visit. --%>
        <%= if :sessions in @sections and @recent_login_attempts != [] do %>
          <div class="divider"></div>
          <div>
            <h2 class="text-lg font-semibold flex items-center gap-2 mb-1">
              <.icon name="hero-shield-exclamation" class="w-5 h-5 text-warning" />
              {gettext("Failed sign-in attempts")}
            </h2>
            <p class="text-sm text-base-content/60 mb-4">
              {gettext("Sign-ins to your account that did not succeed. Nobody got in.")}
            </p>

            <div class="space-y-2">
              <div
                :for={attempt <- @recent_login_attempts}
                class="flex items-center justify-between gap-3 rounded-lg border border-base-300 px-3 py-2"
              >
                <div class="min-w-0">
                  <div class="font-medium text-sm">
                    {ngettext("%{count} attempt", "%{count} attempts", attempt.attempt_count,
                      count: attempt.attempt_count
                    )}
                    <span class="text-base-content/60 font-normal">
                      {failed_attempt_source(attempt)}
                    </span>
                  </div>
                  <div :if={attempt.outcome == "inactive"} class="text-xs text-warning">
                    {gettext("Correct password, account was deactivated.")}
                  </div>
                  <div class="text-xs text-base-content/60 truncate">
                    {attempt.ip_address}
                  </div>
                </div>
                <div class="text-xs text-base-content/60 whitespace-nowrap">
                  {UtilsDate.format_date_with_user_timezone(attempt.last_at, @user)}
                  {UtilsDate.format_time_with_user_timezone(attempt.last_at, @user)}
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Integrations Section — summary + link out to the dedicated
             list/add/edit pages. Only in @sections when the caller has
             already checked the "integrations" permission (see moduledoc). --%>
        <%= if :integrations in @sections do %>
          <%= if Enum.any?(
                   [:identity, :custom_fields, :email, :password, :oauth, :notifications, :sessions],
                   &(&1 in @sections)
                 ) do %>
            <div class="divider"></div>
          <% end %>
          <div>
            <div class="flex items-center justify-between gap-3 mb-1">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-link" class="w-5 h-5 text-primary" /> {gettext("Integrations")}
              </h2>
              <.pk_link navigate="/profile/settings/integrations" class="btn btn-sm btn-outline">
                {gettext("Manage Integrations")}
              </.pk_link>
            </div>
            <p class="text-sm text-base-content/60 mb-4">
              {gettext("Your own API keys and bot connections — only you can see or use these.")}
            </p>

            <div :if={@integration_connections == []} class="text-sm text-base-content/50">
              {gettext("No personal integrations yet.")}
            </div>

            <div :if={@integration_connections != []} class="space-y-2">
              <div
                :for={conn <- @integration_connections}
                class="flex items-center justify-between gap-3 p-3 rounded-lg border border-base-300"
              >
                <div class="flex items-center gap-3 min-w-0">
                  <.icon name={conn.provider.icon} class="w-5 h-5 shrink-0 text-base-content/60" />
                  <div class="min-w-0">
                    <div class="font-medium text-sm truncate">{conn.provider.name}</div>
                    <div class="text-xs text-base-content/60 truncate">{conn.name}</div>
                  </div>
                </div>
                <% {badge_class, badge_text} = integration_status_badge(conn.data["status"]) %>
                <span class={"badge badge-sm #{badge_class} shrink-0"}>{badge_text}</span>
              </div>
            </div>
          </div>
        <% end %>

        <%= if :etcher in @sections do %>
          <%= if Enum.any?(
                   [:identity, :custom_fields, :email, :password, :oauth, :notifications,
                    :sessions, :integrations],
                   &(&1 in @sections)
                 ) do %>
            <div class="divider"></div>
          <% end %>
          <%!-- The hook is what clears the browser's half (Etcher keeps its --%>
          <%!-- board answers in localStorage); the server clears the user   --%>
          <%!-- row's half. One button, both halves, or a reset leaves        --%>
          <%!-- someone half-fixed.                                          --%>
          <div id="etcher-reset" phx-hook="EtcherReset">
            <h2 class="text-lg font-semibold flex items-center gap-2 mb-3">
              <.icon name="hero-pencil-square" class="w-5 h-5 text-primary" />
              {gettext("Annotation tools")}
            </h2>
            <%!-- Which face of the media viewer greets this user: the     --%>
            <%!-- finished picture (shipped default), or the editor with   --%>
            <%!-- the tools already up. Per-user on purpose — one person   --%>
            <%!-- opens files to look, another to work — and read by       --%>
            <%!-- MediaCanvasViewer at every viewer-open.                  --%>
            <%!-- <.checkbox>, not a hand-rolled daisyUI label: `.label`   --%>
            <%!-- does not wrap its text, so the description ran clean off --%>
            <%!-- the card. The component's description slot wraps.        --%>
            <div class="mb-4">
              <.checkbox
                variant="toggle"
                name="viewer_open_annotating"
                checked={@viewer_open_annotating}
                label={gettext("Open media ready to annotate")}
                phx-click="toggle_viewer_open_annotating"
                phx-target={@myself}
              >
                <:description>
                  {gettext(
                    "The viewer opens with the drawing tools already on, so you can edit and move things right away — switch the pencil off to see the finished picture. Off, the viewer opens on the finished picture and the pencil starts the tools."
                  )}
                </:description>
              </.checkbox>
            </div>
            <%!-- Per-user because it is per-machine in truth: the browser  --%>
            <%!-- hands over the fingers after the OS's scroll direction    --%>
            <%!-- has been applied and does not say which, so no default    --%>
            <%!-- suits every trackpad.                                     --%>
            <div class="mb-4">
              <.checkbox
                variant="toggle"
                name="viewer_invert_two_finger_pan"
                checked={@viewer_invert_two_finger_pan}
                label={gettext("Invert two-finger pan")}
                phx-click="toggle_viewer_invert_two_finger_pan"
                phx-target={@myself}
              >
                <:description>
                  {gettext(
                    "If moving around a picture with two fingers on your trackpad goes the opposite way to what you expect, turn this on. Zooming is not affected."
                  )}
                </:description>
              </.checkbox>
            </div>
            <p class="text-sm text-base-content/60 mb-3">
              {gettext(
                "Your drawing colours, line thickness, label size and toolbar layout are remembered as you work. Reset them to start fresh."
              )}
            </p>
            <div class="flex flex-wrap items-center gap-3">
              <button
                type="button"
                phx-click="reset_etcher_settings"
                phx-target={@myself}
                data-confirm={
                  gettext("Reset your annotation colours, thickness and toolbar to the defaults?")
                }
                class="btn btn-outline btn-sm gap-2"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4" />
                {gettext("Reset annotation settings")}
              </button>
              <span :if={@etcher_reset_message} class="text-sm text-success">
                {@etcher_reset_message}
              </span>
            </div>
            <p class="text-xs text-base-content/50 mt-2">
              {gettext("Your annotations themselves are not touched — only how the tools are set up.")}
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
