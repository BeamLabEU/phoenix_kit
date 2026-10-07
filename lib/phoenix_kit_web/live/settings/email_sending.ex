defmodule PhoenixKitWeb.Live.Settings.EmailSending do
  @moduledoc """
  Core "Emails Transactional" admin settings page (`/admin/settings/email-sending`).

  Covers what core owns about outbound TRANSACTIONAL email: sender identity,
  which transport is actually in effect (static app-config mailer vs. a
  connected Integrations provider), the operator's choice of default send
  integration, and a test-send action. Bulk/marketing sending config (Send
  Profiles — per-account sender identity, rate limits, provider-specific
  options) lives on its own sibling page, "Emails Bulk"
  (`/admin/settings/emails-bulk`) — a separate concern that Newsletters
  broadcasts consume, not something a fresh transactional-only install needs
  to see.

  ## Path note

  This page is deliberately at `email-sending`, not `emails` — the
  optional `phoenix_kit_emails` module registers its own routable
  "Emails" settings tab at `/admin/settings/emails` (via its
  `settings_tabs/0`). The two pages coexist under different paths for
  now; a later change (Stage 1 task A5) will collapse them into one.

  ## Branding

  The "Branding" tab holds the email accent colour (`email_accent_color`,
  read by `PhoenixKit.Email.Branding`) and shows the logo emails carry,
  linking to Settings → General where the logo is edited. A preview of every
  known email lives at `/admin/settings/email-sending/preview`
  (`PhoenixKitWeb.Live.Settings.EmailPreview`). The same tab switches the
  welcome email on and off (`email_welcome_enabled`,
  `PhoenixKit.Users.WelcomeEmail`).

  ## Module-contributed sections

  Modules can extend this page without the core page knowing anything
  about them, via `c:PhoenixKit.Module.email_settings_sections/0` — see
  `PhoenixKit.ModuleRegistry.all_email_settings_sections/0`. Each
  section is a module-owned `Phoenix.LiveComponent`, rendered below the
  core sections, gated by its declared permission (or shown to any admin
  when the permission is `nil`). A section with a `:link` also gets a button
  beside "Preview emails" on the Branding tab, under the same permission.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.IntegrationsUI, only: [validation_note_style: 1]

  alias PhoenixKit.Config
  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Mailer
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.WelcomeEmail
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  @default_integration_setting "default_email_integration_uuid"

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Emails Transactional"))
      |> assign(
        :page_subtitle,
        gettext(
          "Sender identity, transport, and the default integration used to deliver outbound email"
        )
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
      |> assign_sender_identity()
      |> assign_transport_info()
      |> assign_email_integrations()
      |> assign_default_integration()
      |> assign_dev_mailbox()
      |> assign_branding()
      |> assign_email_settings_sections()

    {:ok, socket}
  end

  # The tab lives in the URL (`?tab=transport`); see `UrlTabs`.
  def handle_params(params, _url, socket) do
    %{mailbox_local?: mailbox_local?, email_settings_sections: sections} = socket.assigns

    {:noreply,
     assign(socket, :active_tab, UrlTabs.active(params, tabs(mailbox_local?, sections)))}
  end

  defp tabs(mailbox_local?, email_settings_sections) do
    [
      %{id: "identity", label: gettext("Sender Identity"), icon: "hero-identification"},
      %{id: "branding", label: gettext("Branding"), icon: "hero-swatch"},
      %{id: "transport", label: gettext("Transport"), icon: "hero-server-stack"}
    ] ++
      if(mailbox_local?,
        do: [%{id: "mailbox", label: gettext("Local Dev Mailbox"), icon: "hero-inbox"}],
        else: []
      ) ++
      [
        %{
          id: "default_integration",
          label: gettext("Default Integration"),
          icon: "hero-paper-airplane"
        },
        %{id: "test_send", label: gettext("Test Send"), icon: "hero-paper-airplane"}
      ] ++
      Enum.map(email_settings_sections, fn section ->
        %{id: "module_#{section.id}", label: section.title, icon: "hero-puzzle-piece"}
      end)
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  def handle_event("save_sender_identity", %{"from_name" => name, "from_email" => email}, socket) do
    name = String.trim(name)
    email = String.trim(email)

    with {:ok, _} <- Settings.update_setting("from_name", name),
         {:ok, _} <- Settings.update_setting("from_email", email) do
      socket = assign_sender_identity(socket)

      # Saved either way — a host may genuinely want a local-only sender — but
      # say so at the moment of the change, not only in the banner above.
      {kind, message} =
        if socket.assigns.sender_loggable? do
          {:info, gettext("Sender identity updated")}
        else
          {:warning,
           gettext(
             "Sender identity updated, but %{email} is not a full address — the email tracking module will silently skip logging messages sent from it.",
             email: socket.assigns.effective_from_email
           )}
        end

      {:noreply, put_flash(socket, kind, message)}
    else
      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save sender identity"))}
    end
  end

  def handle_event("select_default_integration", %{"integration_uuid" => uuid}, socket) do
    case Settings.update_setting(@default_integration_setting, uuid) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Default send integration updated"))
         |> assign_default_integration()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not update default send integration"))}
    end
  end

  def handle_event("toggle_dev_mailbox", %{"enabled" => enabled}, socket) do
    value = if enabled == "true", do: "true", else: "false"

    case Settings.update_setting("dev_mailbox_enabled", value) do
      {:ok, _} ->
        message =
          if value == "true" do
            gettext(
              "Local mailbox enabled — tokens in auth mail are now readable at /dev/mailbox"
            )
          else
            gettext("Local mailbox disabled — outgoing dev mail goes to the server log")
          end

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign_dev_mailbox()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update the mailbox setting"))}
    end
  end

  def handle_event("toggle_welcome_email", params, socket) do
    value = if params["enabled"] == "true", do: "true", else: "false"

    case Settings.update_setting(WelcomeEmail.setting_key(), value) do
      {:ok, _} ->
        message =
          if value == "true",
            do: gettext("Welcome email switched on"),
            else: gettext("Welcome email switched off")

        {:noreply,
         socket
         |> assign(:welcome_email_enabled, value == "true")
         |> put_flash(:info, message)}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not update the welcome email setting"))}
    end
  end

  # Live check while typing: the swatch follows a valid value, the error
  # follows an invalid one. The colour picker and the text field edit the same
  # value; whichever the browser reports as changed wins.
  def handle_event("validate_accent_color", params, socket) do
    value =
      case params do
        %{"_target" => ["accent_color_picker"], "accent_color_picker" => picked}
        when is_binary(picked) ->
          picked

        %{"accent_color" => typed} when is_binary(typed) ->
          typed

        _ ->
          socket.assigns.accent_input
      end

    # A half-typed colour ("#1d4") is not an error yet; flag it once it is as
    # long as a whole one, or cannot become one.
    {:noreply, assign_accent_input(socket, value, complete?(value))}
  end

  def handle_event("save_accent_color", params, socket) do
    value =
      case params do
        %{"accent_color" => value} when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    case accent_color_value(value) do
      {:ok, color} ->
        case Settings.update_setting(Branding.accent_color_key(), color) do
          {:ok, _} ->
            message =
              if color == "",
                do: gettext("Email accent colour reset to the default"),
                else: gettext("Email accent colour updated")

            {:noreply, socket |> assign_branding() |> put_flash(:info, message)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save the accent colour"))}
        end

      :error ->
        {:noreply,
         socket
         |> assign_accent_input(value)
         |> put_flash(:error, accent_format_error())}
    end
  end

  def handle_event("send_test_email", %{"recipient" => recipient}, socket) do
    case String.trim(recipient) do
      "" ->
        {:noreply, put_flash(socket, :error, gettext("Enter a recipient email address"))}

      recipient ->
        send_test_email(socket, recipient)
    end
  end

  defp send_test_email(socket, recipient) do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient)
      |> Swoosh.Email.from({Mailer.get_from_name(), Mailer.get_from_email()})
      |> Swoosh.Email.subject(
        gettext("Test email from %{site}", site: socket.assigns.project_title)
      )
      |> Swoosh.Email.text_body(
        gettext("This is a test email sent from the Emails Transactional settings page.")
      )

    case Mailer.deliver_email(email) do
      {:ok, _result} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Test email sent to %{recipient}", recipient: recipient)
         )}

      {:error, {:incomplete_credentials, missing_fields}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Could not send test email: the send integration is missing required field(s): %{fields}",
             fields: Enum.map_join(missing_fields, ", ", &to_string/1)
           )
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not send test email: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — assigns
  # ---------------------------------------------------------------------------

  defp assign_sender_identity(socket) do
    effective_from_email = Mailer.get_from_email()

    socket
    |> assign(:from_name, Settings.get_setting("from_name", ""))
    |> assign(:from_email, Settings.get_setting("from_email", ""))
    |> assign(:effective_from_name, Mailer.get_from_name())
    |> assign(:effective_from_email, effective_from_email)
    |> assign(:sender_loggable?, loggable_sender?(effective_from_email))
  end

  # The email-tracking module refuses to log a message whose `from` is not a
  # full address — its Log changeset validates ~r/^[^\s]+@[^\s]+\.[^\s]+$/ — and
  # the interceptor swallows that rejection into a log line. The built-in default
  # `noreply@localhost` fails it, so a freshly enabled email system records
  # nothing at all while mail keeps going out: no rows, no error, nothing in the
  # UI. Mirroring the rule here turns that silent dead end into a warning on the
  # page that owns the address. Deliberately a copy and not a call: core must not
  # depend on the optional module (and the check is one regex).
  #
  # One clause, not a guarded pair: `Mailer.get_from_email/0` is the only caller
  # and always hands back a binary, so a `when is_binary/1` head plus a catch-all
  # is dead code dialyzer fails the build over (pattern_match_cov). `to_string/1`
  # keeps the same defensiveness without the unreachable clause — a nil settings
  # value becomes "", which the regex rejects.
  defp loggable_sender?(email),
    do: Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, to_string(email))

  defp assign_transport_info(socket) do
    mailer = Mailer.get_mailer()
    built_in? = mailer == PhoenixKit.Mailer

    config =
      if built_in?,
        do: Config.get(mailer, []),
        else: Config.get_parent_app_config(mailer, [])

    socket
    |> assign(:mailer_module, mailer)
    |> assign(:mailer_built_in?, built_in?)
    |> assign(:mailer_adapter, Keyword.get(config, :adapter))
  end

  # Single query for all email-capable providers' connections, mirroring
  # `PhoenixKitWeb.Live.Settings.Integrations.load_connections/1`.
  defp assign_email_integrations(socket) do
    providers = Providers.with_capability(:email_send)
    provider_keys = Enum.map(providers, & &1.key)
    providers_by_key = Map.new(providers, &{&1.key, &1})

    all_connections = Integrations.load_all_connections(provider_keys)

    connections =
      Enum.flat_map(providers, fn provider ->
        all_connections
        |> Map.get(provider.key, [])
        |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
          %{provider: providers_by_key[provider.key], uuid: uuid, name: name, data: data}
        end)
      end)

    assign(socket, :email_connections, connections)
  end

  defp assign_default_integration(socket) do
    assign(
      socket,
      :default_integration_uuid,
      Settings.get_setting(@default_integration_setting, "")
    )
  end

  # The section only exists when mail would actually land in the local
  # mailbox — the resolution must match deliver_email/2, not a raw config
  # read (issue #687). mailer_local?/0 is that resolution plus the
  # rescue/catch guard, so a dead pool degrades to a hidden section
  # instead of a crashed mount.
  defp assign_dev_mailbox(socket) do
    socket
    |> assign(:mailbox_local?, Config.mailer_local?())
    |> assign(:dev_mailbox_enabled, Settings.get_boolean_setting("dev_mailbox_enabled", false))
  end

  defp assign_branding(socket) do
    saved = Settings.get_setting(Branding.accent_color_key(), "") || ""

    socket
    |> assign(:accent_color, Branding.accent_color())
    |> assign(:email_logo_url, Branding.logo_url())
    |> assign(:welcome_email_enabled, WelcomeEmail.enabled?())
    |> assign_accent_input(saved)
  end

  # `accent_input` is what the field shows; `accent_preview` is the colour the
  # swatch paints — only ever a normalised `#rrggbb`, so the inline style can
  # never carry anything else.
  defp assign_accent_input(socket, value, show_error? \\ true) do
    value = to_string(value)

    {preview, error} =
      case accent_color_value(String.trim(value)) do
        {:ok, ""} -> {Branding.default_accent_color(), nil}
        {:ok, color} -> {color, nil}
        :error -> {socket.assigns[:accent_color] || Branding.default_accent_color(), show_error?}
      end

    socket
    |> assign(:accent_input, value)
    |> assign(:accent_preview, preview)
    |> assign(:accent_error, error)
  end

  defp complete?(value) do
    value = String.trim(value)
    String.length(value) >= 7 or not Regex.match?(~r/\A#?[0-9a-fA-F]*\z/, value)
  end

  defp accent_format_error,
    do: gettext("Enter the colour as #RRGGBB, for example #1d4ed8")

  # "" clears the setting (emails fall back to the neutral default); anything
  # else must be a six-digit hex colour. `Branding.normalize_color/1` answers
  # the default for a bad value, so compare against the input to tell them apart.
  defp accent_color_value(""), do: {:ok, ""}

  defp accent_color_value(value) do
    color = Branding.normalize_color(value)

    if color == String.downcase(value), do: {:ok, color}, else: :error
  end

  defp assign_email_settings_sections(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    sections =
      ModuleRegistry.all_email_settings_sections()
      |> Enum.filter(&section_visible?(&1, scope))

    socket
    |> assign(:email_settings_sections, sections)
    |> assign(:email_section_links, section_links(sections))
  end

  # A section's optional `:link` becomes a button beside "Preview emails".
  # Built from the already-filtered sections, so a user never gets a link to
  # a section they may not see. A link without a path opens the section's tab.
  defp section_links(sections) do
    for %{id: id, link: %{label: label} = link} <- sections,
        is_binary(label),
        target = link_target(id, link) do
      Map.merge(%{id: id, label: label, navigate: nil, patch: nil}, target)
    end
  end

  # Only a path of this app: "//host/..." is another host, not a path.
  defp link_target(_id, %{path: "//" <> _}), do: nil
  defp link_target(_id, %{path: "/" <> _ = path}), do: %{navigate: path}
  defp link_target(_id, %{path: _}), do: nil

  defp link_target(id, _link),
    do: %{patch: "/admin/settings/email-sending?tab=" <> URI.encode_www_form("module_#{id}")}

  defp section_visible?(%{permission: nil}, _scope), do: true

  defp section_visible?(%{permission: permission}, scope),
    do: Scope.has_module_access?(scope, permission)

  # ---------------------------------------------------------------------------
  # Private — template helpers
  # ---------------------------------------------------------------------------

  defp integration_status_badge("connected"), do: {"badge-success", gettext("Connected")}
  defp integration_status_badge("configured"), do: {"badge-warning", gettext("Not tested")}
  defp integration_status_badge("disconnected"), do: {"badge-ghost", gettext("Not connected")}
  defp integration_status_badge("error"), do: {"badge-error", gettext("Error")}
  defp integration_status_badge(_), do: {"badge-ghost", gettext("Not configured")}

  # Kept out of the template: the `{{accent_color}}` braces would read as a
  # HEEx expression there.
  defp accent_help_text do
    gettext(
      "Used for buttons and links in every email, and for the accent bar of the standard layout. Leave blank for neutral buttons and links (%{color}) and no accent bar. Email files read it as %{placeholder}.",
      color: Branding.default_accent_color(),
      placeholder: "{{accent_color}}"
    )
  end

  defp get_current_path(locale) do
    Routes.path("/admin/settings/email-sending", locale: locale)
  end
end
