defmodule PhoenixKitWeb.Live.Components.PersonalApiKeys do
  @moduledoc """
  "My API keys": the personal API keys of the signed-in person (create, edit the scopes,
  rotate, revoke), as one LiveComponent used by the profile page
  (`PhoenixKitWeb.Live.Users.MyApiKeys`) and by the `:api_keys` section of
  `PhoenixKitWeb.Live.Components.UserSettings`. Both get the same rules from this module.

  ## Contract

  Required assigns:

    * `id` — unique component id
    * `scope` — the session's `PhoenixKit.Users.Auth.Scope` (`@phoenix_kit_current_scope`)
    * `impersonated` — a boolean: whether the session is borrowed. The host page computes it
      in its `mount/3` with `PhoenixKitWeb.Users.MultiSession.impersonated?(session)`, never
      as a constant. It is also true for a person's own second account (a deliberate
      over-caution: the session cannot tell the two apart).

  A component without a usable `scope` (a `%Scope{}` with a user) or without a boolean
  `impersonated` shows one explanation and nothing else: no list, and every event is
  refused. A person who holds neither `api_personal_keys` nor `api` sees an explanation too.

  ## Borrowed session

  When `impersonated` is true the component only lists the keys and says why it does not
  change them. The refusal is on the server, for every event that changes something: a
  hidden button is not the control.

  ## Rights are checked on every event

  Each event that opens a dialog or changes something first checks the context (see above),
  that the session is not borrowed, and then re-reads the person's rights from the database
  (`PhoenixKit.API.Access.fresh_scope/2` with `["api_personal_keys", "api"]`): the scope
  captured at mount can be stale. A key to rotate, edit or revoke is found only in
  `PhoenixKit.API.Keys.list_personal_keys/1` of that fresh scope; for the confirming events
  its uuid is the one the server stored when the dialog opened, never a param. The fresh
  scope and the session's `impersonated` go to `PhoenixKit.API.Keys`, which checks again.

  The create form has no "needs approval" field and the params are cut down to the fields
  of the form, so a forged `requires_approval` never reaches the key.

  While the machine API for admins is switched off (`PhoenixKit.API.Config.admin_enabled?/0`)
  the list stays and a key can still be revoked or have its scopes edited, but no key is
  created or rotated. The switch is read again for each event, not taken from the last render.

  ## At the limit

  A person never has more than `PhoenixKit.API.PersonalKeysConfig.max_count/0` live personal
  keys, and a rotation with a grace period keeps the old key alive next to the new one. When
  the person is already at the limit (`PhoenixKit.API.Keys.personal_keys_full?/1`) the rotate
  dialog starts at a grace period of 0 and says why, and `Keys.rotate/4` refuses a longer one
  with `:personal_key_limit`.

  ## The new key is shown once, and only here

  The token of a new or rotated key lives in one assign, `:new_token` (a
  `PhoenixKit.API.Keys.DisplayToken`), until "I have stored the key" clears it. It is never
  in a flash, a URL, a `phx-value-*`, a form field with a name or a log line. While it waits,
  no other key is created or rotated, so a replayed event cannot mint a second key.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.API.Access
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.DisplayToken
  alias PhoenixKit.API.Paths
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.API.Registry
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.PersonalKeyDisplay

  @permissions ["api_personal_keys", "api"]

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, Map.get(assigns, :scope, socket.assigns[:scope]))
      |> assign(:impersonated, Map.get(assigns, :impersonated, socket.assigns[:impersonated]))
      |> assign_new(:new_token, fn -> nil end)
      |> assign_new(:new_token_name, fn -> nil end)
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:create_form, fn -> closed_create_form() end)
      |> assign_new(:rotate_form, fn -> %{show: false} end)
      |> assign_new(:scopes_form, fn -> %{show: false} end)
      |> assign_new(:revoke_confirmation, fn -> %{show: false} end)

    socket = socket |> assign_mode() |> assign_connect()
    {:ok, assign_state(socket, socket.assigns.scope)}
  end

  # Computed once per component: the REST and MCP addresses of the admin API.
  defp connect_info do
    base = Routes.base_url()

    %{
      rest: base <> Routes.path(Paths.rest_path(:admin)),
      mcp: base <> Routes.path(Paths.mcp_path(:admin))
    }
  end

  # Only the section that lists keys shows the addresses.
  defp assign_connect(%{assigns: %{mode: :ok}} = socket),
    do: assign_new(socket, :connect, &connect_info/0)

  defp assign_connect(socket), do: socket

  # :no_context -> only an explanation; :no_right -> an explanation; :ok -> the section.
  defp assign_mode(socket) do
    %{scope: scope, impersonated: impersonated} = socket.assigns

    mode =
      cond do
        not context?(scope, impersonated) -> :no_context
        not holds_any?(scope) -> :no_right
        true -> :ok
      end

    assign(socket, :mode, mode)
  end

  defp context?(%Scope{user: %User{}}, impersonated) when is_boolean(impersonated), do: true
  defp context?(_scope, _impersonated), do: false

  defp holds_any?(scope), do: Enum.any?(@permissions, &Scope.can?(scope, &1))

  # Lists with `scope`: the session's on mount and update, the fresh one after an event.
  defp assign_state(%{assigns: %{mode: :ok}} = socket, scope) do
    keys = Keys.list_personal_keys(scope)

    socket
    |> assign(:keys, keys)
    |> assign(:key_statuses, PersonalKeyDisplay.statuses(keys))
    |> assign(:key_tools, scope_tools(keys |> Enum.flat_map(& &1.scopes) |> Enum.uniq()))
    |> assign(:max_expiry, max_expiry_date())
    |> assign(:admin_enabled, Config.admin_enabled?())
    |> assign(:holds_api, Scope.can?(scope, "api"))
    |> assign(:max_count, PersonalKeysConfig.max_count())
    |> assign(:live_count, Enum.count(keys, &live?/1))
  end

  defp assign_state(socket, _scope) do
    socket
    |> assign(:keys, [])
    |> assign(:key_statuses, %{})
    |> assign(:key_tools, %{})
    |> assign(:admin_enabled, true)
    |> assign(:holds_api, false)
    |> assign(:max_count, 0)
    |> assign(:live_count, 0)
    |> assign(:max_expiry, nil)
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_create", _params, socket) do
    with_access(
      socket,
      fn socket ->
        cond do
          token_pending?(socket) ->
            refuse(socket)

          not socket.assigns.admin_enabled ->
            deny(socket, gettext("The API is switched off by an administrator."))

          true ->
            assign_create_form(socket, default_key_params(), [])
        end
      end,
      clear_message: true
    )
  end

  def handle_event("close_create", _params, socket) do
    {:noreply, assign(socket, :create_form, closed_create_form())}
  end

  # Only from an open form: a forged change must not reopen a closed form.
  def handle_event("create_form_changed", %{"key" => params}, socket) when is_map(params) do
    with_access(
      socket,
      fn socket ->
        if socket.assigns.create_form.show,
          do: update_create_params(socket, normalize_key_params(params)),
          else: socket
      end,
      reload: false
    )
  end

  # Only from an open form, with the API on and no token waiting to be dismissed.
  def handle_event("create_key", %{"key" => params}, socket) when is_map(params) do
    with_access(socket, fn socket ->
      cond do
        not socket.assigns.create_form.show or token_pending?(socket) -> refuse(socket)
        not socket.assigns.admin_enabled -> refuse(socket)
        true -> create_key(socket, normalize_key_params(params))
      end
    end)
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, socket |> assign(:new_token, nil) |> assign(:new_token_name, nil)}
  end

  def handle_event("request_revoke", %{"uuid" => uuid}, socket) do
    with_access(
      socket,
      fn socket ->
        case find_key(socket, uuid) do
          %{} = key ->
            if Keys.can_revoke?(scope(socket), key) and live?(key),
              do:
                assign(socket, :revoke_confirmation, %{
                  show: true,
                  uuid: key.uuid,
                  name: key.name
                }),
              else: not_found(socket)

          nil ->
            not_found(socket)
        end
      end,
      clear_message: true
    )
  end

  def handle_event("cancel_revoke", _params, socket) do
    {:noreply, assign(socket, :revoke_confirmation, %{show: false})}
  end

  def handle_event("confirm_revoke", _params, socket) do
    with_access(socket, fn socket ->
      uuid = Map.get(socket.assigns.revoke_confirmation, :uuid)
      socket = assign(socket, :revoke_confirmation, %{show: false})

      case uuid && find_key(socket, uuid) do
        %{} = key -> revoke_key(socket, key)
        _ -> not_found(socket)
      end
    end)
  end

  def handle_event("request_rotate", %{"uuid" => uuid}, socket) do
    with_access(
      socket,
      fn socket ->
        case find_key(socket, uuid) do
          %{} = key ->
            cond do
              token_pending?(socket) ->
                refuse(socket)

              not socket.assigns.admin_enabled ->
                refuse(socket)

              being_replaced?(scope(socket), key) ->
                error(socket, rotate_error(:rotation_pending))

              not rotatable?(scope(socket), key) ->
                not_found(socket)

              true ->
                assign(socket, :rotate_form, %{
                  show: true,
                  uuid: key.uuid,
                  name: key.name,
                  at_limit: at_limit?(socket)
                })
            end

          nil ->
            not_found(socket)
        end
      end,
      clear_message: true
    )
  end

  def handle_event("cancel_rotate", _params, socket) do
    {:noreply, assign(socket, :rotate_form, %{show: false})}
  end

  def handle_event("confirm_rotate", %{"rotate" => %{"grace_hours" => hours}}, socket)
      when is_binary(hours) do
    with_access(socket, fn socket ->
      if token_pending?(socket) or not socket.assigns.admin_enabled do
        refuse(socket)
      else
        uuid = Map.get(socket.assigns.rotate_form, :uuid)
        rotate_key(socket, uuid && find_key(socket, uuid), hours)
      end
    end)
  end

  def handle_event("request_edit_scopes", %{"uuid" => uuid}, socket) do
    with_access(
      socket,
      fn socket ->
        case find_key(socket, uuid) do
          %{} = key ->
            if Keys.can_manage?(scope(socket), key) and live?(key),
              do: open_scopes_form(socket, key),
              else: not_found(socket)

          nil ->
            not_found(socket)
        end
      end,
      clear_message: true
    )
  end

  def handle_event("cancel_edit_scopes", _params, socket) do
    {:noreply, assign(socket, :scopes_form, %{show: false})}
  end

  def handle_event("save_key_scopes", %{"key_scopes" => %{"present" => "1"} = form}, socket) do
    with_access(socket, fn socket ->
      uuid = Map.get(socket.assigns.scopes_form, :uuid)

      case uuid && find_key(socket, uuid) do
        %{} = key ->
          save_scopes(socket, key, string_list(form["scopes"]))

        _ ->
          socket |> assign(:scopes_form, %{show: false}) |> not_found()
      end
    end)
  end

  def handle_event(_event, _params, socket) do
    {:noreply, assign(socket, :message, {:error, gettext("That action is not available.")})}
  end

  # ── Access ─────────────────────────────────────────────────────────

  # Every event that opens a dialog or changes something goes through here: the context
  # must be complete, the session must not be borrowed, and the person's rights are read
  # again for THIS event. The fresh scope is kept in `:fresh_scope` and is the one the
  # context calls receive.
  #
  # A refusal closes the open dialogs, or the message would stay behind the backdrop.
  # Options: `reload: false` keeps the list as it is (typing in the form), `clear_message:
  # true` drops the old message before a dialog opens.
  defp with_access(socket, fun, opts \\ []) do
    %{scope: scope, impersonated: impersonated} = socket.assigns

    cond do
      not context?(scope, impersonated) ->
        {:noreply, deny(socket, gettext("You are not allowed to do that."))}

      impersonated ->
        {:noreply,
         deny(socket, gettext("Keys cannot be changed while you act in another account."))}

      true ->
        case Access.fresh_scope(scope, @permissions) do
          {:ok, fresh} ->
            socket = assign(socket, :fresh_scope, fresh)
            # The switch is read again for this event, not taken from the last render.
            socket = assign(socket, :admin_enabled, Config.admin_enabled?())
            socket = if opts[:clear_message], do: assign(socket, :message, nil), else: socket
            socket = fun.(socket)
            {:noreply, if(opts[:reload] == false, do: socket, else: reload(socket))}

          :error ->
            {:noreply, deny(socket, gettext("You are not allowed to do that."))}
        end
    end
  end

  defp scope(socket), do: socket.assigns.fresh_scope

  # The list is read again after every event, with the fresh scope.
  defp reload(socket), do: assign_state(socket, scope(socket))

  defp token_pending?(socket), do: socket.assigns.new_token != nil

  defp refuse(socket), do: deny(socket, gettext("That action is not available."))

  defp deny(socket, text) do
    socket
    |> assign(:create_form, closed_create_form())
    |> assign(:rotate_form, %{show: false})
    |> assign(:scopes_form, %{show: false})
    |> assign(:revoke_confirmation, %{show: false})
    |> error(text)
  end

  defp not_found(socket), do: error(socket, gettext("That key was not found."))
  defp error(socket, text), do: assign(socket, :message, {:error, text})
  defp info(socket, text), do: assign(socket, :message, {:info, text})

  # The key is found only among the person's own personal keys, read now.
  defp find_key(socket, uuid) when is_binary(uuid) do
    Enum.find(Keys.list_personal_keys(scope(socket)), &(&1.uuid == uuid))
  end

  defp find_key(_socket, _uuid), do: nil

  defp live?(key), do: Keys.dead_reason(key) == nil

  # A key being rotated away already has its end set; it is not rotated twice.
  defp rotatable?(scope, key),
    do: Keys.can_manage?(scope, key) and live?(key) and is_nil(key.revoked_at)

  # At the cap a rotation keeps no overlap: the old key cannot stay alive next to the new
  # one, so the dialog starts at 0 hours and says why.
  defp at_limit?(socket), do: Keys.personal_keys_full?(scope(socket))

  defp being_replaced?(scope, key),
    do: Keys.can_manage?(scope, key) and live?(key) and not is_nil(key.revoked_at)

  # ── Create ─────────────────────────────────────────────────────────

  defp closed_create_form, do: %{show: false, params: default_key_params(), errors: []}

  defp default_key_params do
    %{
      "name" => "",
      "scopes" => [],
      "allowed_ips" => "",
      "expires_on" => Date.to_iso8601(max_expiry_date())
    }
  end

  defp max_expiry_date, do: Date.add(Date.utc_today(), PersonalKeysConfig.max_days())

  # Only the four fields of the form survive, each with the type the code expects.
  defp normalize_key_params(params) do
    %{
      "name" => text(params["name"]),
      "scopes" => string_list(params["scopes"]),
      "allowed_ips" => text(params["allowed_ips"]),
      "expires_on" => text(params["expires_on"])
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  defp assign_create_form(socket, params, errors) do
    options = Keys.allowed_scopes_for(scope(socket).user)

    assign(socket, :create_form, %{
      show: true,
      params: params,
      errors: errors,
      options: options,
      tools: scope_tools(options)
    })
  end

  # Typing keeps the options the form opened with: the rights are checked again on submit.
  defp update_create_params(socket, params),
    do: assign(socket, :create_form, %{socket.assigns.create_form | params: params, errors: []})

  defp create_key(socket, params) do
    allowed = Keys.allowed_scopes_for(scope(socket).user)

    with :ok <- check_scopes(params["scopes"], allowed),
         {:ok, expires_at} <- parse_expiry(params["expires_on"]),
         :ok <- check_ceiling(expires_at),
         {:ok, key, token} <-
           Keys.create_personal_key(scope(socket), key_attrs(params, expires_at),
             impersonated: socket.assigns.impersonated
           ) do
      socket
      |> assign(:create_form, closed_create_form())
      |> assign(:new_token, %DisplayToken{value: token})
      |> assign(:new_token_name, key.name)
      |> assign(:message, nil)
    else
      {:error, {:after_ceiling, latest}} ->
        message =
          gettext("The expiry date can be %{date} at the latest.",
            date: PersonalKeyDisplay.expiry_date(latest, scope(socket).user)
          )

        assign_create_form(socket, params, [message])

      {:error, reason} ->
        assign_create_form(socket, params, error_messages(reason))
    end
  end

  # Core refuses a later expiry too; checked here so the message names the date in the
  # person's own format.
  defp check_ceiling(expires_at) do
    latest = PersonalKeysConfig.latest_expiry()

    if DateTime.compare(expires_at, latest) == :gt,
      do: {:error, {:after_ceiling, latest}},
      else: :ok
  end

  defp check_scopes(requested, allowed) do
    if Enum.all?(requested, &(&1 in allowed)), do: :ok, else: {:error, :invalid_scopes}
  end

  # The end of the chosen day, UTC. A personal key always expires, so empty is an error.
  defp parse_expiry(""), do: {:error, :expiry_required}

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
      "expires_at" => expires_at
    }
  end

  # Scope -> names of the tools it unlocks, for the hint under each checkbox.
  defp scope_tools(scopes) do
    Registry.all_tools()
    |> Enum.filter(&(&1.audience == :admin and &1.scope in scopes))
    |> Enum.group_by(& &1.scope, & &1.name)
  end

  # ── Revoke, rotate, edit scopes ────────────────────────────────────

  defp revoke_key(socket, key) do
    with true <- Keys.can_revoke?(scope(socket), key),
         {:ok, _key} <- Keys.revoke(key, scope(socket).user.uuid) do
      info(socket, gettext("The key was revoked. It stops working at once."))
    else
      _ -> error(socket, gettext("The key could not be revoked."))
    end
  end

  defp rotate_key(socket, nil, _hours),
    do: socket |> assign(:rotate_form, %{show: false}) |> not_found()

  defp rotate_key(socket, key, hours) do
    with {:ok, grace} <- parse_grace(hours),
         {:ok, new_key, token} <-
           Keys.rotate(key, grace, scope(socket), impersonated: socket.assigns.impersonated) do
      socket
      |> assign(:rotate_form, %{show: false})
      |> assign(:new_token, %DisplayToken{value: token})
      |> assign(:new_token_name, new_key.name)
      |> assign(:message, nil)
    else
      {:error, :bad_grace} ->
        assign(socket, :rotate_form, Map.put(socket.assigns.rotate_form, :error, true))

      {:error, reason} ->
        socket |> assign(:rotate_form, %{show: false}) |> error(rotate_error(reason))
    end
  end

  defp rotate_error(:rotation_pending),
    do: gettext("This key is already being replaced.")

  defp rotate_error(:personal_key_limit),
    do:
      gettext(
        "You already have the largest number of keys allowed, so the old key cannot keep working next to the new one. Rotate with a grace period of 0, or revoke a key first."
      )

  defp rotate_error(reason)
       when reason in [:forbidden, :owner_inactive, :impersonated, :impersonation_unknown],
       do: hd(error_messages(reason))

  defp rotate_error(reason) when reason in [:revoked, :expired, :not_found],
    do: gettext("That key was not found.")

  defp rotate_error(_reason), do: gettext("The key could not be rotated.")

  # 0 to 24 whole hours; anything else is refused, not clamped.
  defp parse_grace(hours) do
    case Integer.parse(String.trim(hours)) do
      {grace, ""} when grace in 0..24 -> {:ok, grace}
      _ -> {:error, :bad_grace}
    end
  end

  defp grace_options, do: Enum.map(0..24, &{Integer.to_string(&1), Integer.to_string(&1)})

  # The scopes offered are those the person can use now. The ones the key holds that they
  # cannot use right now are listed as inactive and stay on the key when it is saved
  # (`Keys.update_scopes/3` merges them back).
  defp open_scopes_form(socket, key) do
    options = Keys.allowed_scopes_for(scope(socket).user)

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

  defp save_scopes(socket, key, scopes) do
    options = Keys.allowed_scopes_for(scope(socket).user)

    with :ok <- check_scopes(scopes, options),
         {:ok, _key} <- Keys.update_scopes(key, scopes, scope(socket)) do
      socket |> assign(:scopes_form, %{show: false}) |> info(gettext("The scopes were saved."))
    else
      {:error, reason} when reason in [:revoked, :not_found] ->
        socket |> assign(:scopes_form, %{show: false}) |> not_found()

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

  # ── Messages ───────────────────────────────────────────────────────

  defp error_messages(:impersonated),
    do: [gettext("Keys cannot be changed while you act in another account.")]

  defp error_messages(:impersonation_unknown), do: [gettext("You are not allowed to do that.")]
  defp error_messages(:forbidden), do: [gettext("You are not allowed to do that.")]

  defp error_messages(:owner_inactive),
    do: [gettext("Your account cannot own keys right now.")]

  defp error_messages(:owner_not_allowed), do: [gettext("You cannot create keys for that owner.")]

  defp error_messages(:invalid_scopes),
    do: [gettext("Some of the chosen scopes are not available to you.")]

  defp error_messages(:personal_key_limit),
    do: [gettext("You already have the largest number of keys allowed. Revoke one first.")]

  defp error_messages(:expiry_required), do: [gettext("The expiry date is required.")]

  defp error_messages(:bad_expiry),
    do: [gettext("The expiry date must be a date from today on.")]

  defp error_messages(:scopes_not_narrowing),
    do: [gettext("The scopes of this key can only be narrowed.")]

  defp error_messages(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field_label(field)}: #{&1}")
    end)
  end

  defp error_messages(_other), do: [gettext("That could not be saved.")]

  defp field_label(:name), do: gettext("Name")
  defp field_label(:expires_at), do: gettext("Expires on")
  defp field_label(:allowed_ips), do: gettext("Allowed addresses")
  defp field_label(:scopes), do: gettext("Scopes")
  defp field_label(other), do: to_string(other)

  # ── Template helpers ───────────────────────────────────────────────

  defp date(datetime, user), do: UtilsDate.format_date_with_user_timezone(datetime, user)

  defp message_role(:error), do: "alert"
  defp message_role(:info), do: "status"

  defp alert_class(:error), do: "alert alert-error text-sm"
  defp alert_class(:info), do: "alert alert-success text-sm"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-4">
      <div id={"#{@id}-messages"} aria-live="polite">
        <div
          :if={@message}
          id={"#{@id}-message"}
          role={message_role(elem(@message, 0))}
          class={alert_class(elem(@message, 0))}
        >
          {elem(@message, 1)}
        </div>
      </div>

      <%= cond do %>
        <% @mode == :no_context -> %>
          <div id={"#{@id}-no-context"} class="alert alert-warning text-sm">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
            <span>
              {gettext(
                "This section was added without the session's context, so it cannot show your keys."
              )}
            </span>
          </div>
        <% @mode == :no_right -> %>
          <div id={"#{@id}-no-right"} class="alert alert-info text-sm">
            <span>{gettext("You do not have access to API keys.")}</span>
          </div>
        <% true -> %>
          <div class="space-y-4">
            <div :if={@impersonated} id={"#{@id}-impersonated"} class="alert alert-warning text-sm">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
              <span>
                {gettext(
                  "You are acting in another account, so your keys are shown but cannot be changed here. Sign in as yourself to create, rotate or revoke them."
                )}
              </span>
            </div>

            <div :if={not @admin_enabled} id={"#{@id}-api-off"} class="alert alert-warning text-sm">
              <.icon name="hero-power" class="w-5 h-5 shrink-0" />
              <span>
                {gettext(
                  "The API is switched off by an administrator. Your keys do not work now; you can still revoke them or change their scopes, but not create or rotate them."
                )}
              </span>
            </div>

            <.form_section
              id={"#{@id}-card"}
              wrap_actions
              title={gettext("My API keys")}
              icon="hero-key"
              class="border border-base-200"
              body_class="space-y-4"
            >
              <:subtitle>
                {gettext(
                  "A key acts with your rights, never with more. If you lose a right, the key loses it at once."
                )}
              </:subtitle>
              <:actions>
                <.button
                  :if={not @impersonated and @admin_enabled}
                  id={"#{@id}-new-key"}
                  type="button"
                  size="sm"
                  phx-click="open_create"
                  phx-target={@myself}
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New key")}
                </.button>
              </:actions>

              <p id={"#{@id}-counter"} class="text-sm text-base-content/70">
                {gettext("Keys: %{count} of %{max}", count: @live_count, max: @max_count)}
              </p>

              <div :if={@keys != []} id={"#{@id}-table"}>
                <.table_default>
                  <.table_default_header>
                    <.table_default_row>
                      <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
                      <.table_default_header_cell>{gettext("Scopes")}</.table_default_header_cell>
                      <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
                      <.table_default_header_cell>{gettext("Created")}</.table_default_header_cell>
                      <.table_default_header_cell>{gettext("Last used")}</.table_default_header_cell>
                      <.table_default_header_cell>{gettext("Expires on")}</.table_default_header_cell>
                      <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
                    </.table_default_row>
                  </.table_default_header>

                  <.table_default_body>
                    <.table_default_row :for={key <- @keys} id={"#{@id}-key-#{key.uuid}"}>
                      <.table_default_cell>
                        <div class="font-medium">{key.name}</div>
                        <div class="font-mono text-xs text-base-content/60">pk_{key.prefix}_…</div>
                      </.table_default_cell>
                      <.table_default_cell>
                        <div class="flex flex-wrap gap-1 max-w-xs">
                          <span
                            :for={scope <- Enum.take(key.scopes, 3)}
                            class="badge badge-ghost badge-xs font-mono"
                            title={Enum.join(Map.get(@key_tools, scope, []), ", ")}
                          >
                            {scope}
                          </span>
                          <span
                            :if={length(key.scopes) > 3}
                            class="badge badge-ghost badge-xs"
                            title={
                              key.scopes
                              |> Enum.drop(3)
                              |> Enum.flat_map(&Map.get(@key_tools, &1, []))
                              |> Enum.join(", ")
                            }
                          >
                            +{length(key.scopes) - 3}
                          </span>
                          <span :if={key.scopes == []} class="text-xs text-base-content/40">
                            {gettext("identity only")}
                          </span>
                        </div>
                      </.table_default_cell>
                      <.table_default_cell>
                        <.status_badge
                          status={PersonalKeyDisplay.badge_name(@key_statuses[key.uuid])}
                          label={PersonalKeyDisplay.label(@key_statuses[key.uuid])}
                        />
                        <div
                          :if={@key_statuses[key.uuid] == :rotating}
                          class="text-xs text-base-content/60 mt-0.5"
                        >
                          {gettext("until %{time}",
                            time: PersonalKeyDisplay.moment(key.revoked_at, @scope.user)
                          )}
                        </div>
                      </.table_default_cell>
                      <.table_default_cell class="text-sm">
                        {date(key.inserted_at, @scope.user)}
                      </.table_default_cell>
                      <.table_default_cell>
                        <%= if key.last_used_at do %>
                          <.time_ago datetime={key.last_used_at} id={"#{@id}-used-#{key.uuid}"} />
                        <% else %>
                          <span class="text-xs text-base-content/40">{gettext("Never")}</span>
                        <% end %>
                      </.table_default_cell>
                      <.table_default_cell class="text-sm">
                        {key.expires_at && PersonalKeyDisplay.expiry_date(key.expires_at, @scope.user)}
                      </.table_default_cell>
                      <.table_default_cell class="relative z-10">
                        <.table_row_menu
                          :if={
                            not @impersonated and @key_statuses[key.uuid] not in [:revoked, :expired]
                          }
                          id={"#{@id}-menu-#{key.uuid}"}
                          mode="dropdown"
                          label={gettext("Actions")}
                        >
                          <.table_row_menu_button
                            phx-click="request_edit_scopes"
                            phx-value-uuid={key.uuid}
                            phx-target={@myself}
                            icon="hero-adjustments-horizontal"
                            label={gettext("Edit scopes")}
                          />
                          <.table_row_menu_button
                            :if={
                              @admin_enabled and
                                @key_statuses[key.uuid] not in [
                                  :rotating,
                                  :no_permission,
                                  :owner_inactive
                                ]
                            }
                            phx-click="request_rotate"
                            phx-value-uuid={key.uuid}
                            phx-target={@myself}
                            icon="hero-arrow-path"
                            label={gettext("Rotate")}
                          />
                          <.table_row_menu_button
                            phx-click="request_revoke"
                            phx-value-uuid={key.uuid}
                            phx-target={@myself}
                            icon="hero-no-symbol"
                            label={gettext("Revoke")}
                            variant="error"
                          />
                        </.table_row_menu>
                      </.table_default_cell>
                    </.table_default_row>
                  </.table_default_body>
                </.table_default>
              </div>

              <div :if={@keys == []} id={"#{@id}-empty"}>
                <.empty_state
                  variant="compact"
                  icon="hero-key"
                  title={gettext("You have no API keys yet")}
                  description={
                    gettext("Create a key, copy it once, and give it to the program that needs it.")
                  }
                />
              </div>
            </.form_section>

            <%!-- How to connect --%>
            <.form_section
              id={"#{@id}-connect"}
              title={gettext("How to connect")}
              icon="hero-command-line"
              class="border border-base-200"
              body_class="space-y-2 text-sm"
            >
              <p>{gettext("Send the key in the Authorization header of every request:")}</p>
              <pre class="font-mono text-xs bg-base-200 rounded p-2 overflow-x-auto"><code>Authorization: Bearer &lt;your key&gt;</code></pre>
              <p>
                {gettext("REST address:")}
                <span id={"#{@id}-rest-url"} class="font-mono text-xs break-all">{@connect.rest}</span>
              </p>
              <p>
                {gettext("MCP address (for AI agents):")}
                <span id={"#{@id}-mcp-url"} class="font-mono text-xs break-all">{@connect.mcp}</span>
              </p>
              <p class="text-base-content/70">
                {gettext("The key acts only with your rights; do not give it to other people.")}
              </p>
            </.form_section>

            <p :if={@holds_api} id={"#{@id}-other-keys"} class="text-sm text-base-content/70">
              <.pk_link navigate="/admin/settings/api?tab=keys" class="link">
                {gettext("Your other keys are on Settings → API")}
              </.pk_link>
            </p>

            <%!-- Create key --%>
            <.modal
              show={@create_form.show}
              on_close="close_create"
              id={"#{@id}-create-modal"}
              actions_class="flex-wrap"
              max_width="2xl"
            >
              <:title>
                <.icon name="hero-key" class="w-5 h-5" /> {gettext("New API key")}
              </:title>

              <form
                id={"#{@id}-create-form"}
                phx-change="create_form_changed"
                phx-submit="create_key"
                phx-target={@myself}
                class="space-y-4"
              >
                <div
                  :if={@create_form.errors != []}
                  id={"#{@id}-create-errors"}
                  class="alert alert-error text-sm"
                >
                  <ul class="list-disc pl-4">
                    <li :for={message <- @create_form.errors}>{message}</li>
                  </ul>
                </div>

                <.input
                  id={"#{@id}-key-name"}
                  wrap_label
                  name="key[name]"
                  type="text"
                  label={gettext("Name")}
                  value={@create_form.params["name"]}
                  phx-debounce="300"
                  placeholder={gettext("What the key is for, for example Stock sync")}
                  required
                />

                <fieldset id={"#{@id}-key-scopes"} class="fieldset min-w-0">
                  <legend class="fieldset-legend">{gettext("Scopes")}</legend>
                  <p
                    :if={Map.get(@create_form, :options, []) == []}
                    id={"#{@id}-no-scopes"}
                    class="text-sm text-base-content/60"
                  >
                    {gettext(
                      "No scopes are available to you, so a key could only read its own identity. Ask an administrator for more rights."
                    )}
                  </p>
                  <.checkbox
                    :for={scope <- Map.get(@create_form, :options, [])}
                    name="key[scopes][]"
                    value={scope}
                    unchecked_value={nil}
                    checked={scope in @create_form.params["scopes"]}
                    class="checkbox-sm"
                    wrapper_class="py-1"
                  >
                    <span class="font-mono">{scope}</span>
                    <:description>
                      {Enum.join(Map.get(Map.get(@create_form, :tools, %{}), scope, []), ", ")}
                    </:description>
                  </.checkbox>
                </fieldset>

                <.input
                  id={"#{@id}-key-allowed-ips"}
                  wrap_label
                  name="key[allowed_ips]"
                  type="text"
                  label={gettext("Allowed addresses (optional)")}
                  value={@create_form.params["allowed_ips"]}
                  phx-debounce="300"
                  placeholder="203.0.113.5, 10.0.0.0/8"
                />

                <.input
                  id={"#{@id}-key-expires-on"}
                  name="key[expires_on]"
                  type="date"
                  label={gettext("Expires on")}
                  value={@create_form.params["expires_on"]}
                  min={Date.to_iso8601(Date.utc_today())}
                  max={@max_expiry && Date.to_iso8601(@max_expiry)}
                  required
                />
              </form>

              <:actions>
                <.button type="button" variant="ghost" phx-click="close_create" phx-target={@myself}>
                  {gettext("Cancel")}
                </.button>
                <.button
                  type="submit"
                  form={"#{@id}-create-form"}
                  id={"#{@id}-create-submit"}
                  disabled={Map.get(@create_form, :options, []) == []}
                >
                  {gettext("Create the key")}
                </.button>
              </:actions>
            </.modal>

            <%!-- The new key, shown once --%>
            <.modal
              show={@new_token != nil}
              on_close="dismiss_token"
              id={"#{@id}-token-modal"}
              actions_class="flex-wrap"
              max_width="xl"
              closeable={false}
            >
              <:title>
                <.icon name="hero-key" class="w-5 h-5 text-success" /> {gettext(
                  "Copy your new key now"
                )}
              </:title>

              <div class="space-y-4">
                <div class="alert alert-warning text-sm">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
                  <span>
                    {gettext(
                      "This is the only time the key is shown. Keep it in a password manager or a secret store. If it is lost, revoke it and create a new one."
                    )}
                  </span>
                </div>

                <p :if={@new_token_name} class="text-sm">
                  {gettext("Key: %{name}", name: @new_token_name)}
                </p>

                <%!-- No `name`: the key is in no form, so it is never sent back as a param. --%>
                <div class="flex items-center gap-2">
                  <.input
                    id={"#{@id}-token"}
                    name={nil}
                    type="text"
                    readonly
                    autocomplete="off"
                    spellcheck="false"
                    aria-label={gettext("New API key")}
                    value={@new_token}
                    class="font-mono text-sm"
                    wrapper_class="min-w-0 grow"
                  />
                  <.button
                    type="button"
                    id={"#{@id}-token-copy"}
                    size="sm"
                    variant="outline"
                    class="shrink-0"
                    phx-hook="CopyToClipboard"
                    data-copy-target={"##{@id}-token"}
                  >
                    <span data-copy-idle>{gettext("Copy")}</span>
                    <span data-copy-feedback class="hidden">{gettext("Copied!")}</span>
                  </.button>
                </div>

                <p class="text-xs text-base-content/60">
                  {gettext(
                    "Send it only in the Authorization header, as Bearer and the key. A key in a web address is refused."
                  )}
                </p>
              </div>

              <:actions>
                <.button
                  id={"#{@id}-token-done"}
                  type="button"
                  phx-click="dismiss_token"
                  phx-target={@myself}
                >
                  {gettext("I have stored the key")}
                </.button>
              </:actions>
            </.modal>

            <%!-- Edit the scopes of a key --%>
            <.modal
              show={@scopes_form.show}
              on_close="cancel_edit_scopes"
              id={"#{@id}-scopes-modal"}
              actions_class="flex-wrap"
              max_width="2xl"
            >
              <:title>
                <.icon name="hero-adjustments-horizontal" class="w-5 h-5" />
                {gettext("Edit the scopes of this key")}
              </:title>

              <form
                id={"#{@id}-scopes-form"}
                phx-submit="save_key_scopes"
                phx-target={@myself}
                class="space-y-4"
              >
                <input type="hidden" name="key_scopes[present]" value="1" />
                <p :if={@scopes_form[:name]} class="font-medium">{@scopes_form[:name]}</p>

                <div
                  :if={Map.get(@scopes_form, :errors, []) != []}
                  id={"#{@id}-scopes-errors"}
                  class="alert alert-error text-sm"
                >
                  <ul class="list-disc pl-4">
                    <li :for={message <- Map.get(@scopes_form, :errors, [])}>{message}</li>
                  </ul>
                </div>

                <fieldset class="fieldset min-w-0">
                  <legend class="fieldset-legend">{gettext("Scopes")}</legend>
                  <p
                    :if={Map.get(@scopes_form, :options, []) == []}
                    class="text-sm text-base-content/60"
                  >
                    {gettext(
                      "No scopes are available to you, so a key could only read its own identity. Ask an administrator for more rights."
                    )}
                  </p>
                  <.checkbox
                    :for={scope <- Map.get(@scopes_form, :options, [])}
                    name="key_scopes[scopes][]"
                    value={scope}
                    unchecked_value={nil}
                    checked={scope in Map.get(@scopes_form, :selected, [])}
                    class="checkbox-sm"
                    wrapper_class="py-1"
                  >
                    <span class="font-mono">{scope}</span>
                    <:description>
                      {Enum.join(Map.get(Map.get(@scopes_form, :tools, %{}), scope, []), ", ")}
                    </:description>
                  </.checkbox>
                  <div
                    :if={Map.get(@scopes_form, :inactive, []) != []}
                    id={"#{@id}-scopes-inactive"}
                    class="mt-2"
                  >
                    <p class="text-sm text-base-content/70">
                      {gettext(
                        "These scopes are inactive because you can no longer use them or their module's API is switched off. They stay on the key when you save."
                      )}
                    </p>
                    <ul class="text-sm">
                      <li :for={scope <- @scopes_form.inactive} class="font-mono opacity-60">
                        {scope}
                      </li>
                    </ul>
                  </div>
                </fieldset>
              </form>

              <:actions>
                <.button
                  type="button"
                  variant="ghost"
                  phx-click="cancel_edit_scopes"
                  phx-target={@myself}
                >
                  {gettext("Cancel")}
                </.button>
                <.button type="submit" form={"#{@id}-scopes-form"} id={"#{@id}-scopes-submit"}>
                  {gettext("Save the scopes")}
                </.button>
              </:actions>
            </.modal>

            <%!-- Rotate --%>
            <.modal
              show={@rotate_form.show}
              on_close="cancel_rotate"
              id={"#{@id}-rotate-modal"}
              actions_class="flex-wrap"
              max_width="lg"
            >
              <:title>
                <.icon name="hero-arrow-path" class="w-5 h-5" /> {gettext("Rotate this key")}
              </:title>

              <form
                id={"#{@id}-rotate-form"}
                phx-submit="confirm_rotate"
                phx-target={@myself}
                class="space-y-4"
              >
                <p :if={@rotate_form[:name]} class="font-medium">{@rotate_form[:name]}</p>
                <p class="text-sm text-base-content/70">
                  {gettext(
                    "A new key is created with the same scopes and limits and a new expiry date. The old key keeps working for the grace period, then stops."
                  )}
                </p>
                <div
                  :if={@rotate_form[:error]}
                  id={"#{@id}-rotate-error"}
                  class="alert alert-error text-sm"
                >
                  {gettext("Give a whole number of hours from 0 to 24.")}
                </div>
                <.select
                  id={"#{@id}-grace-hours"}
                  wrap_label
                  name="rotate[grace_hours]"
                  label={gettext("Grace period in hours (0 to 24)")}
                  value={if Map.get(@rotate_form, :at_limit), do: "0", else: "1"}
                  options={grace_options()}
                />
                <div
                  :if={Map.get(@rotate_form, :at_limit)}
                  id={"#{@id}-rotate-at-limit"}
                  class="alert alert-info text-sm"
                >
                  {gettext(
                    "You already have the largest number of keys allowed, so the old key cannot keep working next to the new one: the grace period starts at 0 and the old key stops at once. Revoke another key first if you need a longer overlap."
                  )}
                </div>
              </form>

              <:actions>
                <.button type="button" variant="ghost" phx-click="cancel_rotate" phx-target={@myself}>
                  {gettext("Cancel")}
                </.button>
                <.button type="submit" form={"#{@id}-rotate-form"} id={"#{@id}-rotate-submit"}>
                  {gettext("Rotate the key")}
                </.button>
              </:actions>
            </.modal>

            <%!-- Revoke. `confirm_modal` cannot send its buttons to a component, so the dialog is built here. --%>
            <.modal
              show={@revoke_confirmation.show}
              on_close="cancel_revoke"
              id={"#{@id}-revoke-modal"}
              max_width="md"
            >
              <:title>
                <.icon name="hero-no-symbol" class="w-5 h-5 text-error" /> {gettext(
                  "Revoke this key?"
                )}
              </:title>

              <p :if={@revoke_confirmation[:name]} class="font-medium">
                {@revoke_confirmation[:name]}
              </p>
              <div class="alert alert-warning text-sm mt-2">
                {gettext("Programs that use this key stop working at once. This cannot be undone.")}
              </div>

              <:actions>
                <.button type="button" variant="ghost" phx-click="cancel_revoke" phx-target={@myself}>
                  {gettext("Cancel")}
                </.button>
                <.button
                  type="button"
                  variant="error"
                  id={"#{@id}-revoke-confirm"}
                  phx-click="confirm_revoke"
                  phx-target={@myself}
                >
                  {gettext("Revoke")}
                </.button>
              </:actions>
            </.modal>
          </div>
      <% end %>
    </div>
    """
  end
end
