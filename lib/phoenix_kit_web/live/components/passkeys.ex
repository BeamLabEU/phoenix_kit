defmodule PhoenixKitWeb.Live.Components.Passkeys do
  @moduledoc """
  A person's passkeys: the list, and adding, renaming and removing them
  (`PhoenixKit.Users.Passkeys`). Rendered by the `:passkeys` section of
  `PhoenixKitWeb.Live.Components.UserSettings` for the signed-in person, and by the
  admin's user page for someone else.

  ## Contract

    * `id` — unique component id
    * `user` — whose passkeys these are
    * `impersonated` — a boolean the host page computes in its `mount/3` with
      `PhoenixKitWeb.Users.MultiSession.impersonated?(session)`, never a constant.
      Anything but `false` lists the passkeys and changes nothing.
    * `session_token` — the raw session token of this browser, for the
      fresh-sign-in rule of `PhoenixKit.Users.Passkeys.check_may_add/2`
    * `actor` — given by the admin's user page only: the person looking. They may
      remove passkeys (under `Sessions.can_revoke_sessions_of?/2`, checked in
      `Passkeys.delete/3`), never add or rename one.

  Every event is checked on the server: a hidden button is not the control. The user
  and the actor are read again from the database before anything changes, and the
  passkey to remove is the one the server stored when the confirmation opened, never
  a param. The registration challenge lives in this component's assigns only.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Passkeys
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:user, assigns.user)
      |> assign(:impersonated, Map.get(assigns, :impersonated, socket.assigns[:impersonated]))
      |> assign(
        :session_token,
        Map.get(assigns, :session_token, socket.assigns[:session_token])
      )
      |> assign(:actor, Map.get(assigns, :actor, socket.assigns[:actor]))
      |> assign_new(:challenge, fn -> nil end)
      |> assign_new(:renaming, fn -> nil end)
      |> assign_new(:removing, fn -> nil end)
      |> assign_new(:message, fn -> nil end)

    # Once per person: the parent re-renders this on every change of its own.
    if socket.assigns[:loaded_for] == assigns.user.uuid,
      do: {:ok, socket},
      else: {:ok, socket |> load() |> assign(:loaded_for, assigns.user.uuid)}
  end

  defp load(socket) do
    user = socket.assigns.user

    socket
    |> assign(:passkeys, Passkeys.list(user))
    |> assign(:domain, Passkeys.relying_party().rp_id)
    |> assign(:may_add, may_add(socket, user))
  end

  defp may_add(socket, user) do
    if owner?(socket.assigns) do
      Passkeys.check_may_add(user,
        impersonated: socket.assigns.impersonated,
        session_token: socket.assigns.session_token
      )
    else
      {:error, :not_allowed}
    end
  end

  # The person's own settings page passes no `actor`. The admin page always does,
  # one's own user page included: it has no session token, so it cannot add.
  defp owner?(%{actor: nil}), do: true
  defp owner?(_assigns), do: false

  defp borrowed?(assigns), do: assigns.impersonated != false

  # ── Adding ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("passkey_registration_options", _params, socket) do
    with true <- owner?(socket.assigns) || {:error, :not_allowed},
         %User{} = user <- fresh_user(socket.assigns.user),
         :ok <- may_add(socket, user) do
      {challenge, options} = Passkeys.registration_options(user)
      {:reply, %{options: options}, assign(socket, challenge: challenge, message: nil)}
    else
      reason -> {:reply, %{}, refuse(socket, reason)}
    end
  end

  def handle_event("passkey_register", params, socket) when is_map(params) do
    challenge = socket.assigns.challenge
    socket = assign(socket, :challenge, nil)

    with true <- owner?(socket.assigns) || {:error, :not_allowed},
         %Wax.Challenge{} <- challenge || {:error, :invalid},
         %User{} = user <- fresh_user(socket.assigns.user),
         {:ok, passkey} <-
           Passkeys.register(user, challenge, params,
             impersonated: socket.assigns.impersonated,
             session_token: socket.assigns.session_token
           ) do
      {:noreply,
       socket
       |> load()
       |> assign(
         :message,
         {:success, gettext("Passkey added: %{name}.", name: passkey.name)}
       )}
    else
      reason -> {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("passkey_register_failed", %{"name" => "cancelled"}, socket) do
    {:noreply, assign(socket, challenge: nil, message: nil)}
  end

  def handle_event("passkey_register_failed", _params, socket) do
    {:noreply,
     socket
     |> assign(:challenge, nil)
     |> assign(
       :message,
       {:error,
        gettext("Your browser could not make a passkey. Try again, or use another device.")}
     )}
  end

  # ── Renaming ───────────────────────────────────────────────────────

  def handle_event("start_rename", %{"uuid" => uuid}, socket) do
    if owner?(socket.assigns) and not borrowed?(socket.assigns),
      do: {:noreply, assign(socket, renaming: uuid, removing: nil)},
      else: {:noreply, refuse(socket, {:error, :not_allowed})}
  end

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, :renaming, nil)}

  def handle_event("rename", %{"passkey" => %{"name" => name}}, socket) when is_binary(name) do
    with true <-
           (owner?(socket.assigns) and not borrowed?(socket.assigns)) || {:error, :not_allowed},
         uuid when is_binary(uuid) <- socket.assigns.renaming || {:error, :not_found},
         %User{} = user <- fresh_user(socket.assigns.user),
         {:ok, _passkey} <- Passkeys.rename(user, uuid, name) do
      {:noreply, socket |> assign(renaming: nil, message: nil) |> load()}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(
           socket,
           :message,
           {:error, gettext("A name needs 1 to 100 characters.")}
         )}

      reason ->
        {:noreply, refuse(socket, reason)}
    end
  end

  # ── Removing ───────────────────────────────────────────────────────

  def handle_event("request_remove", %{"uuid" => uuid}, socket) do
    if borrowed?(socket.assigns),
      do: {:noreply, refuse(socket, {:error, :impersonated})},
      else: {:noreply, assign(socket, removing: uuid, renaming: nil)}
  end

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :removing, nil)}

  def handle_event("confirm_remove", _params, socket) do
    with true <- not borrowed?(socket.assigns) || {:error, :impersonated},
         uuid when is_binary(uuid) <- socket.assigns.removing || {:error, :not_found},
         %User{} = user <- fresh_user(socket.assigns.user),
         %User{} = actor <- fresh_user(socket.assigns.actor || socket.assigns.user),
         {:ok, passkey} <- Passkeys.delete(user, uuid, actor) do
      {:noreply,
       socket
       |> assign(:removing, nil)
       |> load()
       |> assign(:message, {:success, gettext("Passkey removed: %{name}.", name: passkey.name)})}
    else
      reason -> {:noreply, socket |> assign(:removing, nil) |> refuse(reason)}
    end
  end

  defp fresh_user(%User{uuid: uuid}), do: Auth.get_user(uuid) || {:error, :not_found}
  defp fresh_user(_), do: {:error, :not_found}

  defp refuse(socket, reason) do
    assign(socket, :message, {:error, refusal_text(reason)})
  end

  defp refusal_text({:error, :impersonated}),
    do: gettext("Passkeys cannot be changed while you are signed in as someone else.")

  defp refusal_text({:error, :stale_session}), do: stale_text()

  defp refusal_text({:error, :disabled}), do: gettext("Passkeys are turned off on this site.")

  defp refusal_text({:error, :already_registered}),
    do: gettext("This passkey is already saved to an account.")

  defp refusal_text({:error, :not_found}), do: gettext("That passkey no longer exists.")

  defp refusal_text({:error, :not_allowed}), do: gettext("You cannot change these passkeys.")

  defp refusal_text(_),
    do: gettext("That passkey could not be added. Try again, or use another device.")

  defp stale_text do
    gettext(
      "To add a passkey, sign out and sign in again, then come back here within %{minutes} minutes. This keeps someone who finds your device unlocked from adding a passkey of their own.",
      minutes: Passkeys.fresh_session_minutes()
    )
  end

  # ── Rendering ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:owner, owner?(assigns))
      |> assign(:borrowed, borrowed?(assigns))

    ~H"""
    <div id={@id} phx-hook="PasskeyRegister" phx-target={@myself} data-passkeys>
      <h2 class="text-lg font-semibold flex items-center gap-2 mb-2">
        <.icon name="hero-finger-print" class="w-5 h-5 text-primary" />
        {gettext("Passkeys")}
      </h2>
      <p :if={@owner} class="text-sm text-base-content/70 mb-4">
        {gettext(
          "Sign in with Face ID, Touch ID, Windows Hello or your device's PIN instead of a password. Your device keeps the key; this site stores only its public half."
        )}
      </p>

      <div
        :if={@message}
        class={[
          "alert text-sm mb-4",
          if(elem(@message, 0) == :success, do: "alert-success", else: "alert-error")
        ]}
        role="status"
      >
        <span>{elem(@message, 1)}</span>
      </div>

      <p :if={@passkeys == []} class="text-sm text-base-content/60 mb-4">
        {if @owner,
          do: gettext("You have no passkeys yet."),
          else: gettext("No passkeys.")}
      </p>

      <ul :if={@passkeys != []} class="space-y-2 mb-4">
        <li
          :for={passkey <- @passkeys}
          id={"#{@id}-#{passkey.uuid}"}
          class="rounded-box border border-base-300 p-3"
        >
          <%= if @renaming == passkey.uuid do %>
            <.form
              for={%{}}
              as={:passkey}
              id={"#{@id}-rename-#{passkey.uuid}"}
              phx-submit="rename"
              phx-target={@myself}
              class="flex flex-wrap items-center gap-2"
            >
              <input
                type="text"
                name="passkey[name]"
                value={passkey.name}
                maxlength="100"
                class="input input-sm grow"
                aria-label={gettext("Passkey name")}
              />
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
              <button
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="cancel_rename"
                phx-target={@myself}
              >
                {gettext("Cancel")}
              </button>
            </.form>
          <% else %>
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div class="min-w-0">
                <div class="font-medium break-words">{passkey.name}</div>
                <div class="text-xs text-base-content/60">
                  {gettext("Added %{date}",
                    date: UtilsDate.format_date_with_user_timezone(passkey.inserted_at, @user)
                  )} · {if passkey.last_used_at,
                    do:
                      gettext("last used %{date}",
                        date: UtilsDate.format_date_with_user_timezone(passkey.last_used_at, @user)
                      ),
                    else: gettext("never used")} · {if passkey.backup_eligible,
                    do: gettext("synced"),
                    else: gettext("this device only")}
                </div>
                <div :if={passkey.rp_id != @domain} class="text-xs text-warning mt-1">
                  {gettext("Made for %{domain}; it does not work on this site's current address.",
                    domain: passkey.rp_id
                  )}
                </div>
              </div>
              <div :if={not @borrowed and @removing != passkey.uuid} class="flex gap-1">
                <button
                  :if={@owner}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="start_rename"
                  phx-value-uuid={passkey.uuid}
                  phx-target={@myself}
                >
                  {gettext("Rename")}
                </button>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="request_remove"
                  phx-value-uuid={passkey.uuid}
                  phx-target={@myself}
                >
                  {gettext("Remove")}
                </button>
              </div>
            </div>
            <div
              :if={@removing == passkey.uuid}
              class="mt-2 flex flex-wrap items-center gap-2 text-sm"
            >
              <span>
                {if @owner,
                  do: gettext("Remove this passkey? It will no longer sign you in."),
                  else: gettext("Remove this passkey? It will no longer sign this person in.")}
              </span>
              <button
                type="button"
                class="btn btn-error btn-xs"
                phx-click="confirm_remove"
                phx-target={@myself}
              >
                {gettext("Remove")}
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="cancel_remove"
                phx-target={@myself}
              >
                {gettext("Cancel")}
              </button>
            </div>
          <% end %>
        </li>
      </ul>

      <%= if @owner do %>
        <%= case @may_add do %>
          <% :ok -> %>
            <button type="button" class="btn btn-primary btn-sm" data-passkey-register>
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add a passkey")}
            </button>
          <% {:error, :impersonated} -> %>
            <p class="text-sm text-base-content/60">
              {gettext("Passkeys cannot be added while you are signed in as someone else.")}
            </p>
          <% {:error, :stale_session} -> %>
            <p class="text-sm text-base-content/60">{stale_text()}</p>
          <% _ -> %>
        <% end %>
      <% end %>
    </div>
    """
  end
end
