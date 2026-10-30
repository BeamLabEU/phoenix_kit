defmodule PhoenixKitWeb.Live.Settings.Api do
  @moduledoc """
  Settings -> API: the two switches of the machine API, the API switch of each module
  that declares tools, the API keys (create,
  rotate, edit the scopes, revoke), the service users that can own keys, the
  one-time dialog that shows a new key, and the "Limits and advanced" settings
  (rate limits, hidden tools, allowed MCP origins).

  The page is split into tabs held in the URL (`?tab=…`, see
  `PhoenixKitWeb.Live.Settings.UrlTabs`): switches and modules (the default), keys and
  service users, approvals and limits, and the API guide
  (`PhoenixKitWeb.Live.Settings.ApiGuidePanel`, built each time its tab is opened). The
  other panes are all rendered and only hidden, so a form keeps what was typed when the
  tab changes; the dialogs sit outside the panes.

  Gated by the `api` permission (opt-in for Admin; see
  `PhoenixKitWeb.Users.Auth`'s view map). Every change goes through
  `PhoenixKit.API.Keys` and `PhoenixKit.Settings`, with this admin as the actor.

  ## The new key is shown once, and only here

  `PhoenixKit.API.Keys.create_key/3` and `rotate/3` return the token a single
  time. This LiveView keeps it in **one socket assign**, `:new_token`, for as long
  as the dialog is open, and nowhere else:

    * never in a flash (flashes can ride a redirect and the session);
    * never in a URL or a `push_patch` (a key in a URL is refused by the API);
    * never in a `phx-value-*` attribute or a form field (LiveView logs event
      params at debug level);
    * never in a log line.

  The dialog cannot be closed by Esc or a click outside, so the secret is not
  lost by accident; `dismiss_token` clears the assign.

  ## Per-module switches

  Every module that declares API tools (`PhoenixKit.ModuleRegistry.api_modules/0`) has an
  on/off switch. Off adds the module's key to `api_disabled_modules`, and
  `PhoenixKit.API.Registry` then withholds all its tools like hidden ones. The event names
  the module by key and the state it wants; the key must be one of the listed modules and
  the other keys of the setting are kept as they are.

  ## "Agent may act"

  A module that has write tools also has the box "Agent may act" beside its switch. On, its
  key is in `api_session_write_modules`, and a person's live session (an assistant that
  works in the browser, `PhoenixKit.API.Executor.execute_as/5` with `allow: :all`) may
  propose its writes, each held until that person confirms it. Off by default; while the
  module's API is off it cannot be turned on (an unticked box is disabled), but a ticked one
  can still be taken off. API keys do not read it. The event and the checks are the
  switch's.

  ## The tools of each module

  A module's row also lists its admin tools in a collapsible section: whether it reads or
  writes, its permission, and whether an assistant in a person's live session may call it
  by the install's settings alone (`PhoenixKit.API.Executor.tool_availability/1` without a
  scope), or why not. It is read again after the module's switch, its "Agent may act" box
  and the hidden tools change. The rights of each person are checked on top of it, which
  the section says.

  ## Rights are checked on the server

  The form only offers what the person may do, and every event checks it again:
  the owner must be the person themselves or a service user they may use
  (`PhoenixKit.API.ServiceUsers.list/1`), every scope must be one the owner could
  use, a role for a service user must be one `PhoenixKit.API.ServiceUsers` allows,
  and a key to revoke, rotate or edit must be one the person may see
  (`PhoenixKit.API.Keys.list_keys/1`; the key is never named by the client's
  params, only by the uuid the server stored when the dialog was opened). A
  forged event is refused, not trimmed.

  The person's own rights are re-read from the database for every event that
  changes something (`fresh_scope/1`): the scope captured at mount can be stale.
  A replayed `create_key` event does nothing: it is accepted only while the form
  is open and no new token waits to be dismissed.

  ## Personal keys

  A key with `personal == true` is one a person made for themselves on "My API keys"
  (`PhoenixKit.API.Keys.create_personal_key/3`). The keys table marks it with a "Personal key"
  badge and shows when it expires ("Expires on" for a live key, "Expires soon" only within
  seven days, the grace period of a rotation as "until …", "Owner inactive" or "No
  permission" while its owner may not use it; `PhoenixKitWeb.Components.PersonalKeyDisplay`,
  shared with "My API keys", computes the statuses once in `assign_state/1`; that costs a
  permission check per owner of a live personal key, so an event that changes no owner's
  rights, such as a switch, keeps the owners' rights it has read and reads only an owner it
  has not seen; each key's own status is always computed from the list just read).
  The row menu follows `PhoenixKit.API.Keys.can_manage?/2`: the owner has Edit scopes,
  Rotate and Revoke; an Owner looking at someone else's personal key has only "Remove
  scopes" and "Revoke" (`Keys.can_revoke?/2`). Removing scopes opens the scopes dialog
  in narrowing mode, which the server remembers in `:scopes_form` (never from params): it
  offers only the key's current scopes, all ticked, the inactive ones marked, and
  `Keys.update_scopes/3` keeps exactly what is left; adding a scope gives
  `:scopes_not_narrowing`. Rotating a key one cannot manage is refused by the server, and
  a rotation passes `impersonated:` read from the session at mount
  (`PhoenixKitWeb.Users.MultiSession.impersonated?/1`), so a personal key is not rotated
  while the person acts in another account. Editing the scopes and revoking one's own
  personal key stay allowed in such a session: no token is handed out. At the limit of live
  personal keys (`Keys.personal_keys_full?/1`) the rotate dialog of a personal key starts at
  a grace period of 0, because a longer one is refused with `:personal_key_limit`. The two settings
  of `PhoenixKit.API.PersonalKeysConfig` are edited in a card on the first tab.

  ## Limits and advanced

  The lists `api_disabled_tools` and `api_mcp_allowed_origins` and the six
  numbers of `PhoenixKit.API.Config.rate_limits/0`. The whole form is validated
  first and one invalid field saves nothing. Only values that differ from the
  current ones are written, each through `PhoenixKit.Settings` with this admin as
  the actor (a permanent `setting.changed` entry in the Activity log, which is
  where the key events are read too: this page has no history card).

  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.API.Access
  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.FlowConfig
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.DisplayToken
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Components.PersonalKeyDisplay
  alias PhoenixKitWeb.Live.Settings.ApiGuidePanel
  alias PhoenixKitWeb.Live.Settings.UrlTabs
  alias PhoenixKitWeb.Users.MultiSession

  # The two switches: the name used in the page, the setting it writes.
  @switches %{"admin" => "api_admin_enabled", "public" => "api_public_enabled"}

  # Limits form field -> {setting, key in `Config.rate_limits/0`}.
  @limit_fields [
    {"preauth_fail_per_min", "api_admin_preauth_fail_per_min", :preauth_fail_per_min},
    {"admin_per_min", "api_admin_rate_per_min", :admin_per_min},
    {"public_token_per_min", "api_public_token_rate_per_min", :public_token_per_min},
    {"public_ip_per_min", "api_public_ip_rate_per_min", :public_ip_per_min},
    {"new_rows_ip_hour", "api_public_new_rows_per_ip_hour", :new_rows_ip_hour},
    {"new_rows_global_hour", "api_public_new_rows_global_hour", :new_rows_global_hour}
  ]

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("API"))
      |> assign(
        :page_subtitle,
        gettext("Switches and keys for the API that outside programs and AI agents use.")
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(
        :current_path,
        Routes.path("/admin/settings/api", locale: socket.assigns.current_locale_base)
      )
      |> assign(:new_token, nil)
      |> assign(:new_token_name, nil)
      |> assign(:show_key_form, false)
      |> assign(:key_params, default_key_params())
      |> assign(:key_errors, [])
      |> assign(:scope_options, [])
      |> assign(:scope_tools, %{})
      |> assign(:revoke_confirmation, %{show: false})
      |> assign(:rotate_form, %{show: false})
      |> assign(:scopes_form, %{show: false})
      |> assign(:show_service_user_form, false)
      |> assign(:service_user_params, default_service_user_params())
      |> assign(:service_user_errors, [])
      |> assign(:api_scope, socket.assigns.phoenix_kit_current_scope)
      |> assign(:impersonated, MultiSession.impersonated?(session))
      |> assign(:guide, nil)
      |> assign_limits()
      |> assign_flow()
      |> assign_personal_keys()
      |> assign_state()

    {:ok, socket}
  end

  # The tab lives in the URL (`?tab=keys`); see `UrlTabs`. The guide is built when its
  # tab is opened, so the other tabs do not read the tool registry and the guide shows
  # the switches as they are now.
  @impl true
  def handle_params(params, _url, socket) do
    socket = assign(socket, :active_tab, UrlTabs.active(params, tabs()))

    socket =
      if socket.assigns.active_tab == "guide",
        do: ApiGuidePanel.assign_guide(socket),
        else: socket

    {:noreply, socket}
  end

  defp tabs do
    [
      %{id: "access", label: gettext("Switches and modules"), icon: "hero-power"},
      %{id: "keys", label: gettext("Keys and service users"), icon: "hero-key"},
      %{id: "approvals", label: gettext("Approvals and limits"), icon: "hero-shield-check"},
      %{id: "guide", label: gettext("API guide"), icon: "hero-book-open"}
    ]
  end

  # ── Switches ───────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_switch", %{"switch" => name}, socket)
      when is_map_key(@switches, name) do
    with_access(socket, fn socket ->
      key = Map.fetch!(@switches, name)

      case Settings.update_boolean_setting_with_module(
             key,
             not switch_on?(name),
             "api",
             history(socket)
           ) do
        {:ok, _setting} ->
          socket |> assign_state(statuses: :keep) |> put_flash(:info, switch_text(name))

        {:error, _changeset} ->
          put_flash(socket, :error, gettext("The switch could not be saved."))
      end
    end)
  end

  # The module must be one the page lists, and the new state is the one asked for (not
  # a flip), so a replayed or double-clicked event does not undo itself.
  def handle_event("set_module_api", %{"module" => key, "state" => state}, socket)
      when is_binary(key) and state in ["on", "off"] do
    with_access(socket, fn socket ->
      case Enum.find(ModuleRegistry.api_modules(), &(&1.key == key)) do
        nil -> refuse(socket)
        mod -> set_module_api(socket, mod, state == "on")
      end
    end)
  end

  # The "Agent may act" box: only a listed module that has write tools, and it may be
  # turned on only while the module's API is on (an unticked box is disabled otherwise);
  # off is always accepted. As with the switch, the state asked for, not a flip.
  def handle_event("set_module_session_write", %{"module" => key, "state" => state}, socket)
      when is_binary(key) and state in ["on", "off"] do
    with_access(socket, fn socket ->
      case Enum.find(api_modules(), &(&1.key == key and &1.writes?)) do
        nil -> refuse(socket)
        %{api_on?: false} when state == "on" -> refuse(socket)
        mod -> set_module_session_write(socket, mod, state == "on")
      end
    end)
  end

  # ── New key ────────────────────────────────────────────────────────

  # `owner` is set by the "New key" action of a service user's row; an owner the
  # person may not use only leaves the form with no scopes and fails on submit.
  def handle_event("open_create_key", params, socket) do
    with_access(socket, fn socket ->
      if token_pending?(socket) do
        refuse(socket)
      else
        owner = text(params["owner"], "self")

        socket
        |> assign(:key_errors, [])
        |> assign_key_form(%{default_key_params() | "owner" => owner})
      end
    end)
  end

  def handle_event("close_create_key", _params, socket) do
    {:noreply, close_key_form(socket)}
  end

  # Only from an open form: a forged change must not reopen a closed form.
  def handle_event("key_form_changed", %{"key" => params}, socket) when is_map(params) do
    with_access(socket, fn socket ->
      if socket.assigns.show_key_form do
        socket
        |> assign(:key_errors, [])
        |> assign_key_form(normalize_key_params(params))
      else
        socket
      end
    end)
  end

  # Only from an open form and only when no token waits to be dismissed: a
  # replayed event must not mint a second key or overwrite `:new_token`.
  def handle_event("create_key", %{"key" => params}, socket) when is_map(params) do
    with_access(socket, fn socket ->
      if socket.assigns.show_key_form and not token_pending?(socket) do
        create_key(socket, normalize_key_params(params))
      else
        refuse(socket)
      end
    end)
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, socket |> assign(:new_token, nil) |> assign(:new_token_name, nil)}
  end

  # ── Revoke ─────────────────────────────────────────────────────────

  def handle_event("request_revoke", %{"uuid" => uuid}, socket) do
    with_access(socket, fn socket ->
      case find_key(socket, uuid) do
        %{} = key ->
          if Keys.can_revoke?(scope(socket), key),
            do:
              assign(socket, :revoke_confirmation, %{show: true, uuid: key.uuid, name: key.name}),
            else: refuse(socket)

        nil ->
          put_flash(socket, :error, gettext("That key was not found."))
      end
    end)
  end

  def handle_event("cancel_revoke", _params, socket) do
    {:noreply, assign(socket, :revoke_confirmation, %{show: false})}
  end

  def handle_event("confirm_revoke", _params, socket) do
    with_access(socket, fn socket ->
      uuid = Map.get(socket.assigns.revoke_confirmation, :uuid)
      socket = assign(socket, :revoke_confirmation, %{show: false})

      case uuid && find_key(socket, uuid) do
        %{} = key ->
          if Keys.can_revoke?(scope(socket), key),
            do: revoke_key(socket, key),
            else: refuse(socket)

        _ ->
          put_flash(socket, :error, gettext("That key was not found."))
      end
    end)
  end

  # ── Rotate ─────────────────────────────────────────────────────────

  def handle_event("request_rotate", %{"uuid" => uuid}, socket) do
    with_access(socket, fn socket ->
      case find_key(socket, uuid) do
        nil ->
          put_flash(socket, :error, gettext("That key was not found."))

        key ->
          if Keys.can_manage?(scope(socket), key),
            do:
              assign(socket, :rotate_form, %{
                show: true,
                uuid: key.uuid,
                name: key.name,
                hours: if(at_personal_limit?(socket, key), do: "0", else: "1"),
                at_limit: at_personal_limit?(socket, key)
              }),
            else: refuse(socket)
      end
    end)
  end

  def handle_event("cancel_rotate", _params, socket) do
    {:noreply, assign(socket, :rotate_form, %{show: false})}
  end

  # Not while a token waits to be dismissed: a replayed confirm must not mint a
  # second key and overwrite the first one's token.
  def handle_event("confirm_rotate", %{"rotate" => %{"grace_hours" => hours}}, socket)
      when is_binary(hours) do
    with_access(socket, fn socket ->
      if token_pending?(socket) do
        refuse(socket)
      else
        uuid = Map.get(socket.assigns.rotate_form, :uuid)
        rotate_key(socket, uuid && find_key(socket, uuid), hours)
      end
    end)
  end

  # ── Edit scopes ────────────────────────────────────────────────────

  def handle_event("request_edit_scopes", %{"uuid" => uuid}, socket) do
    with_access(socket, fn socket ->
      key = find_key(socket, uuid)

      cond do
        is_nil(key) or not live?(key) ->
          put_flash(socket, :error, gettext("That key was not found."))

        Keys.can_manage?(scope(socket), key) ->
          open_scopes_form(socket, key)

        narrowing_only?(socket, key) ->
          open_narrow_form(socket, key)

        true ->
          refuse(socket)
      end
    end)
  end

  def handle_event("cancel_edit_scopes", _params, socket) do
    {:noreply, assign(socket, :scopes_form, %{show: false})}
  end

  # The key is the one the server stored when the dialog was opened, found again
  # through the person's own key list; the params only carry the scopes.
  def handle_event("save_key_scopes", %{"key_scopes" => %{"present" => "1"} = form}, socket) do
    with_access(socket, fn socket ->
      uuid = Map.get(socket.assigns.scopes_form, :uuid)

      case uuid && find_key(socket, uuid) do
        %{} = key ->
          case Map.get(socket.assigns.scopes_form, :mode) do
            :narrow -> narrow_scopes(socket, key, form["scopes"])
            _manage -> save_scopes(socket, key, string_list(form["scopes"]))
          end

        _ ->
          socket
          |> assign(:scopes_form, %{show: false})
          |> put_flash(:error, gettext("That key was not found."))
      end
    end)
  end

  # ── Limits and advanced ────────────────────────────────────────────

  def handle_event("save_limits", %{"limits" => params}, socket) when is_map(params) do
    with_access(socket, fn socket -> save_limits(socket, normalize_limit_params(params)) end)
  end

  # ── Service users ──────────────────────────────────────────────────

  def handle_event("open_service_user_form", _params, socket) do
    with_access(socket, fn socket ->
      socket
      |> assign(:service_user_params, default_service_user_params())
      |> assign(:service_user_errors, [])
      |> assign(:show_service_user_form, true)
    end)
  end

  def handle_event("close_service_user_form", _params, socket) do
    {:noreply, close_service_user_form(socket)}
  end

  def handle_event("create_service_user", %{"service_user" => params}, socket)
      when is_map(params) do
    with_access(socket, fn socket ->
      create_service_user(socket, normalize_service_user_params(params))
    end)
  end

  # ── Confirmation, approvals and repeats ────────────────────────────

  def handle_event("save_flow", %{"flow" => params}, socket) when is_map(params) do
    with_access(socket, fn socket -> save_flow(socket, normalize_flow_params(params)) end)
  end

  def handle_event("save_personal_keys", %{"personal_keys" => params}, socket)
      when is_map(params) do
    with_access(socket, fn socket ->
      save_personal_keys(socket, normalize_personal_keys_params(params))
    end)
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("That action is not available."))}
  end

  # ── Access ─────────────────────────────────────────────────────────

  # Every event that changes something goes through here. The scope the socket
  # got at mount can be stale (a role changed since, and core's PubSub refresh
  # was not handled yet or never arrived), so the person's rights are read again
  # for THIS event. The fresh scope is kept in `:api_scope` and is the one the
  # context calls receive; they check again on their own.
  defp with_access(socket, fun) do
    case fresh_scope(socket) do
      {:ok, fresh} ->
        {:noreply, fun.(assign(socket, :api_scope, fresh))}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  # The user is loaded again and must still be active; the scope captured at
  # mount (which may be narrowed to one active role) and a scope built now (all
  # held roles, as the API computes it) must both hold `api`.
  defp fresh_scope(socket), do: Access.fresh_scope(socket.assigns.phoenix_kit_current_scope)

  defp scope(socket), do: socket.assigns.api_scope

  # A token that has not been dismissed is the only copy there is: nothing may
  # start another one (or reopen the form that would) until it is stored.
  defp token_pending?(socket), do: socket.assigns.new_token != nil

  defp refuse(socket), do: put_flash(socket, :error, gettext("That action is not available."))

  defp history(socket), do: [actor_uuid: Actor.uuid(socket), source: "settings"]

  # ── State ──────────────────────────────────────────────────────────

  # `statuses: :keep` reuses the owners' rights read earlier, for an event that changes no
  # owner's rights (a switch). Reading them costs a permission check per owner of a live
  # personal key, so everything else reads them again, once per reload.
  defp assign_state(socket, opts \\ []) do
    scope = scope(socket)
    keys = Keys.list_keys(scope)
    service_users = ServiceUsers.list(scope)

    socket
    |> assign(:admin_enabled, Config.admin_enabled?())
    |> assign(:public_enabled, Config.public_enabled?())
    |> assign_api_modules()
    |> assign(:keys, keys)
    |> assign(:service_users, service_users)
    |> assign(:pending_approvals, Approvals.pending_count(scope))
    |> assign(:allowed_roles, ServiceUsers.allowed_roles(scope))
    |> assign(:owner_labels, owner_labels(keys, service_users, scope))
    |> assign(:key_counts, Enum.frequencies_by(keys, & &1.user_uuid))
    |> assign_personal_statuses(keys, opts[:statuses])
    |> assign(:key_access, key_access(scope, keys))
  end

  # The owners' rights are the costly part: a `statuses: :keep` event reuses the ones read
  # before and reads only an owner that is new. Each key's status is computed from the key
  # list just read, so a key made or ended in the meantime shows its real status.
  defp assign_personal_statuses(socket, keys, mode) do
    known = if mode == :keep, do: socket.assigns[:personal_owner_states] || %{}, else: %{}
    owners = PersonalKeyDisplay.owner_states(keys, known)

    socket
    |> assign(:personal_owner_states, owners)
    |> assign(:personal_statuses, PersonalKeyDisplay.statuses(keys, owners))
  end

  # Only this module's key changes; keys of modules that are not installed stay listed. The
  # list is read from the database under a row lock inside the write, not from the settings
  # cache, so another admin's change (or a stale cache on this node) is never overwritten.
  defp set_module_api(socket, %{key: key} = mod, on?) do
    change = fn stored ->
      listed = Config.parse_list(stored)
      wanted = if(on?, do: List.delete(listed, key), else: Enum.uniq(listed ++ [key]))
      if wanted == listed, do: :unchanged, else: Config.encode_list(wanted)
    end

    case Settings.modify_setting_with_module(
           "api_disabled_modules",
           "api",
           change,
           history(socket)
         ) do
      {:ok, _setting} ->
        socket |> assign_state(statuses: :keep) |> put_flash(:info, module_api_saved(mod, on?))

      {:error, _changeset} ->
        put_flash(socket, :error, gettext("The switch could not be saved."))
    end
  end

  # Like `set_module_api/3`: only this module's key changes, read under a row lock.
  defp set_module_session_write(socket, %{key: key} = mod, on?) do
    change = fn stored ->
      listed = Config.parse_list(stored)
      wanted = if(on?, do: Enum.uniq(listed ++ [key]), else: List.delete(listed, key))
      if wanted == listed, do: :unchanged, else: Config.encode_list(wanted)
    end

    case Settings.modify_setting_with_module(
           "api_session_write_modules",
           "api",
           change,
           history(socket)
         ) do
      {:ok, _setting} ->
        socket |> assign_state(statuses: :keep) |> put_flash(:info, session_write_saved(mod, on?))

      {:error, _changeset} ->
        put_flash(socket, :error, gettext("The switch could not be saved."))
    end
  end

  defp session_write_saved(mod, true),
    do: gettext("The agent may act in %{module}.", module: module_label(mod))

  defp session_write_saved(mod, false),
    do: gettext("The agent may no longer act in %{module}.", module: module_label(mod))

  defp module_api_saved(mod, true),
    do: gettext("The API of %{module} is on.", module: module_label(mod))

  defp module_api_saved(mod, false),
    do: gettext("The API of %{module} is off.", module: module_label(mod))

  @doc false
  # A module's name, translated: by the gettext backend the module declares in its
  # `permission_metadata/0` (the one the permissions matrix uses for its label), then by
  # core's own catalogue. A module without a backend reads as before. A module of
  # `api_modules/0` already carries its `:label`; resolving one asks every module for its
  # metadata, which the template must not repeat for each row and aria-label of a render.
  def module_label(%{label: label}) when is_binary(label), do: label
  def module_label(mod), do: label_in(ModuleRegistry.permission_gettext(), mod)

  defp label_in(backends, %{key: key, name: name}) do
    with {backend, domain} <- Map.get(backends, key),
         translated when translated != name <- Gettext.dgettext(backend, domain, name) do
      translated
    else
      _ -> Gettext.gettext(PhoenixKitWeb.Gettext, name)
    end
  end

  # The modules with tools, whether their API is on right now and whether the agent may act
  # in them (`api_session_write_modules`).
  defp api_modules do
    disabled = Config.disabled_modules()
    writes = Config.session_write_modules()
    backends = ModuleRegistry.permission_gettext()

    Enum.map(ModuleRegistry.api_modules(), fn mod ->
      mod
      |> Map.put(:api_on?, mod.key not in disabled)
      |> Map.put(:session_write?, mod.key in writes)
      |> Map.put(:label, label_in(backends, mod))
    end)
  end

  # The card's modules, each with its admin tools as an assistant in a person's live session
  # finds them by the install's settings alone (`Executor.tool_availability/1` without a
  # scope): the rights of each person are checked on top of that.
  defp assign_api_modules(socket) do
    tools = Enum.group_by(Executor.tool_availability(), & &1.module_key)

    assign(
      socket,
      :api_modules,
      Enum.map(api_modules(), &Map.put(&1, :assistant_tools, Map.get(tools, &1.key, [])))
    )
  end

  defp available_count(tools), do: Enum.count(tools, &(&1.status == :available))

  defp closed_reasons(%{status: {:closed, reasons}}), do: reasons
  defp closed_reasons(%{status: :available}), do: []

  defp closed_reason_text(:module_disabled), do: gettext("The module is switched off.")
  defp closed_reason_text(:api_off), do: gettext("The module's API is off.")

  defp closed_reason_text(:tool_hidden),
    do: gettext("The tool is hidden in “Limits and advanced”.")

  defp closed_reason_text(:agent_writes_off),
    do: gettext("It writes, and “Agent may act” is off.")

  # A reason this page does not name (a later addition) still renders.
  defp closed_reason_text(_other), do: gettext("Closed")

  defp switch_on?("admin"), do: Config.admin_enabled?()
  defp switch_on?("public"), do: Config.public_enabled?()

  defp switch_text("admin"), do: gettext("The admin API setting was saved.")
  defp switch_text("public"), do: gettext("The public API setting was saved.")

  # The names shown in the Owner column. A key's owner is the person who created
  # it, or a service user; an Owner also sees keys of other people, which cost
  # one lookup per distinct owner.
  defp owner_labels(keys, service_users, scope) do
    known = Map.new([scope.user | service_users], &{&1.uuid, &1})

    keys
    |> Enum.map(& &1.user_uuid)
    |> Enum.uniq()
    |> Map.new(fn uuid ->
      {uuid, user_label(Map.get(known, uuid) || Auth.get_user(uuid))}
    end)
  end

  defp user_label(nil), do: gettext("Deleted user")

  defp user_label(user) do
    Enum.find([user.first_name, user.username], &present?/1) || user.email
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp find_key(socket, uuid) do
    Enum.find(Keys.list_keys(scope(socket)), &(&1.uuid == uuid))
  end

  # ── Create-key form ────────────────────────────────────────────────

  defp default_key_params do
    %{
      "name" => "",
      "owner" => "self",
      "scopes" => [],
      "allowed_ips" => "",
      "expires_on" => "",
      "requires_approval" => false
    }
  end

  # Only the five fields of the form survive; each has the type the code below
  # expects, whatever the client sent.
  defp normalize_key_params(params) do
    %{
      "name" => text(params["name"], ""),
      "owner" => text(params["owner"], "self"),
      "scopes" => string_list(params["scopes"]),
      "allowed_ips" => text(params["allowed_ips"], ""),
      "expires_on" => text(params["expires_on"], ""),
      "requires_approval" => params["requires_approval"] in ["true", "on", true]
    }
  end

  defp text(value, _default) when is_binary(value), do: value
  defp text(_value, default), do: default

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  # Shows the form with `params`, and the scopes the chosen owner could be given.
  defp assign_key_form(socket, params) do
    scopes =
      case resolve_owner(socket, params["owner"]) do
        {:ok, owner} -> Keys.allowed_scopes_for(owner)
        {:error, _reason} -> []
      end

    socket
    |> assign(:show_key_form, true)
    |> assign(:key_params, params)
    |> assign(:scope_options, scopes)
    |> assign(:scope_tools, scope_tools(scopes))
  end

  defp close_key_form(socket) do
    socket
    |> assign(:show_key_form, false)
    |> assign(:key_params, default_key_params())
    |> assign(:key_errors, [])
  end

  # Scope -> names of the tools it unlocks, for the hint under each checkbox.
  defp scope_tools(scopes) do
    Registry.all_tools()
    |> Enum.filter(&(&1.audience == :admin and &1.scope in scopes))
    |> Enum.group_by(& &1.scope, & &1.name)
  end

  # The owner comes from the server, never from the client's word: "self" is the
  # person acting; any other value must be a service user from the list the person
  # may use, which is read again here.
  defp resolve_owner(socket, "self"), do: {:ok, scope(socket).user}

  defp resolve_owner(socket, uuid) do
    case Enum.find(ServiceUsers.list(scope(socket)), &(&1.uuid == uuid)) do
      nil -> {:error, :owner_not_allowed}
      user -> {:ok, user}
    end
  end

  defp owner_options(service_users) do
    [{gettext("Me"), "self"} | Enum.map(service_users, &{user_label(&1), &1.uuid})]
  end

  defp create_key(socket, params) do
    with {:ok, owner} <- resolve_owner(socket, params["owner"]),
         :ok <- check_scopes(params["scopes"], Keys.allowed_scopes_for(owner)),
         {:ok, expires_at} <- parse_expiry(params["expires_on"]),
         {:ok, key, token} <- Keys.create_key(owner, scope(socket), key_attrs(params, expires_at)) do
      socket
      |> close_key_form()
      |> assign(:new_token, %DisplayToken{value: token})
      |> assign(:new_token_name, key.name)
      |> assign_state()
    else
      {:error, reason} ->
        socket
        |> assign_key_form(params)
        |> assign(:key_errors, error_messages(reason))
    end
  end

  defp check_scopes(requested, allowed) do
    if Enum.all?(requested, &(&1 in allowed)), do: :ok, else: {:error, :scope_not_allowed}
  end

  defp parse_expiry(""), do: {:ok, nil}

  defp parse_expiry(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         :gt <- Date.compare(Date.add(date, 1), Date.utc_today()) do
      {:ok, DateTime.new!(date, ~T[23:59:59], "Etc/UTC")}
    else
      _ -> {:error, :bad_expiry}
    end
  end

  defp key_attrs(params, expires_at) do
    %{
      "name" => String.trim(params["name"]),
      "scopes" => params["scopes"],
      "allowed_ips" => String.split(params["allowed_ips"], ~r/[\s,;]+/, trim: true),
      "expires_at" => expires_at,
      "requires_approval" => params["requires_approval"]
    }
  end

  defp error_messages(:owner_not_allowed),
    do: [gettext("You cannot create keys for that owner.")]

  defp error_messages(reason) when reason in [:scope_not_allowed, :invalid_scopes],
    do: [gettext("Some of the chosen scopes are not available to that owner.")]

  defp error_messages(:bad_expiry),
    do: [gettext("The expiry date must be a date from today on.")]

  defp error_messages(:forbidden),
    do: [gettext("You are not allowed to do that.")]

  defp error_messages(:role_not_allowed),
    do: [gettext("You cannot give a role that holds more rights than you do.")]

  defp error_messages(:scopes_not_narrowing),
    do: [gettext("You can only remove scopes from a personal key, not add any.")]

  defp error_messages(:impersonation_unknown),
    do: [gettext("This session cannot tell whether you act in another account.")]

  defp error_messages(:impersonated),
    do: [gettext("Personal keys cannot be rotated while you act in another account.")]

  defp error_messages(:personal_key_limit),
    do: [
      gettext(
        "You already have the largest number of keys allowed, so the old key cannot keep working next to the new one. Rotate with a grace period of 0, or revoke a key first."
      )
    ]

  defp error_messages(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
  end

  defp error_messages(_other), do: [gettext("That could not be saved.")]

  # ── Revoke ─────────────────────────────────────────────────────────

  defp revoke_key(socket, key) do
    case Keys.revoke(key, Actor.uuid(socket)) do
      {:ok, _key} ->
        socket
        |> assign_state()
        |> put_flash(:info, gettext("The key was revoked. It stops working at once."))

      {:error, _reason} ->
        put_flash(socket, :error, gettext("The key could not be revoked."))
    end
  end

  # ── Rotate ─────────────────────────────────────────────────────────

  defp rotate_key(socket, nil, _hours) do
    socket
    |> assign(:rotate_form, %{show: false})
    |> put_flash(:error, gettext("That key was not found."))
  end

  defp rotate_key(socket, key, hours) do
    with :ok <- check_manageable(socket, key),
         {:ok, grace} <- parse_grace(hours),
         {:ok, new_key, token} <-
           Keys.rotate(key, grace, scope(socket), impersonated: socket.assigns.impersonated) do
      socket
      |> assign(:rotate_form, %{show: false})
      |> assign(:new_token, %DisplayToken{value: token})
      |> assign(:new_token_name, new_key.name)
      |> assign_state()
    else
      {:error, :bad_grace} ->
        assign(socket, :rotate_form, Map.put(socket.assigns.rotate_form, :error, true))

      {:error, reason} ->
        socket
        |> assign(:rotate_form, %{show: false})
        |> put_flash(:error, rotate_error(reason))
    end
  end

  # At the cap a personal key's rotation keeps no overlap, so the dialog starts at 0 hours.
  defp at_personal_limit?(socket, key),
    do: key.personal and Keys.personal_keys_full?(scope(socket))

  defp check_manageable(socket, key),
    do: if(Keys.can_manage?(scope(socket), key), do: :ok, else: {:error, :forbidden})

  defp rotate_error(reason)
       when reason in [:impersonated, :impersonation_unknown, :personal_key_limit],
       do: reason |> error_messages() |> hd()

  defp rotate_error(_reason), do: gettext("The key could not be rotated.")

  # 0 to 24 whole hours; anything else is refused, not clamped.
  defp parse_grace(hours) do
    case Integer.parse(String.trim(hours)) do
      {grace, ""} when grace in 0..24 -> {:ok, grace}
      _ -> {:error, :bad_grace}
    end
  end

  defp grace_options, do: Enum.map(0..24, &{Integer.to_string(&1), Integer.to_string(&1)})

  # ── Edit scopes ────────────────────────────────────────────────────

  # The scopes offered are those the key's owner could use NOW. The ones the key
  # holds that the owner cannot use right now are listed as inactive and stay on
  # the key when it is saved (Keys.update_scopes/3 merges them back).
  defp open_scopes_form(socket, key) do
    options =
      case key_owner(key) do
        {:ok, owner} -> editable_scopes(socket, key, owner)
        {:error, _reason} -> []
      end

    assign(socket, :scopes_form, %{
      show: true,
      uuid: key.uuid,
      name: key.name,
      options: options,
      selected: Enum.filter(key.scopes, &(&1 in options)),
      inactive: Enum.reject(key.scopes, &(&1 in options)),
      tools: scope_tools(options),
      errors: []
    })
  end

  # An Owner on someone else's personal key may only take scopes off it. Every scope the
  # key holds is offered, ticked, the ones its owner cannot use right now marked inactive.
  defp narrowing_only?(socket, key),
    do:
      key.personal and Keys.can_revoke?(scope(socket), key) and
        not Keys.can_manage?(scope(socket), key)

  defp open_narrow_form(socket, key) do
    usable =
      with {:ok, _owner} <- Keys.active_owner(key),
           {:ok, owner} <- key_owner(key) do
        Keys.allowed_scopes_for(owner)
      else
        _unusable -> []
      end

    assign(socket, :scopes_form, %{
      show: true,
      mode: :narrow,
      uuid: key.uuid,
      name: key.name,
      options: key.scopes,
      selected: key.scopes,
      inactive: Enum.reject(key.scopes, &(&1 in usable)),
      tools: scope_tools(key.scopes),
      errors: []
    })
  end

  # Nothing ticked sends no field; anything but a list of strings is forged and refused
  # (it must not read as "remove every scope").
  defp narrow_scopes(socket, key, raw) when is_nil(raw) or is_list(raw) do
    if Enum.all?(raw || [], &is_binary/1),
      do: narrow_scopes_checked(socket, key, raw || []),
      else: narrow_refused(socket)
  end

  defp narrow_scopes(socket, _key, _raw), do: narrow_refused(socket)

  defp narrow_refused(socket) do
    assign(
      socket,
      :scopes_form,
      Map.put(socket.assigns.scopes_form, :errors, error_messages(:invalid_scopes))
    )
  end

  defp check_narrowing_only(socket, key),
    do: if(narrowing_only?(socket, key), do: :ok, else: {:error, :forbidden})

  defp check_only_removing(scopes, key),
    do: if(Enum.all?(scopes, &(&1 in key.scopes)), do: :ok, else: {:error, :scopes_not_narrowing})

  defp narrow_scopes_checked(socket, key, scopes) do
    with :ok <- check_narrowing_only(socket, key),
         :ok <- check_only_removing(scopes, key),
         {:ok, _key} <- Keys.update_scopes(key, scopes, scope(socket)) do
      socket
      |> assign(:scopes_form, %{show: false})
      |> assign_state()
      |> put_flash(:info, gettext("The scopes were saved."))
    else
      {:error, reason} when reason in [:revoked, :not_found] ->
        socket
        |> assign(:scopes_form, %{show: false})
        |> put_flash(:error, gettext("That key was not found."))

      {:error, reason} ->
        assign(
          socket,
          :scopes_form,
          Map.merge(socket.assigns.scopes_form, %{
            selected: scopes,
            errors: error_messages(reason)
          })
        )
    end
  end

  defp save_scopes(socket, key, scopes) do
    with {:ok, owner} <- key_owner(key),
         :ok <- check_scopes(scopes, editable_scopes(socket, key, owner)),
         {:ok, _key} <- Keys.update_scopes(key, scopes, scope(socket)) do
      socket
      |> assign(:scopes_form, %{show: false})
      |> assign_state()
      |> put_flash(:info, gettext("The scopes were saved."))
    else
      {:error, reason} when reason in [:revoked, :not_found] ->
        socket
        |> assign(:scopes_form, %{show: false})
        |> put_flash(:error, gettext("That key was not found."))

      {:error, reason} ->
        assign(
          socket,
          :scopes_form,
          Map.merge(socket.assigns.scopes_form, %{
            selected: scopes,
            errors: error_messages(reason)
          })
        )
    end
  end

  # What the form offers and accepts for a key: the scopes the key's owner can
  # use and the person editing may add (they hold the tools' permissions too),
  # and the ones already on the key, which may stay or go.
  defp editable_scopes(socket, key, owner) do
    addable = Keys.allowed_scopes_for(owner, scope(socket))
    Enum.filter(Keys.allowed_scopes_for(owner), &(&1 in addable or &1 in key.scopes))
  end

  defp key_owner(key) do
    case Auth.get_user(key.user_uuid) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  # ── Limits and advanced ────────────────────────────────────────────

  # The form as it stands now: the current settings, as the text the fields show.
  defp assign_limits(socket) do
    limits = Config.rate_limits()

    params =
      Enum.reduce(
        @limit_fields,
        %{
          "disabled_tools" => Config.encode_list(Config.disabled_tools()),
          "mcp_allowed_origins" => Config.encode_list(Config.mcp_allowed_origins())
        },
        fn {field, _setting, name}, acc ->
          Map.put(acc, field, Integer.to_string(Map.fetch!(limits, name)))
        end
      )

    socket |> assign(:limits_params, params) |> assign(:limits_errors, [])
  end

  # Only the eight fields of the form survive, each a string.
  defp normalize_limit_params(params) do
    Enum.reduce(
      @limit_fields,
      %{
        "disabled_tools" => text(params["disabled_tools"], ""),
        "mcp_allowed_origins" => text(params["mcp_allowed_origins"], "")
      },
      fn {field, _setting, _name}, acc -> Map.put(acc, field, text(params[field], "")) end
    )
  end

  # All or nothing: validate every field, then write only what changed.
  defp save_limits(socket, params) do
    case validate_limits(params) do
      {:ok, wanted} ->
        write_limits(socket, wanted)

      {:error, messages} ->
        socket |> assign(:limits_params, params) |> assign(:limits_errors, messages)
    end
  end

  defp validate_limits(params) do
    tools = Config.parse_list(params["disabled_tools"])
    origins = Config.parse_list(params["mcp_allowed_origins"])

    numbers =
      Enum.map(@limit_fields, fn {field, setting, name} ->
        {setting, name, parse_limit(params[field])}
      end)

    errors =
      Enum.reject(
        [
          if(Enum.all?(tools, &tool_name?/1),
            do: nil,
            else:
              gettext(
                "Tool names look like catalogue.list_categories: lowercase words with underscores, a dot between the two parts."
              )
          ),
          if(Enum.all?(origins, &origin?/1),
            do: nil,
            else:
              gettext(
                "Origins look like https://example.com: a scheme and a host, without a path."
              )
          ),
          if(Enum.all?(numbers, fn {_setting, _name, parsed} -> parsed != :error end),
            do: nil,
            else: gettext("Every limit must be a whole number from 1 to 1000000.")
          )
        ],
        &is_nil/1
      )

    if errors == [] do
      {:ok,
       %{
         tools: tools,
         origins: origins,
         numbers: for({setting, name, {:ok, number}} <- numbers, do: {setting, name, number})
       }}
    else
      {:error, errors}
    end
  end

  defp parse_limit(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number in 1..1_000_000 -> {:ok, number}
      _ -> :error
    end
  end

  defp tool_name?(name) do
    String.length(name) <= 100 and Regex.match?(~r/\A[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\z/, name)
  end

  # An origin is a scheme and a host (and maybe a port): no path, query or login.
  defp origin?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, ""] ->
        String.length(value) <= 255 and not String.contains?(value, [" ", "\t"])

      _other ->
        false
    end
  end

  defp write_limits(socket, wanted) do
    stored = Config.rate_limits()

    # A number is written when it differs from what is in effect.
    number_changes =
      Enum.map(wanted.numbers, fn {setting, name, number} ->
        {setting, Integer.to_string(number), number != Map.fetch!(stored, name)}
      end)

    list_changes = [
      {"api_disabled_tools", Config.encode_list(wanted.tools),
       wanted.tools != Config.disabled_tools()},
      {"api_mcp_allowed_origins", Config.encode_list(wanted.origins),
       wanted.origins != Config.mcp_allowed_origins()}
    ]

    changes =
      Enum.filter(list_changes ++ number_changes, fn {_setting, _value, changed?} -> changed? end)

    results =
      Enum.map(changes, fn {setting, value, _changed?} ->
        Settings.update_setting_with_module(setting, value, "api", history(socket))
      end)

    # A hidden tool is closed to the assistant too: the modules' tool lists follow.
    socket = socket |> assign_limits() |> assign_api_modules()

    if Enum.all?(results, &match?({:ok, _setting}, &1)) do
      put_flash(socket, :info, gettext("The limits were saved."))
    else
      assign(socket, :limits_errors, [gettext("The limits could not be saved.")])
    end
  end

  # ── Service users ──────────────────────────────────────────────────

  # ── Confirmation, approvals and repeats ────────────────────────────

  defp assign_flow(socket) do
    socket |> assign(:flow_params, FlowConfig.current()) |> assign(:flow_errors, [])
  end

  # Only the fields of the form survive, each a string.
  defp normalize_flow_params(params) do
    Map.new(FlowConfig.fields(), fn %{field: field} -> {field, text(params[field], "")} end)
  end

  # All or nothing, like the limits form: `FlowConfig.save/2` validates every field first.
  defp save_flow(socket, params) do
    case FlowConfig.save(params, history(socket)) do
      {:ok, _changed} ->
        socket |> assign_flow() |> put_flash(:info, gettext("The settings were saved."))

      {:error, :save_failed} ->
        socket
        |> assign(:flow_params, params)
        |> assign(:flow_errors, [gettext("The settings could not be saved.")])

      {:error, fields} when is_list(fields) ->
        socket
        |> assign(:flow_params, params)
        |> assign(:flow_errors, [gettext("Every value must be a whole number inside its range.")])
    end
  end

  defp assign_personal_keys(socket) do
    socket
    |> assign(:personal_keys_params, PersonalKeysConfig.current())
    |> assign(:personal_keys_errors, [])
  end

  # Only the fields of the form survive, each a string.
  defp normalize_personal_keys_params(params) do
    Map.new(PersonalKeysConfig.fields(), fn %{field: field} ->
      {field, text(params[field], "")}
    end)
  end

  defp save_personal_keys(socket, params) do
    case PersonalKeysConfig.save(params, history(socket)) do
      {:ok, _changed} ->
        socket |> assign_personal_keys() |> put_flash(:info, gettext("The settings were saved."))

      {:error, :save_failed} ->
        socket
        |> assign(:personal_keys_params, params)
        |> assign(:personal_keys_errors, [gettext("The settings could not be saved.")])

      {:error, fields} when is_list(fields) ->
        socket
        |> assign(:personal_keys_params, params)
        |> assign(:personal_keys_errors, [
          gettext("Every value must be a whole number inside its range.")
        ])
    end
  end

  defp default_service_user_params, do: %{"name" => "", "roles" => []}

  defp normalize_service_user_params(params) do
    %{"name" => text(params["name"], ""), "roles" => string_list(params["roles"])}
  end

  defp close_service_user_form(socket) do
    socket
    |> assign(:show_service_user_form, false)
    |> assign(:service_user_params, default_service_user_params())
    |> assign(:service_user_errors, [])
  end

  defp create_service_user(socket, params) do
    case ServiceUsers.create(scope(socket), service_user_attrs(params)) do
      {:ok, _user} ->
        socket
        |> close_service_user_form()
        |> assign_state()
        |> put_flash(:info, gettext("The service user was created. You can give it keys now."))

      {:error, reason} ->
        socket
        |> assign(:show_service_user_form, true)
        |> assign(:service_user_params, params)
        |> assign(:service_user_errors, error_messages(reason))
    end
  end

  defp service_user_attrs(%{"name" => name, "roles" => roles}) do
    case String.trim(name) do
      "" -> %{roles: roles}
      name -> %{name: name, roles: roles}
    end
  end

  # ── Template helpers ───────────────────────────────────────────────

  @doc """
  What a key is doing right now, as one of `:active`, `:ending`, `:expired` or
  `:revoked`.

  `:ending` is a key that still works but has an end in the future: a planned
  expiry, or the grace period of a rotation (rotation sets `revoked_at` ahead of
  time).
  """
  @spec key_status(map(), DateTime.t()) :: :active | :ending | :expired | :revoked
  def key_status(key, now \\ DateTime.utc_now()) do
    cond do
      reached?(key.revoked_at, now) -> :revoked
      reached?(key.expires_at, now) -> :expired
      key.revoked_at || key.expires_at -> :ending
      true -> :active
    end
  end

  defp reached?(nil, _now), do: false
  defp reached?(%DateTime{} = at, now), do: DateTime.compare(at, now) != :gt

  defp status_label(:active), do: gettext("Active")
  defp status_label(:ending), do: gettext("Ending")
  defp status_label(:expired), do: gettext("Expired")
  defp status_label(:revoked), do: gettext("Revoked")

  # The earliest moment the key stops working, if it has one.
  defp ends_at(key) do
    [key.revoked_at, key.expires_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp live?(key), do: key_status(key) in [:active, :ending]

  # What the keys table may offer for each key: `:manage` (edit scopes, rotate, revoke),
  # `:narrow` (an Owner on someone else's personal key: remove scopes, revoke), or `:none`.
  defp key_access(scope, keys) do
    Map.new(keys, fn key ->
      access =
        cond do
          Keys.can_manage?(scope, key) -> :manage
          key.personal and Keys.can_revoke?(scope, key) -> :narrow
          true -> :none
        end

      {key.uuid, access}
    end)
  end
end
