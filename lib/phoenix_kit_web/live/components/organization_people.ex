defmodule PhoenixKitWeb.Live.Components.OrganizationPeople do
  @moduledoc """
  An organization's people on the admin's page of it, changed in place: the
  mirror of a person's Organizations row (`PersonOrganizations`). Each person
  is a chip with what they can do there (the link's type, then "All roles",
  the roles on the link or "No roles"; "Member" for the older tie); × detaches
  after a one-click confirm, "+ Add" opens a search that attaches on Enter,
  and an email nobody has an account at is invited (managed organizations).
  Built on `PhoenixKit.Users.OrganizationPeople`, which goes through the core
  functions that check the actor.

  The first five people show; past that "+N more" opens the tab that lists
  them all (People, or Members for the older tie).

  ## Attrs

    * `id`, `organization` — required.
    * `actor` — the page's `ManagedOrganizations.Actor` (from the session).
    * `can_edit` — whether to offer the changes (an Owner or Admin in their
      own account). Without it the chips are read-only; the context refuses
      anyway.
    * `notice` — a line saying why nothing can be changed, when `can_edit`
      is false (`PhoenixKitWeb.Users.ManageNotice`).

  After every change the LiveView gets `{PhoenixKitWeb.Live.Components.OrganizationPeople, :changed}`
  and should reload what it shows of the organization.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.OrganizationPeople
  alias PhoenixKit.Users.PersonOrganizations
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Users.Roles

  @max_shown 5

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       adding: false,
       term: "",
       results: [],
       type_key: nil,
       confirming: nil,
       last_manager: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:organization, assigns.organization)
     |> assign(:actor, Map.get(assigns, :actor))
     |> assign(:can_edit, Map.get(assigns, :can_edit, false))
     |> assign(:notice, Map.get(assigns, :notice))
     |> assign(:entries, OrganizationPeople.list(assigns.organization))
     |> assign_new(:types, fn -> PersonOrganizations.link_types() end)}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_edit: false}} = socket),
    do: {:noreply, socket}

  def handle_event("open", _params, socket) do
    {:noreply, socket |> assign(adding: true, term: "") |> search()}
  end

  def handle_event("close", _params, socket) do
    {:noreply, close(socket)}
  end

  def handle_event("search", %{"term" => term} = params, socket) do
    {:noreply,
     socket
     |> assign(term: term, type_key: blank_to_nil(params["type"]))
     |> search()}
  end

  # Enter in the search: the first match, or an invitation to a new address.
  def handle_event("submit", %{"term" => term} = params, socket) do
    socket = socket |> assign(term: term, type_key: blank_to_nil(params["type"])) |> search()

    case socket.assigns.results do
      [person | _] -> attach(socket, person.uuid)
      [] -> invite(socket, term)
    end
  end

  def handle_event("attach", %{"uuid" => uuid}, socket), do: attach(socket, uuid)

  def handle_event("invite", _params, socket), do: invite(socket, socket.assigns.term)

  def handle_event("confirm_detach", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, confirming: uuid, last_manager: nil)}
  end

  def handle_event("cancel_detach", _params, socket) do
    {:noreply, assign(socket, confirming: nil, last_manager: nil)}
  end

  def handle_event("detach", %{"uuid" => uuid} = params, socket) do
    %{actor: actor, organization: org} = socket.assigns

    case OrganizationPeople.detach(actor, org, uuid, anyway: params["anyway"] == "true") do
      :ok ->
        {:noreply,
         socket
         |> assign(confirming: nil, last_manager: nil)
         |> changed(gettext("%{name} was removed.", name: entry_name(socket, uuid)))}

      {:error, :cannot_remove_last_active_manager} ->
        {:noreply, assign(socket, last_manager: uuid)}

      {:error, reason} ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, error_text(reason))}
    end
  end

  defp attach(socket, uuid) do
    %{actor: actor, organization: org, type_key: type_key} = socket.assigns

    name = Enum.find_value(socket.assigns.results, &(&1.uuid == uuid && User.display_name(&1)))

    case OrganizationPeople.attach(actor, org, uuid, type_key) do
      {:ok, _} ->
        {:noreply, socket |> close() |> changed(gettext("%{name} was added.", name: name || ""))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  defp invite(socket, term) do
    %{actor: actor, organization: org, type_key: type_key} = socket.assigns

    if invitable?(org, term) do
      case OrganizationPeople.invite(actor, org, term, type_key) do
        {:ok, _invitation} ->
          {:noreply,
           socket
           |> close()
           |> changed(
             gettext(
               "If this address can receive invitations, an invitation is available to its owner."
             )
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_text(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  defp search(socket) do
    exclude = Enum.map(socket.assigns.entries, & &1.person.uuid)
    assign(socket, :results, OrganizationPeople.search(socket.assigns.term, exclude))
  end

  defp close(socket), do: assign(socket, adding: false, term: "", results: [])

  defp changed(socket, message) do
    send(self(), {__MODULE__, :changed})
    put_flash(socket, :info, message)
  end

  defp entry_name(socket, uuid) do
    Enum.find_value(socket.assigns.entries, "", fn entry ->
      entry.person.uuid == uuid && User.display_name(entry.person)
    end)
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # An address nobody in the results has, for an organization people act for.
  defp invitable?(%User{managed_by_members: true}, term), do: OrganizationPeople.email?(term)
  defp invitable?(_org, _term), do: false

  defp error_text(:forbidden),
    do: gettext("Only an Owner or Admin can change an organization's people.")

  defp error_text(:manager_must_be_active_person),
    do: gettext("Only an active person account can be added to an organization.")

  defp error_text(:organization_accounts_disabled),
    do: gettext("Organization accounts are turned off in Settings → Users.")

  defp error_text(:cannot_modify_own_roles),
    do: gettext("You can't change your own access. Ask another manager to do it.")

  defp error_text(:not_permitted),
    do: gettext("You can only hand out roles you have yourself.")

  defp error_text(_reason), do: gettext("This change is not available.")

  @doc false
  def access_label(%{kind: :member}), do: [gettext("Member")]

  def access_label(%{type: type, all_roles?: all?, roles: roles}) do
    roles_text =
      cond do
        all? -> gettext("All roles")
        roles == [] -> gettext("No roles")
        true -> Enum.map_join(roles, ", ", &Roles.display_name/1)
      end

    [RelationshipTypes.name(type), roles_text]
  end

  # The tab that lists everyone: People for links, Members for the older tie.
  defp all_path(%User{managed_by_members: true} = org),
    do: "/admin/users/view/#{org.uuid}?tab=people"

  defp all_path(org), do: "/admin/users/view/#{org.uuid}?tab=members"

  @impl true
  def render(assigns) do
    shown = Enum.take(assigns.entries, @max_shown)

    assigns =
      assign(assigns,
        shown: shown,
        more: length(assigns.entries) - length(shown),
        invitable:
          assigns.adding and assigns.results == [] and
            invitable?(assigns.organization, assigns.term),
        email_typed: assigns.adding and OrganizationPeople.email?(assigns.term),
        managed?: assigns.organization.managed_by_members == true
      )

    ~H"""
    <div id={@id} class="space-y-2">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-medium text-base-content/60">{gettext("People")}:</span>

        <span :if={@entries == [] and not @can_edit} class="text-xs text-base-content/50">
          {gettext("None")}
        </span>

        <%= for entry <- @shown do %>
          <% uuid = entry.person.uuid %>
          <% name = User.display_name(entry.person) %>
          <span
            id={"#{@id}-person-#{uuid}"}
            class={[
              "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs",
              if(@confirming == uuid,
                do: "border-error bg-error/10",
                else: "border-base-300 bg-base-100"
              )
            ]}
          >
            <%= cond do %>
              <% @confirming == uuid and @last_manager == uuid -> %>
                <span>
                  {gettext("Without %{name} nobody could manage this organization.", name: name)}
                </span>
                <button
                  type="button"
                  id={"#{@id}-detach-anyway-#{uuid}"}
                  phx-click="detach"
                  phx-value-uuid={uuid}
                  phx-value-anyway="true"
                  phx-target={@myself}
                  class="btn btn-error btn-xs"
                >
                  {gettext("Remove anyway")}
                </button>
                <button
                  type="button"
                  phx-click="cancel_detach"
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                >
                  {gettext("Cancel")}
                </button>
              <% @confirming == uuid -> %>
                <span>{gettext("Remove %{name}?", name: name)}</span>
                <button
                  type="button"
                  id={"#{@id}-detach-#{uuid}"}
                  phx-click="detach"
                  phx-value-uuid={uuid}
                  phx-target={@myself}
                  class="btn btn-error btn-xs"
                >
                  {gettext("Remove")}
                </button>
                <button
                  type="button"
                  phx-click="cancel_detach"
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                >
                  {gettext("Cancel")}
                </button>
              <% true -> %>
                <.pk_link navigate={"/admin/users/view/#{uuid}"} class="font-medium hover:underline">
                  {name}
                </.pk_link>
                <span :for={part <- access_label(entry)} class="text-base-content/60">· {part}</span>
                <button
                  :if={@can_edit}
                  type="button"
                  id={"#{@id}-remove-#{uuid}"}
                  phx-click="confirm_detach"
                  phx-value-uuid={uuid}
                  phx-target={@myself}
                  class="ml-0.5 rounded-full p-0.5 opacity-60 hover:opacity-100 hover:bg-base-200"
                  aria-label={gettext("Remove %{name}", name: name)}
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
            <% end %>
          </span>
        <% end %>

        <.pk_link
          :if={@more > 0}
          id={"#{@id}-more"}
          navigate={all_path(@organization)}
          class="text-xs link link-hover text-base-content/60"
        >
          {ngettext("+%{count} more", "+%{count} more", @more)}
        </.pk_link>

        <button
          :if={@can_edit and not @adding}
          type="button"
          id={"#{@id}-open"}
          phx-click="open"
          phx-target={@myself}
          class="btn btn-ghost btn-xs gap-1"
        >
          <.icon name="hero-plus" class="w-3 h-3" /> {gettext("Add")}
        </button>
      </div>

      <p :if={not @can_edit and @notice} id={"#{@id}-notice"} class="text-xs text-base-content/60">
        <.icon name="hero-information-circle" class="w-3.5 h-3.5 inline -mt-0.5" /> {@notice}
      </p>

      <%!-- One box: type to find a person, Enter attaches the first match;
           an email nobody has an account at is invited. --%>
      <div :if={@adding} class="relative max-w-xl">
        <form
          id={"#{@id}-form"}
          phx-change="search"
          phx-submit="submit"
          phx-target={@myself}
          class="flex flex-wrap items-center gap-2"
          autocomplete="off"
        >
          <label class="input input-sm flex-1 min-w-48">
            <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-60" />
            <input
              id={"#{@id}-term"}
              type="text"
              name="term"
              value={@term}
              placeholder={
                if @managed?,
                  do: gettext("Find a person or type an email to invite"),
                  else: gettext("Find a person")
              }
              phx-debounce="150"
              phx-keydown="close"
              phx-key="Escape"
              phx-target={@myself}
              phx-mounted={Phoenix.LiveView.JS.focus()}
              class="grow"
            />
          </label>
          <select
            :if={@managed? and length(@types) > 1}
            name="type"
            class="select select-sm w-auto"
            aria-label={gettext("Link type")}
          >
            <option
              :for={type <- @types}
              value={type.key}
              selected={(@type_key || "manager") == type.key}
            >
              {gettext("as %{type}", type: RelationshipTypes.name(type))}
            </option>
          </select>
          <button
            :if={@managed?}
            type="button"
            id={"#{@id}-invite-button"}
            phx-click="invite"
            phx-target={@myself}
            disabled={not @invitable}
            class="btn btn-sm btn-primary"
            title={gettext("Invite this address")}
          >
            <.icon name="hero-envelope" class="w-4 h-4" /> {gettext("Invite")}
          </button>
          <button
            type="button"
            phx-click="close"
            phx-target={@myself}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Cancel")}
          </button>
        </form>

        <ul
          :if={@results != [] or @invitable or (@email_typed and not @managed?)}
          id={"#{@id}-results"}
          class="menu menu-sm bg-base-100 rounded-box shadow-lg border border-base-300 mt-1 w-full z-20"
        >
          <li :for={{person, index} <- Enum.with_index(@results)}>
            <button
              type="button"
              id={"#{@id}-pick-#{person.uuid}"}
              phx-click="attach"
              phx-value-uuid={person.uuid}
              phx-target={@myself}
              class={["flex justify-between", index == 0 && "menu-active"]}
            >
              <span class="truncate">
                {User.display_name(person)}
                <span class="opacity-60">· {User.delivery_email(person)}</span>
              </span>
              <span class="flex items-center gap-2 text-xs opacity-60 shrink-0">
                <span :if={
                  not @managed? and person.organization_uuid not in [nil, @organization.uuid]
                }>
                  {gettext("replaces their current one")}
                </span>
                <kbd :if={index == 0} class="kbd kbd-xs">↵</kbd>
              </span>
            </button>
          </li>
          <li :if={@invitable}>
            <button
              type="button"
              id={"#{@id}-invite"}
              phx-click="invite"
              phx-target={@myself}
              class="text-primary menu-active"
            >
              <.icon name="hero-envelope" class="w-4 h-4" />
              {gettext("Invite %{email}", email: String.trim(@term))}
              <kbd class="kbd kbd-xs ml-auto">↵</kbd>
            </button>
          </li>
          <li :if={@email_typed and not @managed? and @results == []} class="menu-disabled">
            <span class="text-xs">
              {gettext("Nobody has an account at this address.")}
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
