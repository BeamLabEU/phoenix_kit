defmodule PhoenixKitWeb.Live.Components.OrganizationManagers do
  @moduledoc """
  Manager controls shared by organization details and account settings.

  `actor` must come from `ManagedOrganizations.Actor.from_session/1` at the
  caller's mount. Never build it from event parameters. A host embedding the
  UserSettings `:managers` section passes it as `manager_actor`.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Checkbox
  alias PhoenixKitWeb.Components.Core.Input

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:people, fn -> [] end)
     |> load()}
  end

  defp load(socket) do
    case OrganizationManagers.details(socket.assigns.actor, socket.assigns.organization_uuid) do
      {:ok, details} -> assign(socket, :details, details)
      _ -> assign(socket, :details, nil)
    end
  end

  @impl true
  def handle_event("invite", %{"email" => email}, socket) do
    result =
      Invitations.create_invitation(
        %User{uuid: socket.assigns.organization_uuid},
        email,
        socket.assigns.actor,
        kind: :manager
      )

    finish(
      socket,
      result,
      gettext(
        "If this address can receive invitations, a manager invitation is available to its owner."
      )
    )
  end

  def handle_event("cancel", %{"uuid" => uuid}, socket) do
    result =
      Invitations.cancel_invitation(socket.assigns.actor, socket.assigns.organization_uuid, uuid)

    finish(socket, result, gettext("Invitation cancelled"))
  end

  def handle_event("remove", %{"person_uuid" => person_uuid} = params, socket) do
    result =
      OrganizationManagers.remove(
        socket.assigns.actor,
        socket.assigns.organization_uuid,
        person_uuid,
        allow_managerless: params["allow_managerless"] == "true"
      )

    finish(socket, result, gettext("Manager removed"))
  end

  def handle_event("contact", %{"contact_email" => email}, socket) do
    result =
      OrganizationManagers.update_contact(
        socket.assigns.actor,
        socket.assigns.organization_uuid,
        %{"contact_email" => email}
      )

    finish(socket, result, gettext("Contact address updated"))
  end

  def handle_event("search", %{"query" => term}, socket) do
    case OrganizationManagers.search(socket.assigns.actor, socket.assigns.organization_uuid, term) do
      {:ok, people} -> {:noreply, assign(socket, :people, people)}
      _ -> finish(socket, {:error, :forbidden}, nil)
    end
  end

  def handle_event("add", %{"person_uuid" => person_uuid}, socket) do
    result =
      OrganizationManagers.add(
        socket.assigns.actor,
        socket.assigns.organization_uuid,
        person_uuid
      )

    finish(socket, result, gettext("Manager added"))
  end

  def handle_event("convert_to_managed", %{"person_uuid" => person_uuid}, socket) do
    result =
      ManagedOrganizations.convert_to_managed(
        socket.assigns.actor,
        socket.assigns.organization_uuid,
        person_uuid
      )

    finish(socket, result, gettext("Organization now uses manager accounts"))
  end

  def handle_event("convert_to_independent", params, socket) do
    result =
      ManagedOrganizations.convert_to_independent(
        socket.assigns.actor,
        socket.assigns.organization_uuid,
        Map.take(params, ["email", "password"])
      )

    case result do
      {:ok, org} ->
        Auth.deliver_user_confirmation_instructions(org, &Routes.url("/users/confirm/#{&1}"))

      _ ->
        :ok
    end

    finish(socket, result, gettext("Organization now has its own sign-in credentials"))
  end

  defp finish(socket, {:ok, _, _}, message), do: finish(socket, {:ok, :ok}, message)

  defp finish(socket, {:ok, %User{} = user}, message) do
    send(self(), {:phoenix_kit_user_updated, user})
    finish(socket, {:ok, :ok}, message)
  end

  defp finish(socket, {:ok, _}, message) do
    {:noreply,
     socket |> assign(:notice, message) |> assign(:error, nil) |> assign(:people, []) |> load()}
  end

  defp finish(socket, {:error, reason}, _message) do
    {:noreply, socket |> assign(:notice, nil) |> assign(:error, error_message(reason)) |> load()}
  end

  defp error_message(:cannot_remove_last_active_manager),
    do:
      gettext(
        "Add another active manager first, or explicitly leave this organization without managers as an administrator."
      )

  defp error_message(:rate_limit_exceeded),
    do: gettext("Too many invitations. Please try again later.")

  defp error_message(%Ecto.Changeset{}),
    do: gettext("Check the email address and required fields.")

  defp error_message(_),
    do: gettext("This change is not available. Refresh the page and check your access.")

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="card bg-base-100 shadow-sm my-6">
      <div :if={@details} class="card-body gap-5">
        <h2 class="card-title">{gettext("Managers")}</h2>
        <div :if={@notice} class="alert alert-success" role="status">{@notice}</div>
        <div :if={@error} class="alert alert-error" role="alert">{@error}</div>
        <%= if @details.organization.managed_by_members do %>
          <p>{gettext("Managers use their own accounts to act for this organization.")}</p>
          <form
            id={"#{@id}-contact"}
            phx-submit="contact"
            phx-target={@myself}
            class="flex gap-3 items-end"
          >
            <Input.input
              name="contact_email"
              value={@details.organization.contact_email}
              type="email"
              label={gettext("Contact email")}
            />
            <button class="btn btn-primary" type="submit">{gettext("Save")}</button>
          </form>
          <p :if={@details.grants == []}>{gettext("This organization has no managers.")}</p>
          <div :for={grant <- @details.grants} class="border-b border-base-300 py-3">
            <div class="font-medium">{User.display_name(grant.user)}</div>
            <div class="text-sm opacity-70">{User.delivery_email(grant.user)}</div>
            <form
              id={"#{@id}-remove-#{grant.uuid}"}
              phx-submit="remove"
              phx-target={@myself}
              class="flex gap-3 items-center mt-2"
            >
              <input type="hidden" name="person_uuid" value={grant.user_uuid} />
              <Checkbox.checkbox
                :if={@details.authority.kind == :admin}
                name="allow_managerless"
                checked={false}
                label={gettext("Allow this organization to have no active managers")}
              />
              <button type="submit" class="btn btn-sm btn-error btn-outline">{gettext(
                "Remove manager"
              )}</button>
            </form>
          </div>
          <form
            id={"#{@id}-invite"}
            phx-submit="invite"
            phx-target={@myself}
            class="flex gap-3 items-end"
          >
            <Input.input
              name="email"
              value=""
              type="email"
              required
              label={gettext("Invite a manager by email")}
            />
            <button type="submit" class="btn btn-primary">{gettext("Send invitation")}</button>
          </form>
          <div
            :for={invitation <- @details.invitations}
            :if={invitation.status == :pending}
            class="flex justify-between gap-3"
          >
            <span>{invitation.email}</span>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="cancel"
              phx-value-uuid={invitation.uuid}
              phx-target={@myself}
            >{gettext("Cancel invitation")}</button>
          </div>
        <% end %>
        <div :if={@details.authority.kind == :admin} class="space-y-4">
          <%= if @details.organization.managed_by_members do %>
            <form
              id={"#{@id}-search"}
              phx-submit="search"
              phx-target={@myself}
              class="flex gap-3 items-end"
            >
              <Input.input name="query" value="" label={gettext("Find an active person")} />
              <button type="submit" class="btn btn-outline">{gettext("Search")}</button>
            </form>
            <button
              :for={person <- @people}
              type="button"
              class="btn btn-outline mr-2"
              phx-click="add"
              phx-value-person_uuid={person.uuid}
              phx-target={@myself}
            >
              {gettext("Add %{person}", person: User.display_name(person))}
            </button>
            <details>
              <summary class="cursor-pointer">
                {gettext("Give this organization its own login")}
              </summary>
              <p class="my-3">
                {gettext(
                  "This removes all managers and acting sessions. Set new credentials; previous credentials stay revoked."
                )}
              </p>
              <form
                id={"#{@id}-independent"}
                phx-submit="convert_to_independent"
                phx-target={@myself}
                class="space-y-3"
              >
                <Input.input
                  name="email"
                  type="email"
                  value=""
                  required
                  label={gettext("New login email")}
                />
                <Input.input
                  name="password"
                  type="password"
                  value=""
                  required
                  label={gettext("New password")}
                />
                <button type="submit" class="btn btn-warning">{gettext(
                  "Convert to independent organization"
                )}</button>
              </form>
            </details>
          <% else %>
            <p>
              {gettext(
                "Convert this organization to manager accounts. Its existing credentials and sessions will be revoked."
              )}
            </p>
            <form
              id={"#{@id}-search"}
              phx-submit="search"
              phx-target={@myself}
              class="flex gap-3 items-end"
            >
              <Input.input name="query" value="" label={gettext("Find the first manager")} />
              <button type="submit" class="btn btn-outline">{gettext("Search")}</button>
            </form>
            <button
              :for={person <- @people}
              type="button"
              class="btn btn-warning mr-2"
              phx-click="convert_to_managed"
              phx-value-person_uuid={person.uuid}
              phx-target={@myself}
            >
              {gettext("Convert with %{person} as first manager", person: User.display_name(person))}
            </button>
          <% end %>
        </div>
      </div>
    </section>
    """
  end
end
