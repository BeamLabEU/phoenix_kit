defmodule PhoenixKitWeb.Live.Components.OrganizationManagers do
  @moduledoc """
  The People panel, shared by organization details and account settings: everyone who
  may act for the organization, what each may do, and one dialog to add or change them.

  `actor` must come from `ManagedOrganizations.Actor.from_session/1` at the
  caller's mount. Never build it from event parameters. A host embedding the
  UserSettings `:managers` section passes it as `manager_actor`.

  What the dialog offers is for show: `OrganizationManagers` checks every value again.
  A role the actor may not hand out renders locked and rides along as a hidden input, or
  its omission would read as a removal.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Input

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:people, fn -> [] end)
     |> assign_new(:searched?, fn -> false end)
     |> assign_new(:query, fn -> "" end)
     |> assign_new(:dialog, fn -> nil end)
     |> assign_new(:draft, fn -> nil end)
     |> assign_new(:selected, fn -> nil end)
     |> assign_new(:blocked_removal, fn -> nil end)
     |> load()}
  end

  defp load(socket) do
    case OrganizationManagers.details(socket.assigns.actor, socket.assigns.organization_uuid) do
      {:ok, details} -> assign(socket, :details, details)
      _ -> assign(socket, :details, nil)
    end
  end

  @impl true
  def handle_event("open_add", _params, socket) do
    {:noreply,
     socket
     |> reset_dialog()
     |> assign(dialog: :add, draft: new_draft(socket.assigns.details))}
  end

  def handle_event("open_edit", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.details.grants, &(&1.uuid == uuid)) do
      %OrganizationManager{} = grant ->
        {:noreply, socket |> reset_dialog() |> assign(dialog: grant, draft: grant_draft(grant))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("close_dialog", _params, socket), do: {:noreply, reset_dialog(socket)}

  # Keeps what is typed and ticked across the patches a change causes.
  def handle_event("draft", params, socket) do
    {:noreply, assign(socket, :draft, read_draft(socket.assigns.draft, params))}
  end

  def handle_event("select_person", %{"person_uuid" => uuid}, socket) do
    {:noreply, assign(socket, :selected, Enum.find(socket.assigns.people, &(&1.uuid == uuid)))}
  end

  def handle_event("clear_person", _params, socket),
    do: {:noreply, assign(socket, :selected, nil)}

  def handle_event("invite", %{"email" => email} = params, socket) do
    result =
      Invitations.create_invitation(
        %User{uuid: socket.assigns.organization_uuid},
        email,
        socket.assigns.actor,
        [kind: :manager] ++ link_opts(params)
      )

    finish(
      socket,
      result,
      gettext("If this address can receive invitations, an invitation is available to its owner.")
    )
  end

  def handle_event("save_link", params, socket) do
    case socket.assigns.dialog do
      %OrganizationManager{user_uuid: person_uuid} ->
        result =
          OrganizationManagers.update(
            socket.assigns.actor,
            socket.assigns.organization_uuid,
            person_uuid,
            link_opts(params)
          )

        finish(socket, result, gettext("Access updated"))

      _ ->
        {:noreply, socket}
    end
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

    finish(socket, result, gettext("Person removed"), person_uuid)
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
    if String.trim(term) == "" do
      {:noreply, assign(socket, people: [], searched?: false, query: term)}
    else
      case OrganizationManagers.search(
             socket.assigns.actor,
             socket.assigns.organization_uuid,
             term
           ) do
        {:ok, people} -> {:noreply, assign(socket, people: people, searched?: true, query: term)}
        _ -> finish(socket, {:error, :forbidden}, nil)
      end
    end
  end

  def handle_event("add", %{"person_uuid" => person_uuid} = params, socket) do
    result =
      OrganizationManagers.add(
        socket.assigns.actor,
        socket.assigns.organization_uuid,
        person_uuid,
        link_opts(params)
      )

    finish(socket, result, gettext("Person added"))
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

  # A form names the access it wants; a caller with no such fields gets the defaults.
  defp link_opts(%{"access" => access} = params) do
    type = if params["type"] in [nil, ""], do: [], else: [type: params["type"]]

    roles =
      case access do
        "all" -> [all_roles: true]
        _ -> [roles: List.wrap(params["roles"])]
      end

    type ++ roles
  end

  defp link_opts(_params), do: []

  defp reset_dialog(socket) do
    assign(socket,
      dialog: nil,
      draft: nil,
      selected: nil,
      people: [],
      searched?: false,
      query: "",
      error: nil
    )
  end

  # The lowest level is what a slip should cost.
  defp new_draft(details) do
    active = active_types(details.types, nil)
    type = Enum.find(active, &(not &1.can_manage)) || List.first(active)

    %{
      email: "",
      type: type && type.key,
      access: if(details.may_give_all?, do: "all", else: "some"),
      roles: []
    }
  end

  defp grant_draft(grant) do
    %{
      email: "",
      type: grant.relationship_type.key,
      access: if(grant.all_roles, do: "all", else: "some"),
      roles: Enum.map(grant.role_links, & &1.role.name)
    }
  end

  defp read_draft(draft, params) do
    %{
      draft
      | email: Map.get(params, "email", draft.email),
        type: Map.get(params, "type", draft.type),
        access: Map.get(params, "access", draft.access),
        roles: params |> Map.get("roles", []) |> List.wrap()
    }
  end

  defp finish(socket, result, message, person_uuid \\ nil)

  defp finish(socket, {:ok, _, _}, message, person_uuid),
    do: finish(socket, {:ok, :ok}, message, person_uuid)

  defp finish(socket, {:ok, %User{} = user}, message, person_uuid) do
    send(self(), {:phoenix_kit_user_updated, user})
    finish(socket, {:ok, :ok}, message, person_uuid)
  end

  defp finish(socket, {:ok, _}, message, _person_uuid) do
    {:noreply,
     socket
     |> reset_dialog()
     |> assign(notice: message, error: nil, blocked_removal: nil)
     |> load()}
  end

  defp finish(socket, {:error, reason}, _message, person_uuid) do
    blocked = if reason == :cannot_remove_last_active_manager, do: person_uuid

    {:noreply,
     socket
     |> assign(notice: nil, error: error_message(reason), blocked_removal: blocked)
     |> load()}
  end

  defp error_message(:cannot_remove_last_active_manager),
    do:
      gettext(
        "This is the organization's last manager. Add another manager first, so someone can still look after it."
      )

  defp error_message(:rate_limit_exceeded),
    do: gettext("Too many invitations. Please try again later.")

  defp error_message(:not_permitted),
    do: gettext("You can only hand out roles you have yourself.")

  defp error_message(:cannot_modify_own_roles),
    do: gettext("You can't change your own access. Ask another manager to do it.")

  defp error_message(:role_not_held),
    do: gettext("This organization doesn't have that role. Give it to the organization first.")

  defp error_message(:already_linked),
    do: gettext("This person is already here. Use Edit to change their access.")

  defp error_message(:invitation_pending),
    do:
      gettext(
        "This address already has a pending invitation with different access. Cancel it first."
      )

  defp error_message(:relationship_type_archived),
    do: gettext("That type is archived. Choose another one.")

  defp error_message(%Ecto.Changeset{}),
    do: gettext("Check the email address and required fields.")

  defp error_message(_),
    do: gettext("This change is not available. Refresh the page and check your access.")

  defp dialog_event(:add, nil), do: "invite"
  defp dialog_event(:add, %User{}), do: "add"
  defp dialog_event(%OrganizationManager{}, _selected), do: "save_link"

  defp dialog_action(:add, nil), do: gettext("Send invitation")
  defp dialog_action(:add, %User{}), do: gettext("Add person")
  defp dialog_action(%OrganizationManager{}, _selected), do: gettext("Save")

  defp admin?(%{authority: %{kind: :admin}}), do: true
  defp admin?(_details), do: false

  # A person cannot change their own link; an Owner can.
  defp editable?(grant, %{authority: authority}) do
    authority.person_uuid != grant.user_uuid or
      (authority.kind == :admin and Scope.owner?(authority.scope))
  end

  defp active_types(types, current_uuid) do
    Enum.filter(types, &(&1.status == "active" or &1.uuid == current_uuid))
  end

  defp role_labels(grant), do: Enum.map(grant.role_links, & &1.role)

  defp held?(role, details), do: Enum.any?(details.organization_roles, &(&1.uuid == role.uuid))

  defp invitation_roles(invitation, details) do
    Enum.filter(details.organization_roles, &(&1.uuid in invitation.role_uuids))
  end

  defp invitation_type(invitation, details) do
    Enum.find(details.types, &(&1.uuid == invitation.relationship_type_uuid))
  end

  # A role on the link the organization has since lost still shows, so it can go.
  defp offered_roles(details, %OrganizationManager{} = grant) do
    held = MapSet.new(details.organization_roles, & &1.uuid)
    details.organization_roles ++ Enum.reject(role_labels(grant), &MapSet.member?(held, &1.uuid))
  end

  defp offered_roles(details, _dialog), do: details.organization_roles

  defp type_hint(%RelationshipType{can_manage: true}),
    do: gettext("Can act for this organization and manage its people and profile.")

  defp type_hint(%RelationshipType{}),
    do: gettext("Can act for this organization, but not manage it.")

  defp added_line(%{granted_by: %User{} = by, inserted_at: at}) do
    gettext("Added by %{person} on %{date}",
      person: User.display_name(by),
      date: UtilsDate.format_date_with_user_format(DateTime.to_date(at))
    )
  end

  defp added_line(%{inserted_at: at}) do
    gettext("Added on %{date}",
      date: UtilsDate.format_date_with_user_format(DateTime.to_date(at))
    )
  end

  attr :type, :any, required: true
  attr :all_roles, :boolean, required: true
  attr :roles, :list, required: true
  attr :details, :map, required: true

  defp access_badges(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1">
      <span :if={@type} class="badge badge-sm badge-primary">{RelationshipTypes.name(@type)}</span>
      <span :if={@all_roles} class="badge badge-sm badge-outline">{gettext("All roles")}</span>
      <span
        :if={not @all_roles and @roles == []}
        class="badge badge-sm badge-ghost"
        title={gettext("They can enter the organization, but have no role in it.")}
      >
        {gettext("No roles")}
      </span>
      <span
        :for={role <- @roles}
        :if={not @all_roles}
        class={[
          "badge badge-sm badge-outline",
          not held?(role, @details) && "opacity-50 line-through"
        ]}
        title={
          not held?(role, @details) &&
            gettext("This organization no longer has this role, so it has no effect.")
        }
      >
        {Roles.display_name(role)}
      </span>
    </div>
    """
  end

  attr :details, :map, required: true
  attr :draft, :map, required: true
  attr :dialog, :any, required: true

  defp access_fields(assigns) do
    current_type =
      case assigns.dialog do
        %OrganizationManager{relationship_type_uuid: uuid} -> uuid
        _ -> nil
      end

    types = active_types(assigns.details.types, current_type)

    assigns =
      assign(assigns,
        types: types,
        chosen_type: Enum.find(types, &(&1.key == assigns.draft.type)),
        roles: offered_roles(assigns.details, assigns.dialog),
        fixed_all?: assigns.draft.access == "all" and not assigns.details.may_give_all?
      )

    ~H"""
    <div class="space-y-5">
      <div :if={length(@types) > 1}>
        <label class="label mb-2" for="pk-link-type">
          <span class="font-semibold">{gettext("What are they to this organization?")}</span>
        </label>
        <select id="pk-link-type" name="type" class="select w-full">
          <option :for={type <- @types} value={type.key} selected={type.key == @draft.type}>
            {RelationshipTypes.name(type)}
          </option>
        </select>
        <p :if={@chosen_type} class="text-sm text-base-content/70 mt-1">{type_hint(@chosen_type)}</p>
      </div>
      <input :if={length(@types) == 1} type="hidden" name="type" value={@draft.type} />

      <fieldset>
        <legend class="font-semibold mb-2">{gettext("Which roles can they use?")}</legend>

        <%= if @fixed_all? do %>
          <input type="hidden" name="access" value="all" />
          <p class="text-sm">{gettext("All this organization's roles")}</p>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext("Only someone with all roles can change this.")}
          </p>
        <% else %>
          <label class="flex items-start gap-3 py-1 cursor-pointer">
            <input
              type="radio"
              name="access"
              value="all"
              class="radio radio-sm mt-0.5"
              checked={@draft.access == "all"}
              disabled={not @details.may_give_all?}
            />
            <span>
              <span class="block">{gettext("All this organization's roles")}</span>
              <span class="block text-sm text-base-content/70">
                <%= if @details.may_give_all? do %>
                  {gettext("Includes any role it gets later.")}
                <% else %>
                  {gettext("Only someone with all roles can give this.")}
                <% end %>
              </span>
            </span>
          </label>
          <label class="flex items-start gap-3 py-1 cursor-pointer">
            <input
              type="radio"
              name="access"
              value="some"
              class="radio radio-sm mt-0.5"
              checked={@draft.access == "some"}
            />
            <span>{gettext("Only the roles I choose")}</span>
          </label>

          <div :if={@draft.access == "some"} class="mt-2 ml-7 space-y-2">
            <p :if={@roles == []} class="text-sm text-base-content/70">
              <%= if admin?(@details) do %>
                {gettext(
                  "This organization has no roles to choose from yet. Give it roles on its Profile tab."
                )}
              <% else %>
                {gettext("This organization has no roles to choose from yet.")}
              <% end %>
            </p>
            <p
              :if={@roles != [] and @draft.roles == []}
              class="text-sm text-base-content/70"
            >
              {gettext("With none ticked, they can enter but have no role in it.")}
            </p>
            <.role_choice
              :for={role <- @roles}
              role={role}
              checked={role.name in @draft.roles}
              locked={role.name not in @details.manageable_roles}
            />
          </div>
        <% end %>
      </fieldset>
    </div>
    """
  end

  attr :role, :any, required: true
  attr :checked, :boolean, required: true
  attr :locked, :boolean, required: true

  defp role_choice(assigns) do
    ~H"""
    <label class={["flex items-start gap-3", @locked && "opacity-60"]}>
      <%!-- A disabled box submits nothing, which would read as a removal. --%>
      <input :if={@locked and @checked} type="hidden" name="roles[]" value={@role.name} />
      <input
        type="checkbox"
        name={if not @locked, do: "roles[]"}
        value={@role.name}
        class="checkbox checkbox-sm mt-0.5"
        checked={@checked}
        disabled={@locked}
      />
      <span>
        <span class="block">{Roles.display_name(@role)}</span>
        <span :if={@locked} class="block text-sm text-base-content/70">
          {gettext("Only someone who has this role can change it.")}
        </span>
        <span
          :if={not @locked and Roles.display_description(@role)}
          class="block text-sm text-base-content/70"
        >
          {Roles.display_description(@role)}
        </span>
      </span>
    </label>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="card bg-base-100 shadow-sm my-6">
      <div :if={@details} class="card-body gap-5">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 class="card-title">{gettext("People")}</h2>
            <p :if={@details.organization.managed_by_members} class="text-sm text-base-content/70">
              {gettext("People use their own accounts to act for this organization.")}
            </p>
          </div>
          <button
            :if={@details.organization.managed_by_members}
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="open_add"
            phx-target={@myself}
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add person")}
          </button>
        </div>
        <div :if={@notice} class="alert alert-success" role="status">{@notice}</div>
        <div :if={@error && !@dialog} class="alert alert-error" role="alert">{@error}</div>
        <%= if @details.organization.managed_by_members do %>
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class="text-base-content/70">{gettext("This organization's roles:")}</span>
            <span :for={role <- @details.organization_roles} class="badge badge-sm badge-outline">
              {Roles.display_name(role)}
            </span>
            <span :if={@details.organization_roles == []} class="text-base-content/70">
              {gettext("none yet")}
            </span>
          </div>
          <p :if={@details.grants == []}>{gettext("Nobody can act for this organization yet.")}</p>
          <div :if={@details.grants != []}>
            <div
              :for={grant <- @details.grants}
              id={"#{@id}-person-#{grant.uuid}"}
              class="border-b border-base-300 py-3 last:border-b-0"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 space-y-1">
                  <div class="font-medium">{User.display_name(grant.user)}</div>
                  <div class="text-sm opacity-70 break-all">{User.delivery_email(grant.user)}</div>
                  <.access_badges
                    type={grant.relationship_type}
                    all_roles={grant.all_roles}
                    roles={role_labels(grant)}
                    details={@details}
                  />
                  <div class="text-xs opacity-60">{added_line(grant)}</div>
                </div>
                <div class="flex gap-2">
                  <button
                    :if={editable?(grant, @details)}
                    type="button"
                    class="btn btn-sm btn-outline"
                    phx-click="open_edit"
                    phx-value-uuid={grant.uuid}
                    phx-target={@myself}
                  >
                    {gettext("Edit")}
                  </button>
                  <form
                    id={"#{@id}-remove-#{grant.uuid}"}
                    phx-submit="remove"
                    phx-target={@myself}
                  >
                    <input type="hidden" name="person_uuid" value={grant.user_uuid} />
                    <button
                      type="submit"
                      class="btn btn-sm btn-error btn-outline"
                      data-confirm={
                        gettext("Remove %{person} from this organization?",
                          person: User.display_name(grant.user)
                        )
                      }
                    >{gettext("Remove")}</button>
                  </form>
                </div>
              </div>
              <form
                :if={admin?(@details) and @blocked_removal == grant.user_uuid}
                id={"#{@id}-remove-anyway-#{grant.uuid}"}
                phx-submit="remove"
                phx-target={@myself}
                class="alert alert-warning mt-3 flex flex-wrap justify-between gap-3"
              >
                <input type="hidden" name="person_uuid" value={grant.user_uuid} />
                <input type="hidden" name="allow_managerless" value="true" />
                <span class="text-sm">
                  {gettext(
                    "As an administrator you can still remove them. Nobody could then manage it."
                  )}
                </span>
                <button type="submit" class="btn btn-sm btn-warning">{gettext("Remove anyway")}</button>
              </form>
            </div>
          </div>

          <div :if={Enum.any?(@details.invitations, &(&1.status == :pending))} class="space-y-2">
            <h3 class="font-semibold">{gettext("Invited")}</h3>
            <div
              :for={invitation <- @details.invitations}
              :if={invitation.status == :pending}
              class="flex flex-wrap items-start justify-between gap-3"
            >
              <div class="min-w-0 space-y-1">
                <div class="break-all">{invitation.email}</div>
                <.access_badges
                  type={invitation_type(invitation, @details)}
                  all_roles={invitation.all_roles}
                  roles={invitation_roles(invitation, @details)}
                  details={@details}
                />
              </div>
              <button
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click="cancel"
                phx-value-uuid={invitation.uuid}
                phx-target={@myself}
              >{gettext("Cancel invitation")}</button>
            </div>
          </div>

          <form
            id={"#{@id}-contact"}
            phx-submit="contact"
            phx-target={@myself}
            class="flex flex-wrap gap-3 items-end border-t border-base-300 pt-5"
          >
            <div class="flex-1 min-w-48">
              <Input.input
                name="contact_email"
                value={@details.organization.contact_email}
                type="email"
                label={gettext("Contact email")}
              />
              <p class="text-sm text-base-content/70 mt-1">
                {gettext("Where this organization's own email goes.")}
              </p>
            </div>
            <button class="btn btn-primary" type="submit">{gettext("Save")}</button>
          </form>

          <.modal
            :if={@dialog}
            show={true}
            on_close="close_dialog"
            id={"#{@id}-dialog"}
            max_width="xl"
          >
            <:title>
              <%= if @dialog == :add do %>
                {gettext("Add a person")}
              <% else %>
                {gettext("Access for %{person}", person: User.display_name(@dialog.user))}
              <% end %>
            </:title>

            <div class="space-y-5">
              <div :if={@error} class="alert alert-error" role="alert">{@error}</div>

              <div :if={@dialog == :add and admin?(@details) and is_nil(@selected)}>
                <form
                  id={"#{@id}-search"}
                  phx-change="search"
                  phx-submit="search"
                  phx-target={@myself}
                >
                  <Input.input
                    name="query"
                    value={@query}
                    label={gettext("Find someone with an account")}
                    placeholder={gettext("Type a name, username or email")}
                    phx-debounce="300"
                  />
                </form>
                <p :if={@searched? and @people == []} class="text-sm text-base-content/70 mt-1">
                  {gettext("No active person with that name, username or email")}
                </p>
                <div :if={@people != []} class="mt-2 flex flex-wrap gap-2">
                  <button
                    :for={person <- @people}
                    type="button"
                    class="btn btn-sm btn-outline"
                    phx-click="select_person"
                    phx-value-person_uuid={person.uuid}
                    phx-target={@myself}
                  >
                    {User.display_name(person)}
                  </button>
                </div>
              </div>

              <div :if={@selected} class="flex flex-wrap items-center justify-between gap-3">
                <div class="min-w-0">
                  <div class="font-medium">{User.display_name(@selected)}</div>
                  <div class="text-sm opacity-70 break-all">{@selected.email}</div>
                </div>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="clear_person"
                  phx-target={@myself}
                >
                  {gettext("Choose someone else")}
                </button>
              </div>

              <form
                id={"#{@id}-#{if @dialog == :add, do: "invite", else: "edit"}"}
                phx-change="draft"
                phx-submit={dialog_event(@dialog, @selected)}
                phx-target={@myself}
                class="space-y-5"
              >
                <input :if={@selected} type="hidden" name="person_uuid" value={@selected.uuid} />
                <div :if={@dialog == :add and is_nil(@selected)}>
                  <Input.input
                    name="email"
                    value={@draft.email}
                    type="email"
                    required
                    label={
                      if admin?(@details),
                        do: gettext("Or invite someone by email"),
                        else: gettext("Invite someone by email")
                    }
                  />
                  <p class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "They use their own account, and accept the invitation after signing in."
                    )}
                  </p>
                </div>
                <.access_fields details={@details} draft={@draft} dialog={@dialog} />
              </form>
            </div>

            <:actions>
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="close_dialog"
                phx-target={@myself}
              >
                {gettext("Cancel")}
              </button>
              <button
                type="submit"
                class="btn btn-primary"
                form={"#{@id}-#{if @dialog == :add, do: "invite", else: "edit"}"}
              >
                {dialog_action(@dialog, @selected)}
              </button>
            </:actions>
          </.modal>
        <% end %>
        <div :if={@details.authority.kind == :admin} class="space-y-4">
          <%= if @details.organization.managed_by_members do %>
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
              <Input.input
                name="query"
                value=""
                label={gettext("Find the first manager")}
                placeholder={gettext("Type a name, username or email")}
              />
              <button type="submit" class="btn btn-outline">{gettext("Search")}</button>
            </form>
            <p :if={@searched? and @people == []} class="text-sm text-base-content/70">
              {gettext("No active person with that name, username or email")}
            </p>
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
