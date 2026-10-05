defmodule PhoenixKitWeb.Live.Settings.Integrations do
  @moduledoc """
  Integrations list page — shows all configured service connections.

  Each connection is displayed as a card with status, connected account info,
  and quick actions (disconnect, test). An "Add Integration" button links to
  the form page for creating new connections.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  # Imported per-LiveView rather than from `PhoenixKitWeb, :live_view`: a host
  # app that defines its own `row_link/1` would get an ambiguous import the
  # moment core wired this one in project-wide.
  import PhoenixKitWeb.Components.Core.IntegrationsUI, only: [validation_note_style: 1]
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page_title, gettext("Integrations"))
      |> assign(
        :page_subtitle,
        gettext("Connect external services for use across modules")
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, project_title)
      |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
      |> load_encryption_report()
      |> load_connections()
      |> assign_personal_providers()
      |> assign(:validating, nil)

    {:ok, socket}
  end

  # The tab lives in the URL (`?tab=personal`); see `UrlTabs`.
  def handle_params(params, _url, socket) do
    {:noreply,
     assign(socket, :active_tab, UrlTabs.active(params, tabs(socket.assigns.connections)))}
  end

  defp tabs(connections) do
    [
      %{
        id: "connections",
        label: gettext("Connections"),
        icon: "hero-link",
        badge: if(connections != [], do: length(connections))
      },
      %{id: "personal", label: gettext("Personal integrations"), icon: "hero-user-circle"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  def handle_event("disconnect", %{"uuid" => uuid}, socket) do
    Integrations.disconnect(uuid, Actor.uuid(socket), owner: :system)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Disconnected"))
     |> load_connections()}
  end

  # Which services users may connect on their own (the personal "add" picker).
  # Only providers that may be personal are kept.
  def handle_event("save_personal_providers", params, socket) do
    keys = params |> get_in(["personal", "providers"]) |> List.wrap()

    case Providers.put_personal_enabled(keys) do
      {:ok, _kept} ->
        {:noreply,
         socket
         |> assign_personal_providers()
         |> put_flash(:info, gettext("Personal integrations saved"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Personal integrations could not be saved"))}
    end
  end

  def handle_event("validate_connection", %{"uuid" => uuid}, socket) do
    send(self(), {:do_validate, uuid})
    {:noreply, assign(socket, :validating, uuid)}
  end

  def handle_event("remove_connection", %{"uuid" => uuid}, socket) do
    case Integrations.remove_connection(uuid, Actor.uuid(socket), owner: :system) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Connection removed"))
         |> load_connections()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove connection"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Async validation
  # ---------------------------------------------------------------------------

  def handle_info({:do_validate, uuid}, socket) do
    actor = Actor.uuid(socket)
    result = Integrations.validate_connection(uuid, actor, owner: :system)
    Integrations.record_validation(uuid, result, owner: :system)

    {:noreply,
     socket
     |> assign(:validating, nil)
     |> load_connections()
     |> check_flash(result)}
  end

  # ---------------------------------------------------------------------------
  # PubSub handlers
  # ---------------------------------------------------------------------------

  def handle_info({:integration_setup_saved, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connected, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_disconnected, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_validated, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_added, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_removed, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_renamed, _, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  # Catch-all to prevent crashes from unexpected messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Computed once at mount, not on every `load_connections/1` reload below.
  # `Encryption.key_report/0` is store-backed, not a pure config read: with a
  # Chain/S3 store it does a network round trip, and it always runs a
  # PBKDF2-HMAC-SHA256 with 100_000 iterations (~0.1 CPU-sec) to fingerprint
  # the key. `load_connections/1` runs on every PubSub event this LiveView
  # gets, including ones about connections that have nothing to do with the
  # key, so paying that cost there on each one would be wasted work.
  #
  # The trade-off this accepts: the report CAN go stale before the operator
  # reloads the page. The dedicated key itself only changes on a restart
  # (rotation is a Mix task, and there is no running-app event for "the key
  # changed"), which would remount this LiveView anyway — but the STORE
  # around that key is read fresh on every `key_report/0` call precisely so
  # `store_unreadable`/`store_shadowed`/`no_secret_yet` can flip on a live VM
  # without a restart (see `Encryption.key_signals/0` and `store_state/2`),
  # and this page will not notice such a flip until it is reloaded.
  defp load_encryption_report(socket) do
    # ONE report per mount. This used to be three separate calls —
    # `status/0`, `key_diagnosis/0`, `key_fingerprint/0` — each re-resolving the
    # key independently, and a key store that answers one read and fails the
    # next could hand the three of them different answers for the same page.
    report = Encryption.key_report()

    socket
    |> assign(:encryption_report, report)
    |> assign(:encryption_fingerprint, encryption_fingerprint(report))
  end

  # The providers that may be personal, each with whether users are offered it:
  # ticked by the admin, or (Object Storage) because users may keep a library on
  # their own bucket (`Providers.also_while_on?/1`).
  defp assign_personal_providers(socket) do
    capable = Providers.for_scope(:personal)
    enabled = Providers.personal_enabled_keys(capable)

    rows =
      Enum.map(capable, fn provider ->
        %{
          provider: provider,
          enabled: provider.key in enabled,
          forced: Providers.also_while_on?(provider)
        }
      end)

    assign(socket, :personal_providers, rows)
  end

  # What the Remove confirmation says. A connection is removed without checking
  # who uses it, so a bucket that does is named before it stops working.
  defp remove_confirm(bucket_counts, uuid) do
    case Map.get(bucket_counts, uuid, 0) do
      0 ->
        gettext(
          "This integration may be in use by other parts of the system. Remove it permanently?"
        )

      count ->
        ngettext(
          "%{count} storage bucket uses this connection and will stop working. Remove it permanently?",
          "%{count} storage buckets use this connection and will stop working. Remove it permanently?",
          count
        )
    end
  end

  defp load_connections(socket) do
    # System page: only providers usable system-wide, and only SYSTEM-owned
    # connections (owner: :system) — a user's personal connection never leaks here.
    providers = Providers.for_scope(:system)
    provider_keys = Enum.map(providers, & &1.key)
    providers_by_key = Map.new(providers, &{&1.key, &1})

    # Single query for all providers instead of N+1
    all_connections = Integrations.load_all_connections(provider_keys, owner: :system)

    connections =
      Enum.flat_map(providers, fn provider ->
        Map.get(all_connections, provider.key, [])
        |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
          %{
            provider: providers_by_key[provider.key],
            uuid: uuid,
            name: name,
            data: data
          }
        end)
      end)

    socket
    |> assign(:connections, connections)
    |> assign(:bucket_counts, Storage.bucket_counts_by_connection())
    |> assign(:provider_names, join_with_and(Enum.map(providers, & &1.name)))
  end

  # Joins a list of names with commas, using a translated "and" before
  # the final item: ["A"] → "A", ["A", "B"] → "A and B",
  # ["A", "B", "C"] → "A, B and C". `gettext("and")` is extracted to the
  # .pot so each locale can supply its own conjunction.
  defp join_with_and([]), do: ""
  defp join_with_and([single]), do: single

  defp join_with_and(list) do
    {init, [last]} = Enum.split(list, -1)
    Enum.join(init, ", ") <> " " <> gettext("and") <> " " <> last
  end

  defp get_current_path(locale) do
    Routes.path("/admin/settings/integrations", locale: locale)
  end

  # A provider's icon in a tile of fixed size. Heroicons do not fill their
  # box evenly — an envelope reaches the edges, a sparkle floats in the
  # middle — so glyphs sized alike looked slim beside padded ones. The tile
  # is what lines up; the glyph sits centred inside it.
  attr :name, :string, required: true

  defp provider_icon(assigns) do
    ~H"""
    <span class="inline-flex w-7 h-7 shrink-0 items-center justify-center rounded-md bg-base-200 text-base-content/70">
      <.icon name={@name} class="w-4 h-4" />
    </span>
    """
  end

  defp integration_status_badge("connected"), do: {"badge-success", gettext("Connected")}
  defp integration_status_badge("configured"), do: {"badge-warning", gettext("Not tested")}
  defp integration_status_badge("disconnected"), do: {"badge-ghost", gettext("Not connected")}
  defp integration_status_badge("error"), do: {"badge-error", gettext("Error")}
  defp integration_status_badge(_), do: {"badge-ghost", gettext("Not configured")}

  # Public seams, `@doc false`: the defect these exist against lives in the
  # rendering, and a test that cannot reach the rendering cannot guard it — the
  # same reasoning that made `Mix.Tasks.PhoenixKit.Doctor.integration_key_result/2`
  # public. The template guards the banner on the report's severity, so the
  # healthy `{:dedicated, :ok}` case never reaches these.
  #
  # Keyed on `report.diagnosis`, not on the status alone. Keyed on the status,
  # this page told an operator whose key store is merely UNREADABLE that "no
  # dedicated encryption key is configured" — false, they configured one — and
  # then advised the rotation that would abandon the key their data may be
  # encrypted under.
  #
  # `{:dedicated, :store_unreadable}` gets its own clause ahead of the generic
  # one for the same reason it got its own clause in `Encryption.key_report/1`:
  # without it this page called a working dedicated key a FALLBACK, and — since
  # the banner used to be guarded on `status != :dedicated` — printed that label
  # under no banner at all, so the broken store was never mentioned.
  @doc false
  def encryption_status_title(%{diagnosis: {:dedicated, :store_unreadable}}),
    do: gettext("The encryption key is fine, but its key store cannot be read")

  def encryption_status_title(%{diagnosis: {:dedicated, :store_shadowed}}),
    do: gettext("The key store holds a different secret from the key in use")

  def encryption_status_title(%{diagnosis: {_status, :store_unreadable}}),
    do: gettext("The configured encryption key store cannot be read")

  # Mirrors `{_status, :store_unreadable}` immediately above: `:legacy` and
  # `:none` only had the `:dedicated` clause to fall back to, which is silent
  # about the store for the exact window — after a rotation, before the
  # restart it requires — where an operator most needs to hear that the store
  # already holds a secret waiting to be picked up.
  def encryption_status_title(%{diagnosis: {_status, :store_shadowed}}),
    do: gettext("The configured key store holds a different secret")

  # A rejected key does not have to be `integrations_encryption_key`. Until the
  # store could supply one, it always was, and these clauses said so; the moment
  # it could, they went on saying it. The source is now carried on the report
  # rather than assumed from the diagnosis.
  def encryption_status_title(%{diagnosis: {_status, :key_too_short}, rejected_key: :store}),
    do: gettext("The secret in the key store was rejected as too short")

  def encryption_status_title(%{diagnosis: {_status, :key_too_short}}),
    do: gettext("The configured encryption key was rejected as too short")

  def encryption_status_title(%{diagnosis: {:legacy_secret_key_base, _reason}}),
    do: gettext("Credentials are protected only by a shared application secret")

  def encryption_status_title(%{diagnosis: {:disabled_no_key, _reason}}),
    do: gettext("Credentials are stored in plain text")

  def encryption_status_title(%{diagnosis: {:disabled_explicit, _reason}}),
    do: gettext("Encryption is turned off for integration credentials")

  # Catch-all: the template renders this banner for ANY status other than
  # `:dedicated` (see the guard note above), so a future `key_status/0`
  # value this page hasn't been taught about must degrade to a generic
  # warning instead of a `FunctionClauseError` crashing the settings page.
  def encryption_status_title(_report),
    do: gettext("Integration credential encryption needs attention")

  # Two clauses per fault, because the consequence genuinely differs: with a
  # legacy secret still available the data is merely on a weaker key, with none
  # it is in plain text. Saying "fell back" in the second case is the exact
  # falsehood this module already removed from two other surfaces — and saying
  # it for `{:dedicated, _}` is the same falsehood a third time, since nothing
  # fell back at all there.
  @doc false
  def encryption_status_detail(%{diagnosis: {:dedicated, :store_unreadable}}) do
    gettext(
      "Encryption itself is working — the key in use comes from configuration. The configured " <>
        "key store cannot be read, so nothing confirms that key is saved anywhere. Do not " <>
        "rotate until the store reads back: the rotation pre-flight only checks that the " <>
        "store can be written, so it will not stop for this."
    )
  end

  def encryption_status_detail(%{diagnosis: {:dedicated, :store_shadowed}}) do
    gettext(
      "Encryption is working — the key in use comes from configuration. The configured key " <>
        "store holds a different secret, so it is not a copy of that key: restoring from it " <>
        "would produce a key that decrypts nothing stored here. Do not rotate before you " <>
        "know what the stored secret is for — a rotation replaces it in every configured " <>
        "store and keeps no copy."
    )
  end

  def encryption_status_detail(%{diagnosis: {:disabled_no_key, :store_unreadable}}) do
    gettext(
      "A key store is configured but its secret could not be read, and no other key resolves " <>
        "either — credentials below are being written in plain text. Do NOT run " <>
        "mix phoenix_kit.integrations.rotate_key: the stored key may be the one existing " <>
        "credentials are encrypted under. Repair the store first; repairing it later will not " <>
        "make anything written in the meantime readable."
    )
  end

  def encryption_status_detail(%{diagnosis: {_status, :store_unreadable}}) do
    gettext(
      "A key store is configured but its secret could not be read, so encryption fell back to " <>
        "a weaker key. Values written under the stored key will not decrypt. Do NOT run " <>
        "mix phoenix_kit.integrations.rotate_key: the stored key may be the one they are " <>
        "encrypted under. Repair the store first; repairing it later will not make anything " <>
        "written in the meantime readable."
    )
  end

  def encryption_status_detail(%{diagnosis: {:disabled_no_key, :store_shadowed}} = report) do
    gettext(
      "A key store is configured and holds a secret at %{location}, but no encryption key " <>
        "resolves at all — credentials below are being written in plain text. Do NOT run " <>
        "mix phoenix_kit.integrations.rotate_key: it refuses while no key is active. Check " <>
        "what the store holds — if it is a real key from an earlier rotation, wire it in as " <>
        "integrations_encryption_key and restart.",
      location: store_location(report)
    )
  end

  # Mirrors the generic `{_status, :store_unreadable}` clause above, for the
  # sibling fault: the store holds something, just not the key in use. Most
  # plausibly the window between a rotation and the restart it requires — see
  # `Encryption.key_report/1`'s `:legacy, store: {:shadowed, _}` clause.
  def encryption_status_detail(%{diagnosis: {_status, :store_shadowed}} = report) do
    gettext(
      "A key store is configured but holds a secret that is not the key in use, so " <>
        "encryption fell back to a weaker key. %{location} is most plausibly already " <>
        "holding a dedicated secret from a rotation this app has not restarted to pick up " <>
        "yet. Do NOT run mix phoenix_kit.integrations.rotate_key before checking: if that " <>
        "is the case, restart instead of rotating again, since rotating replaces it with no " <>
        "copy kept.",
      location: store_location(report)
    )
  end

  # The clause the checker found. Keyed on the diagnosis alone it matched ANY
  # status with a rejected key and told an operator whose short secret sits in
  # the key store that "the key store is not consulted at all, so repairing or
  # filling the store changes nothing" — false three times over, and it argues
  # against the one repair that would work.
  def encryption_status_detail(
        %{diagnosis: {:disabled_no_key, :key_too_short}, rejected_key: :store} = report
      ) do
    gettext(
      "The secret in the key store (%{location}) was rejected as shorter than the minimum, " <>
        "and no other key resolves — credentials below are being written in plain text. No " <>
        "integrations_encryption_key is set, so the store is where the key is read from: put " <>
        "a longer secret there and restart.",
      location: store_location(report)
    )
  end

  def encryption_status_detail(
        %{diagnosis: {_status, :key_too_short}, rejected_key: :store} = report
      ) do
    gettext(
      "The secret in the key store (%{location}) was rejected as shorter than the minimum, " <>
        "so a weaker key is in use. No integrations_encryption_key is set, so the store is " <>
        "where the key is read from: put a longer secret there and restart.",
      location: store_location(report)
    )
  end

  def encryption_status_detail(%{diagnosis: {:disabled_no_key, :key_too_short}}) do
    gettext(
      "A dedicated encryption key is configured but was rejected as too short, and no other " <>
        "key resolves — credentials below are being written in plain text. Replace it with a " <>
        "longer secret and restart; rotation cannot help while no key is active."
    )
  end

  def encryption_status_detail(%{diagnosis: {_status, :key_too_short}}) do
    gettext(
      "A dedicated encryption key is configured but was rejected as too short, so a weaker " <>
        "key is in use. This is not the same as having none configured. Replace it with a " <>
        "longer secret — while a rejected key is set, the key store is not consulted at all, " <>
        "so repairing or filling the store changes nothing."
    )
  end

  def encryption_status_detail(%{diagnosis: {:legacy_secret_key_base, _reason}}) do
    gettext(
      "No dedicated encryption key is configured, so credentials below fall back to a key " <>
        "derived from secret_key_base — a secret shared with session signing and CSRF tokens. " <>
        "Anyone who can read secret_key_base can decrypt every credential here. Run " <>
        "mix phoenix_kit.integrations.rotate_key to fix this."
    )
  end

  def encryption_status_detail(%{diagnosis: {:disabled_no_key, _reason}}) do
    gettext(
      "No encryption key could be resolved. New and existing credentials below are stored as " <>
        "plain text in the database."
    )
  end

  def encryption_status_detail(%{diagnosis: {:disabled_explicit, _reason}}) do
    gettext(
      "integration_encryption_enabled is set to false. Credentials below are stored as plain " <>
        "text in the database."
    )
  end

  # See `encryption_status_title/1`'s catch-all note.
  def encryption_status_detail(_report) do
    gettext(
      "The current encryption status could not be described by this admin page — it may be " <>
        "newer than what this page recognizes. Check PhoenixKit.Integrations.Encryption.status/0 " <>
        "directly."
    )
  end

  # Returns `{fingerprint, tier}` or nil. The tier is not decoration: a site
  # whose key store is unreadable, or whose dedicated key was rejected as too
  # short, fingerprints its FALLBACK key. A bare number would let an operator
  # comparing two sites conclude their keys differ when the comparison was never
  # like-for-like.
  #
  # `:none` renders nothing rather than a placeholder: with no key there is
  # nothing to compare, and the banner above already says the credentials are
  # unencrypted.
  defp encryption_fingerprint(report) do
    case report.fingerprint do
      {:ok, fingerprint, _label} -> {fingerprint, fingerprint_tier(report)}
      :none -> nil
    end
  end

  # `:key_store` is `{state, location}` or nil; a clause that names a location
  # only runs where the store supplied the secret, so nil cannot reach it — but
  # the verdict is total and so is this.
  defp store_location(%{key_store: {_state, location}}), do: location
  defp store_location(_report), do: "the configured key store"

  @doc false
  def fingerprint_tier(%{diagnosis: {:dedicated, :ok}}), do: gettext("dedicated key")

  # Ahead of the generic `:store_unreadable` clause below, which would otherwise
  # label a working dedicated key "FALLBACK".
  def fingerprint_tier(%{diagnosis: {:dedicated, :store_unreadable}}),
    do: gettext("dedicated key — its key store could not be read")

  def fingerprint_tier(%{diagnosis: {:dedicated, :store_shadowed}}),
    do: gettext("dedicated key — the key store holds a different secret")

  def fingerprint_tier(%{diagnosis: {_status, :store_unreadable}}),
    do: gettext("FALLBACK key — the configured key store could not be read")

  def fingerprint_tier(%{diagnosis: {_status, :store_shadowed}}),
    do: gettext("FALLBACK key — the configured key store holds a different secret")

  def fingerprint_tier(%{diagnosis: {_status, :key_too_short}, rejected_key: :store}),
    do: gettext("FALLBACK key — the secret in the key store was rejected as too short")

  def fingerprint_tier(%{diagnosis: {_status, :key_too_short}}),
    do: gettext("FALLBACK key — the configured key was rejected as too short")

  def fingerprint_tier(%{diagnosis: {:legacy_secret_key_base, _}}),
    do: gettext("derived from secret_key_base")

  def fingerprint_tier(_report), do: gettext("unrecognised key state")
  # A check from the list said nothing at all before: the row was reloaded and
  # whatever the provider reported was dropped. What it reports is now the only
  # place a figure appears — a balance, the searches left — since a figure is
  # never stored (`t:PhoenixKit.Integrations.Probe.note/0`).
  defp check_flash(socket, result) do
    case result do
      :unverified ->
        put_flash(
          socket,
          :warning,
          gettext("Not tested — this provider has no connection check")
        )

      {:error, reason} ->
        put_flash(socket, :error, "#{gettext("Test failed")}: #{reason}")

      _ok ->
        case Integrations.note_text(result) do
          nil -> put_flash(socket, :info, gettext("Connection verified"))
          note -> put_flash(socket, :info, "#{gettext("Connection verified")} — #{note}")
        end
    end
  end
end
