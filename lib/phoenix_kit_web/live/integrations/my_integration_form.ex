defmodule PhoenixKitWeb.Live.Integrations.MyIntegrationForm do
  @moduledoc """
  Add / edit a PERSONAL integration connection for the current user.

  `:new` shows a provider picker (only `for_scope(:personal)` providers), then a
  name + setup-fields form. `:edit` loads the connection owner-scoped and shows
  its setup fields with Test / Delete.

  Every context call is scoped to `owner: {:user, uuid}` where the uuid comes
  ONLY from the request scope — a crafted `:edit` uuid for another user's row
  fails closed (redirects), never exposing their credentials. No OAuth flow:
  personal providers are self-owned-secret types validated in place.

  Renders with the shared `Components.Core.IntegrationsUI` so it stays visually
  consistent with the website-wide page (`Live.Settings.IntegrationForm`).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.IntegrationsUI,
    only: [
      provider_picker: 1,
      provider_status_card: 1,
      setup_field: 1,
      setup_instructions: 1,
      connection_usage: 1,
      integration_error: 1
    ]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Integrations.Telegram
  alias PhoenixKit.Integrations.Telegram.ChatLink
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "integrations") do
      user_uuid = Scope.user_uuid(scope)

      {:ok,
       socket
       |> assign(:page_title, gettext("Integration"))
       |> assign(:project_title, Settings.get_project_title())
       |> assign(:user_uuid, user_uuid)
       |> assign(:providers, Providers.personal_offered())
       |> assign(:selected_provider, nil)
       |> assign(:provider, nil)
       |> assign(:uuid, nil)
       |> assign(:bucket_uses, 0)
       |> assign(:storage_usage, [])
       |> assign(:saving, false)
       |> assign(:name, nil)
       |> assign(:data, %{})
       # Groups the last Test found but did not link — held here, never
       # stored, until the owner confirms one (see `ChatLink`).
       |> assign(:telegram_candidates, [])
       # `new_name` / `form_values` hold what the operator typed on the /new
       # flow so a pre-save dry-run Test can re-render the form without
       # eating input.
       |> assign(:new_name, "")
       |> assign(:form_values, %{})
       |> assign(:validating, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You don't have access to Integrations."))
       |> redirect(to: Routes.path("/profile/settings"))}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    {:noreply,
     socket
     |> assign(:url_path, URI.parse(url).path)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    # `?provider=key` opens the form on that provider (another page links here,
    # e.g. the Media tab's "Add a connection"). Only a provider offered to
    # users is taken; anything else shows the picker.
    provider = Enum.find(socket.assigns.providers, &(&1.key == params["provider"]))

    socket
    |> assign(:page_title, gettext("Add Integration"))
    |> assign(:selected_provider, provider && provider.key)
    |> assign(:provider, provider)
    |> assign(:uuid, nil)
    |> assign(:name, nil)
    |> assign(:data, %{})
    |> assign(:new_name, "")
    |> assign(:form_values, %{})
  end

  defp apply_action(socket, :edit, %{"uuid" => uuid}) do
    # Owner-scoped load — a personal uuid belonging to another user (or a
    # system row) fails closed and redirects, never rendering credentials.
    case Integrations.get_integration_by_uuid(uuid, owner(socket)) do
      {:ok, %{provider: provider_key, name: name, data: data}} ->
        socket
        |> assign(:page_title, gettext("Integration"))
        |> assign(:uuid, uuid)
        |> assign(:bucket_uses, Map.get(Storage.bucket_counts_by_connection(), uuid, 0))
        |> assign(:storage_usage, Storage.integration_usage(uuid))
        |> assign(:name, name)
        |> assign(:data, data)
        |> assign(:selected_provider, provider_key)
        |> assign(:provider, Providers.get(provider_key))

      {:error, _} ->
        socket
        |> put_flash(:error, gettext("Integration not found"))
        |> push_navigate(to: Routes.path("/profile/settings/integrations"))
    end
  end

  @impl true
  # Only a provider the picker offered: the key arrives from the client, and the
  # list is what a site admin chose (`Providers.personal_offered/0`), not whatever
  # a hand-made event names.
  def handle_event(event, _params, %{assigns: %{live_action: :edit}} = socket)
      when event in ["select_provider", "back_to_providers"], do: {:noreply, socket}

  def handle_event("select_provider", %{"provider" => key}, socket) do
    case Enum.find(socket.assigns.providers, &(&1.key == key)) do
      nil ->
        {:noreply, socket}

      provider ->
        {:noreply,
         socket
         |> assign(:selected_provider, key)
         |> assign(:provider, provider)
         |> assign(:data, %{})
         |> assign(:new_name, "")
         |> assign(:form_values, %{})}
    end
  end

  # A field that re-shapes the form (the object-storage service) changed: keep
  # what is typed so far and render the fields the new choice asks for.
  def handle_event("setup_changed", params, socket) do
    provider = socket.assigns.provider
    keys = Enum.map(provider.setup_fields, & &1.key)

    # Seed only the service from saved data: secrets must never become typed
    # values and be echoed into the page. This also preserves an inferred
    # legacy service on the first change to another field.
    previous =
      Map.put_new(
        socket.assigns.form_values,
        "service",
        Providers.setup_saved(provider, socket.assigns.data, %{})["service"]
      )

    typed = Providers.setup_changed(provider, previous, Map.take(params, keys))

    socket = assign(socket, :form_values, typed)

    socket =
      if socket.assigns.live_action == :new and is_binary(params["name"]),
        do: assign(socket, :new_name, params["name"]),
        else: socket

    {:noreply, socket}
  end

  def handle_event("back_to_providers", _params, socket) do
    {:noreply,
     assign(socket, selected_provider: nil, provider: nil, new_name: "", form_values: %{})}
  end

  # Pre-save dry-run: probe the provider with the values currently typed, no
  # row created. Preserves the entered name + fields so a failed test doesn't
  # blank the form. `formnovalidate` on the button lets it run without a name.
  def handle_event("save_new", %{"_intent" => "test"} = params, socket) do
    provider_key = socket.assigns.selected_provider
    attrs = setup_attrs(params, socket.assigns.provider)

    socket =
      socket
      |> assign(:new_name, String.trim(params["name"] || ""))
      |> assign(:form_values, attrs)

    {flash_kind, flash_msg} =
      case Integrations.validate_credentials(provider_key, attrs, owner: owner(socket)) do
        :ok -> {:info, gettext("Connection works")}
        {:ok, note} -> {:info, Integrations.note_text({:ok, note})}
        # Neither a pass nor a failure — this provider has no way to check a
        # connection at all, so nothing ran. :warning, not :info/:error —
        # matches the system form's tone (both are wrong in different ways).
        :unverified -> {:warning, gettext("Not tested — this provider has no connection check")}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, put_flash(socket, flash_kind, flash_msg)}
  end

  # Create: birth the row owned by this user, then persist the setup fields.
  def handle_event("save_new", params, socket) do
    provider_key = socket.assigns.selected_provider
    name = String.trim(params["name"] || "")

    with {:ok, %{uuid: uuid}} <-
           Integrations.add_connection(provider_key, name, socket.assigns.user_uuid,
             owner: owner(socket)
           ),
         {:ok, _} <-
           Integrations.save_setup(uuid, setup_attrs(params, socket.assigns.provider), nil,
             owner: owner(socket)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Integration added"))
       |> push_navigate(to: Routes.path("/profile/settings/integrations/#{uuid}"))}
    else
      {:error, :empty_name} ->
        {:noreply, put_flash(socket, :error, gettext("Please enter a name"))}

      {:error, :scope_not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("This provider can't be added here"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add integration"))}
    end
  end

  # The name and setup are committed together after validation.
  def handle_event("save", params, socket) do
    name = String.trim(params["name"] || "")
    uuid = socket.assigns.uuid
    attrs = Providers.setup_edit_attrs(socket.assigns.provider, socket.assigns.data, params)
    actor = socket.assigns.user_uuid
    opts = [owner: owner(socket)]

    if socket.assigns.provider.key == "object_storage" and socket.assigns.storage_usage != [] do
      {:noreply,
       socket
       |> assign(:saving, true)
       |> start_async(:save_storage, fn ->
         {uuid, Integrations.update_connection(uuid, name, attrs, actor, opts)}
       end)}
    else
      save_result(socket, Integrations.update_connection(uuid, name, attrs, actor, opts))
    end
  end

  def handle_event("validate_connection", _params, socket) do
    send(self(), :do_validate)
    {:noreply, assign(socket, :validating, true)}
  end

  # Telegram: who the bot messages. "single" locks to your one chat; "multi"
  # broadcasts to everyone who has started the bot.
  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["single", "multi"] do
    case Integrations.save_setup(socket.assigns.uuid, %{"mode" => mode}, socket.assigns.user_uuid,
           owner: owner(socket)
         ) do
      {:ok, _} -> {:noreply, reload(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_mode", _params, socket), do: {:noreply, socket}

  # Clear every captured chat — the escape hatch if the wrong chat got linked
  # (single mode has no nonce, so a stranger who messaged the bot right before
  # Test could be captured). Re-link by messaging the bot again + pressing Test.
  def handle_event("unlink_chats", _params, socket) do
    save_chat_ids(socket, [], gettext("Unlinked. Message the bot and press Test to re-link."))
  end

  # Link a chat by its id. Capture can only reach chats whose update is still
  # in Telegram's ~24h queue; an id the operator already knows (a group's, a
  # channel's) should not depend on that window.
  def handle_event("link_chat", %{"chat_id" => value}, socket) do
    existing = socket.assigns.data["chat_ids"] || []

    case ChatLink.normalize_chat_id(value) do
      {:ok, id} ->
        if id in existing do
          {:noreply, put_flash(socket, :info, gettext("That chat is already linked"))}
        else
          save_chat_ids(socket, existing ++ [id], gettext("Chat linked"))
        end

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Not a chat id — expected a number like -1001234567890, or @channelname")
         )}
    end
  end

  # Link a group the last Test found. The id is looked up in the candidates
  # this process captured, so the event cannot name an arbitrary chat.
  def handle_event("link_candidate", %{"chat_id" => id}, socket) do
    existing = socket.assigns.data["chat_ids"] || []

    case Enum.find(socket.assigns.telegram_candidates, &(&1["id"] == id)) do
      %{} = chat when is_binary(id) ->
        ids = Enum.uniq(existing ++ [id])

        meta =
          (socket.assigns.data["chat_meta"] || %{})
          |> Map.put(id, %{"type" => chat["type"], "title" => chat["title"]})
          |> ChatLink.prune_meta(ids)

        socket
        |> assign(
          :telegram_candidates,
          Enum.reject(socket.assigns.telegram_candidates, &(&1["id"] == id))
        )
        |> save_chats(ids, meta, gettext("Chat linked"))

      _ ->
        {:noreply, socket}
    end
  end

  # Remove ONE chat. The all-or-nothing `unlink_chats` above cannot express
  # "drop the group, keep my own chat" once more than one is linked.
  def handle_event("unlink_chat", %{"chat_id" => id}, socket) do
    remaining = Enum.reject(socket.assigns.data["chat_ids"] || [], &(&1 == id))

    save_chat_ids(socket, remaining, gettext("Chat unlinked"))
  end

  def handle_event("delete_connection", _params, socket) do
    case Integrations.remove_connection(socket.assigns.uuid, socket.assigns.user_uuid,
           owner: owner(socket)
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Integration removed"))
         |> push_navigate(to: Routes.path("/profile/settings/integrations"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           integration_error(reason)
         )}
    end
  end

  @impl true
  def handle_async(:save_storage, {:ok, {uuid, result}}, socket) do
    socket = assign(socket, :saving, false)
    if socket.assigns.uuid == uuid, do: save_result(socket, result), else: {:noreply, socket}
  end

  def handle_async(:save_storage, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> put_flash(:error, gettext("Saving stopped unexpectedly. Refresh before trying again."))}
  end

  defp save_result(socket, {:ok, data}) do
    {:noreply,
     socket
     |> assign(:data, data)
     |> assign(:name, data["name"])
     |> assign(:form_values, %{})
     |> put_flash(:info, gettext("Saved"))}
  end

  defp save_result(socket, {:error, reason}) do
    {:noreply, socket |> reload() |> put_flash(:error, integration_error(reason))}
  end

  @impl true
  def handle_info(:do_validate, socket) do
    result =
      Integrations.validate_connection(socket.assigns.uuid, socket.assigns.user_uuid,
        owner: owner(socket)
      )

    Integrations.record_validation(socket.assigns.uuid, result, owner: owner(socket))

    # For Telegram, Test doubles as chat capture: read the chats that have
    # messaged the bot and store them (single = link your chat when it is the
    # only private one that messaged the bot, multi = all).
    capture = maybe_capture_telegram_chats(socket)

    flash =
      case result do
        :ok ->
          capture_flash(capture, socket) || {:info, gettext("Connection works")}

        {:ok, note} ->
          capture_flash(capture, socket) || {:info, Integrations.note_text({:ok, note})}

        :unverified ->
          {:warning, gettext("Not tested — this provider has no connection check")}

        {:error, reason} ->
          {:error, reason}
      end

    {:noreply,
     socket
     |> assign(:validating, false)
     |> assign(:telegram_candidates, capture_candidates(capture))
     |> reload()
     |> then(fn s -> put_flash(s, elem(flash, 0), elem(flash, 1)) end)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Telegram chat capture (no-op for other providers). Reads the bot's pending
  # updates and merges the linkable chats per mode — see `ChatLink` for the
  # rules. `save_setup` merges `chat_ids` into the connection data; `reload/1`
  # (called after) refreshes it.
  #
  # Returns what actually happened so the caller's flash can say it: the old
  # version swallowed every outcome into `:ok`, which is why "nothing was
  # captured" and "your chat is linked" both read as "Connection works".
  defp maybe_capture_telegram_chats(
         %{assigns: %{provider: %{key: "telegram"}, uuid: uuid}} = socket
       ) do
    owner = owner(socket)
    mode = socket.assigns.data["mode"] || "single"
    existing = socket.assigns.data["chat_ids"] || []

    case Telegram.get_updates(uuid, offset: nil, owner: owner) do
      {:ok, updates} ->
        %{ids: ids, added: added, meta: meta, candidates: candidates, ambiguous?: ambiguous?} =
          ChatLink.capture(
            mode,
            existing,
            socket.assigns.data["chat_meta"] || %{},
            ChatLink.capturable_chats(updates)
          )

        if added != [] do
          Integrations.save_setup(
            uuid,
            %{"chat_ids" => ids, "chat_meta" => meta},
            socket.assigns.user_uuid,
            owner: owner
          )
        end

        if ambiguous?, do: {:ambiguous, candidates}, else: {:captured, added, candidates}

      _ ->
        :unreachable
    end
  end

  defp maybe_capture_telegram_chats(_socket), do: :not_telegram

  # A working token with nothing linked is the state that used to be reported
  # as plain success — and it is precisely the state in which no notification
  # will ever arrive. Say so.
  defp capture_candidates({:captured, _added, candidates}), do: candidates
  defp capture_candidates({:ambiguous, candidates}), do: candidates
  defp capture_candidates(_capture), do: []

  # "Only me" refused to guess between several private chats. Say why nothing
  # was linked and what does work — without naming any of those chats.
  defp capture_flash({:ambiguous, _candidates}, _socket) do
    {:warning,
     gettext(
       "Several people have messaged this bot, so we can't tell which chat is yours — nothing was linked. Link your chat by its ID below instead."
     )}
  end

  defp capture_flash({:captured, [_ | _] = added, _candidates}, _socket) do
    {:info, gettext("Linked %{count} chat(s)", count: length(added))}
  end

  # A group is never linked on its own — anyone can add a public bot to a
  # group of theirs — so say that one is waiting for a decision.
  defp capture_flash({:captured, [], [_ | _]}, _socket) do
    {:info, gettext("Found a group — confirm it below to link it.")}
  end

  defp capture_flash({:captured, [], []}, socket) do
    if socket.assigns.data["chat_ids"] in [nil, []] do
      {:warning,
       gettext(
         "The bot works, but no chat is linked yet — message the bot (or run /start@%{bot} in a group), then press Test again.",
         bot: bot_username(socket.assigns.data)
       )}
    end
  end

  # The token checked out but the update peek didn't: whatever is linked stays
  # linked, and nothing new could have been. Saying "connection works" here
  # would hide the one thing that just failed.
  defp capture_flash(:unreachable, _socket) do
    {:warning, gettext("The bot answers, but its chats could not be read just now — try again.")}
  end

  defp capture_flash(_capture, _socket), do: nil

  # What a linked chat IS, in words. Falls back to the id's own shape when no
  # metadata was captured (a hand-typed id, or one linked before this existed):
  # Telegram signs group ids negative, and an @handle is a channel.
  defp chat_kind_label(id, meta) do
    case (meta || %{})["type"] do
      "private" ->
        gettext("Direct message")

      type when type in ["group", "supergroup"] ->
        gettext("Group")

      "channel" ->
        gettext("Channel")

      _ ->
        cond do
          String.starts_with?(id, "@") -> gettext("Channel")
          ChatLink.group_id?(id) -> gettext("Group")
          true -> gettext("Direct message")
        end
    end
  end

  # BotFather's handle, as recorded by the last successful validation
  # ("Connected as @somebot") — the group command is useless without it, so an
  # unvalidated connection still gets a placeholder to show the shape.
  defp bot_username(data) do
    case Regex.run(~r/@([A-Za-z0-9_]+)/, to_string(data["validation_status"])) do
      [_, name] -> name
      _ -> "yourbot"
    end
  end

  # `chat_meta` (what each linked chat IS, so the card can name it) is kept
  # alongside `chat_ids` rather than inside it: the notifications channel reads
  # that list and must keep seeing plain ids. It follows the list on every
  # write — an unlinked chat's title has no business lingering.
  defp save_chat_ids(socket, ids, message) do
    save_chats(
      socket,
      ids,
      ChatLink.prune_meta(socket.assigns.data["chat_meta"] || %{}, ids),
      message
    )
  end

  defp save_chats(socket, ids, meta, message) do
    case Integrations.save_setup(
           socket.assigns.uuid,
           %{"chat_ids" => ids, "chat_meta" => meta},
           socket.assigns.user_uuid,
           owner: owner(socket)
         ) do
      {:ok, _} -> {:noreply, socket |> reload() |> put_flash(:info, message)}
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not save the linked chats"))}
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  # Dependency checks are enforced again by the context when the action runs.
  defp delete_confirm(0),
    do: gettext("Permanently delete this connection? This cannot be undone.")

  defp delete_confirm(count) do
    ngettext(
      "%{count} storage bucket uses this connection and prevents its removal.",
      "%{count} storage buckets use this connection and prevent its removal.",
      count
    )
  end

  defp owner(socket), do: {:user, socket.assigns.user_uuid}

  defp reload(%{assigns: %{uuid: uuid}} = socket) when is_binary(uuid) do
    case Integrations.get_integration_by_uuid(uuid, owner(socket)) do
      {:ok, %{name: name, data: data}} ->
        socket
        |> assign(:name, name)
        |> assign(:data, data)
        |> assign(:storage_usage, Integrations.usage(uuid, owner: owner(socket)))

      _ ->
        socket
    end
  end

  defp reload(socket), do: socket

  # Only the provider's declared setup-field keys are persisted, and a blank
  # is dropped for `:password` fields only (see `Providers.setup_attrs/2`).
  defp setup_attrs(params, provider), do: Providers.setup_attrs(provider, params)

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={gettext("Profile Settings")}
      page_section_path={Routes.path("/profile/settings")}
      page_crumbs={[
        %{label: gettext("My Integrations"), path: Routes.path("/profile/settings/integrations")}
      ]}
      page_subtitle={if @provider == nil, do: gettext("Choose a service to connect")}
      current_path={@url_path}
      project_title={@project_title}
      current_locale={assigns[:current_locale]}
    >
      <div class="px-4 py-6">
        <%!-- The profile's settings tabs, as on the list page, so "Add integration"
             and a connection's own page still say where you are. --%>
        <PhoenixKitWeb.Components.ProfileSettingsTabs.profile_tabs
          active="integrations"
          scope={assigns[:phoenix_kit_current_scope]}
        />
        <%!-- Step 1: Provider picker (new mode, no provider selected yet) --%>
        <div :if={@live_action == :new && @selected_provider == nil} class="max-w-4xl mx-auto">
          <.provider_picker providers={@providers} />
        </div>

        <%!-- Step 2: Setup form (provider selected in new mode, or edit mode) --%>
        <div :if={@provider != nil} class="space-y-6 max-w-4xl mx-auto">
          <button
            :if={@live_action == :new}
            phx-click="back_to_providers"
            class="btn btn-ghost btn-sm -mt-2"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            {gettext("Choose a different service")}
          </button>

          <.provider_status_card provider={@provider} data={@data} name={@name} />
          <.connection_usage usage={@storage_usage} />
          <p :if={@saving} role="status">{gettext("Checking every bucket before saving...")}</p>

          <form
            id="personal-integration-setup-form"
            phx-submit={if @live_action == :new, do: "save_new", else: "save"}
            phx-change={Providers.dynamic_setup?(@provider) && "setup_changed"}
            autocomplete="off"
          >
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body py-4 space-y-4">
                <%!-- Connection name — editable in both modes; the edit save
                     renames when it changes. --%>
                <div class="fieldset">
                  <label class="label" for="field-name">
                    <span class="fieldset-legend">{gettext("Connection Name")}</span>
                  </label>
                  <input
                    type="text"
                    id="field-name"
                    name="name"
                    value={@name || @new_name}
                    class="input w-full"
                    placeholder={gettext("e.g. My personal key")}
                    required
                  />
                </div>

                <p
                  :if={@live_action == :edit and Providers.storage_service_locked?(@provider, @data)}
                  class="text-sm"
                >
                  {gettext("Service")}: {Providers.setup_label(@provider, @data)}. {gettext(
                    "Create a new integration to use another service."
                  )}
                </p>
                <% saved = Providers.setup_saved(@provider, @data, @form_values) %>
                <input
                  :if={@live_action == :edit and Providers.storage_service_locked?(@provider, @data)}
                  type="hidden"
                  name="service"
                  value={PhoenixKit.Integrations.ObjectStorageServices.current(@data)}
                />
                <fieldset
                  :for={field <- Providers.setup_fields(@provider, Map.merge(saved, @form_values))}
                  :if={
                    @live_action == :new or field.key != "service" or
                      not Providers.storage_service_locked?(@provider, @data)
                  }
                  disabled={
                    @storage_usage != [] and field.key in ~w(endpoint region account_id jurisdiction)
                  }
                >
                  <.setup_field
                    field={field}
                    typed_value={Map.get(@form_values, field.key)}
                    saved_value={to_string(saved[field.key] || "")}
                  />
                </fieldset>

                <div class="flex flex-wrap gap-2 items-center pt-2">
                  <button
                    type="submit"
                    class="btn btn-primary"
                    disabled={@saving}
                    phx-disable-with={gettext("Saving…")}
                  >
                    {if @live_action == :new,
                      do: gettext("Create Connection"),
                      else: gettext("Save Changes")}
                  </button>

                  <%!-- Pre-save dry-run on /new: submits with `_intent=test`,
                       `formnovalidate` so a name isn't required just to probe
                       the credentials. On /edit, Test verifies the saved row. --%>
                  <button
                    :if={@live_action == :new}
                    type="submit"
                    name="_intent"
                    value="test"
                    formnovalidate
                    class="btn btn-outline"
                    phx-disable-with={gettext("Testing…")}
                  >
                    <.icon name="hero-signal" class="w-4 h-4" />
                    {gettext("Test Connection")}
                  </button>

                  <button
                    :if={@live_action == :edit}
                    type="button"
                    phx-click="validate_connection"
                    class={"btn btn-outline #{if @validating, do: "loading"}"}
                    disabled={@validating}
                  >
                    <.icon :if={!@validating} name="hero-signal" class="w-4 h-4" />
                    {if @validating, do: gettext("Testing..."), else: gettext("Test Connection")}
                  </button>
                </div>
              </div>
            </div>
          </form>

          <%!-- Telegram notifications: mode + captured chats. Test (above)
               doubles as chat capture. --%>
          <div
            :if={@live_action == :edit and @provider.key == "telegram"}
            class="card bg-base-100 shadow-sm"
          >
            <div class="card-body py-4 space-y-3">
              <h3 class="card-title text-base">{gettext("Notifications")}</h3>
              <p class="text-sm text-base-content/60">
                {gettext(
                  "Message your bot, then press Test above — we'll capture your chat so it can notify you. If several people have messaged the bot, we can't tell which chat is yours: link it by its ID below instead."
                )}
              </p>

              <form id="telegram-mode-form" phx-change="set_mode">
                <.select
                  name="mode"
                  label={gettext("Who does this bot message?")}
                  value={@data["mode"] || "single"}
                  options={[
                    {gettext("Only me"), "single"},
                    {gettext("Everyone who starts the bot"), "multi"}
                  ]}
                />
              </form>

              <p :if={(@data["mode"] || "single") == "multi"} class="text-xs text-warning">
                {gettext(
                  "Anyone who starts this bot will be linked on the next Test and will receive every notification sent here. Use it only for a bot you hand out deliberately."
                )}
              </p>

              <% chats = @data["chat_ids"] || [] %>
              <% meta = @data["chat_meta"] || %{} %>

              <p :if={chats == []} class="text-xs text-warning">
                {gettext("No chats linked yet — nothing will be delivered.")}
              </p>

              <ul :if={chats != []} class="divide-y divide-base-200">
                <li :for={id <- chats} class="flex items-center justify-between gap-3 py-1.5">
                  <span class="text-xs">
                    <span class="badge badge-ghost badge-sm mr-2">
                      {chat_kind_label(id, meta[id])}
                    </span>
                    <span :if={meta[id]["title"]} class="mr-2">{meta[id]["title"]}</span>
                    <span class="font-mono text-base-content/60">{id}</span>
                  </span>
                  <button
                    type="button"
                    phx-click="unlink_chat"
                    phx-value-chat_id={id}
                    data-confirm={gettext("Stop sending notifications to this chat?")}
                    class="btn btn-ghost btn-xs text-error gap-1"
                  >
                    <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                    {gettext("Unlink")}
                  </button>
                </li>
              </ul>

              <%!-- Groups the last Test found. Never linked on their own: a
                   bot's username is public, so a group it was added to need
                   not be the owner's. --%>
              <div
                :if={@telegram_candidates != []}
                class="rounded-box border border-info/40 p-3 space-y-2"
              >
                <p class="text-xs">
                  {gettext(
                    "Found by the last Test. Link a group only if you recognise it — anyone can add a bot to a group of their own."
                  )}
                </p>
                <ul class="divide-y divide-base-200">
                  <li
                    :for={chat <- @telegram_candidates}
                    class="flex items-center justify-between gap-3 py-1.5"
                  >
                    <span class="text-xs">
                      <span class="badge badge-ghost badge-sm mr-2">{gettext("Group")}</span>
                      <span :if={chat["title"]} class="mr-2">{chat["title"]}</span>
                      <span class="font-mono text-base-content/60">{chat["id"]}</span>
                    </span>
                    <button
                      type="button"
                      phx-click="link_candidate"
                      phx-value-chat_id={chat["id"]}
                      class="btn btn-outline btn-xs"
                    >
                      {gettext("Link")}
                    </button>
                  </li>
                </ul>
              </div>

              <%!-- Two ways in, because capture alone cannot reach every chat:
                   it only sees updates still in Telegram's ~24h queue. --%>
              <div class="rounded-box bg-base-200/50 p-3 space-y-2 text-xs">
                <p class="font-medium">{gettext("How to link a chat")}</p>
                <p>
                  {gettext("Your own chat:")}
                  <span class="font-mono">
                    /start
                  </span>
                  {gettext("the bot in Telegram, then press Test Connection above.")}
                  {gettext(
                    "If anyone else has messaged the bot too, link your chat by its ID below instead."
                  )}
                </p>
                <p>
                  {gettext("A group:")} {gettext("add the bot to the group, then send")}
                  <span class="font-mono">/start@{bot_username(@data)}</span>
                  {gettext(
                    "there, press Test Connection and confirm the group it finds. A group needs that command — bots cannot read ordinary group messages."
                  )}
                </p>
              </div>

              <form id="telegram-link-chat-form" phx-submit="link_chat" class="flex items-end gap-2">
                <div class="flex-1">
                  <.input
                    type="text"
                    id="telegram-chat-id-input"
                    name="chat_id"
                    value=""
                    label={gettext("Or link a chat by ID")}
                    placeholder="-1001234567890"
                  />
                </div>
                <button type="submit" class="btn btn-outline btn-sm">
                  {gettext("Link")}
                </button>
              </form>
            </div>
          </div>

          <.setup_instructions provider={@provider} scope={:personal} open={@live_action == :new} />

          <%!-- Danger Zone (edit mode only). Personal connections have no
               OAuth to disconnect — just permanent removal. --%>
          <details
            :if={@live_action == :edit}
            id="my-integration-danger-zone"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
            class="card bg-base-100 border-2 border-error/30"
          >
            <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-error" />
              <h3 class="font-semibold text-error text-base">
                {gettext("Danger Zone")}
              </h3>
              <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
            </summary>

            <div class="card-body pt-0 space-y-4">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <p class="font-medium text-sm">{gettext("Delete this connection")}</p>
                  <p class="text-xs text-base-content/60">
                    {gettext(
                      "Removes the integration permanently. Any module pinned to this connection will stop working until repointed."
                    )}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="delete_connection"
                  disabled={@storage_usage != []}
                  class="btn btn-outline btn-error btn-sm shrink-0"
                  data-confirm={delete_confirm(@bucket_uses)}
                  phx-disable-with={gettext("Deleting…")}
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                  {gettext("Delete")}
                </button>
              </div>
            </div>
          </details>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
