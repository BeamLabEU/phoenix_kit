defmodule PhoenixKitWeb.Live.Components.PersonOrganizations do
  @moduledoc """
  A person's companies on the admin's user page, changed in place: each one a
  chip (× detaches, after a one-click confirm), "+ Add" opens a search that
  attaches on Enter, and a name nobody has yet creates the company and makes
  the person its manager. Built on `PhoenixKit.Users.PersonOrganizations`,
  which goes through the core functions that check the actor.

  ## Attrs

    * `id`, `person` — required.
    * `actor` — the page's `ManagedOrganizations.Actor` (from the session).
    * `can_edit` — whether to offer the changes (an Owner or Admin not acting
      for an organization). Without it the chips are read-only; the context
      refuses anyway.
    * `notice` — a line saying why nothing can be changed, when `can_edit`
      is false (`PhoenixKitWeb.Users.ManageNotice`).

  After every change the LiveView gets `{PhoenixKitWeb.Live.Components.PersonOrganizations, :changed}`
  and should reload the person.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Users.PersonOrganizations
  alias PhoenixKit.Users.RelationshipTypes

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
     |> assign(:person, assigns.person)
     |> assign(:actor, Map.get(assigns, :actor))
     |> assign(:can_edit, Map.get(assigns, :can_edit, false))
     |> assign(:notice, Map.get(assigns, :notice))
     |> assign(:entries, PersonOrganizations.list(assigns.person))
     |> assign_new(:types, fn -> PersonOrganizations.link_types() end)}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_edit: false}} = socket),
    do: {:noreply, socket}

  def handle_event("open", _params, socket) do
    {:noreply, socket |> assign(adding: true, term: "") |> search()}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, adding: false, term: "", results: [])}
  end

  def handle_event("search", %{"term" => term} = params, socket) do
    {:noreply,
     socket
     |> assign(term: term, type_key: blank_to_nil(params["type"]))
     |> search()}
  end

  # Enter in the search: the first match, or a new company when nothing matches.
  def handle_event("submit", %{"term" => term} = params, socket) do
    socket = assign(socket, term: term, type_key: blank_to_nil(params["type"])) |> search()

    case socket.assigns.results do
      [org | _] -> attach(socket, org.uuid)
      [] -> create(socket, term)
    end
  end

  def handle_event("attach", %{"uuid" => uuid}, socket), do: attach(socket, uuid)

  def handle_event("create", _params, socket), do: create(socket, socket.assigns.term)

  def handle_event("confirm_detach", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, confirming: uuid, last_manager: nil)}
  end

  def handle_event("cancel_detach", _params, socket) do
    {:noreply, assign(socket, confirming: nil, last_manager: nil)}
  end

  def handle_event("detach", %{"uuid" => uuid} = params, socket) do
    %{actor: actor, person: person} = socket.assigns

    case PersonOrganizations.detach(actor, person, uuid, anyway: params["anyway"] == "true") do
      :ok ->
        {:noreply,
         socket
         |> assign(confirming: nil, last_manager: nil)
         |> changed(gettext("Removed from %{name}.", name: entry_name(socket, uuid)))}

      {:error, :cannot_remove_last_active_manager} ->
        {:noreply, assign(socket, last_manager: uuid)}

      {:error, reason} ->
        {:noreply, socket |> assign(confirming: nil) |> put_flash(:error, error_text(reason))}
    end
  end

  defp attach(socket, uuid) do
    %{actor: actor, person: person, type_key: type_key} = socket.assigns

    name =
      Enum.find_value(socket.assigns.results, &(&1.uuid == uuid && PersonOrganizations.name(&1)))

    case PersonOrganizations.attach(actor, person, uuid, type_key) do
      {:ok, _} ->
        {:noreply, socket |> close() |> changed(gettext("Added to %{name}.", name: name || ""))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  defp create(socket, term) do
    %{actor: actor, person: person} = socket.assigns

    case PersonOrganizations.create_and_attach(actor, person, term) do
      {:ok, org} ->
        {:noreply,
         socket
         |> close()
         |> changed(
           gettext("Created %{name} with this person as its manager.",
             name: PersonOrganizations.name(org)
           )
         )}

      {:error, :name_required} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  defp search(socket) do
    exclude = Enum.map(socket.assigns.entries, & &1.organization.uuid)
    assign(socket, :results, PersonOrganizations.search(socket.assigns.term, exclude))
  end

  defp close(socket), do: assign(socket, adding: false, term: "", results: [])

  defp changed(socket, message) do
    send(self(), {__MODULE__, :changed})
    put_flash(socket, :info, message)
  end

  defp entry_name(socket, uuid) do
    Enum.find_value(socket.assigns.entries, "", fn entry ->
      entry.organization.uuid == uuid && PersonOrganizations.name(entry.organization)
    end)
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp error_text(:forbidden),
    do: gettext("Only an Owner or Admin can change a person's organizations.")

  defp error_text(:name_taken),
    do: gettext("An organization with this name already exists. Pick it from the list.")

  defp error_text(:manager_must_be_active_person),
    do: gettext("Only an active person account can be added to an organization.")

  defp error_text(:organization_accounts_disabled),
    do: gettext("Organization accounts are turned off in Settings → Users.")

  defp error_text(%Ecto.Changeset{}), do: gettext("Check the organization's name.")
  defp error_text(_reason), do: gettext("This change is not available.")

  # A typed name that no organization has yet.
  defp can_create?(term, results) do
    name = String.trim(term)

    name != "" and
      not Enum.any?(
        results,
        &(String.downcase(&1.organization_name || "") == String.downcase(name))
      ) and
      not PersonOrganizations.name_taken?(name)
  end

  defp entry_label(%{kind: :member}), do: gettext("Member")
  defp entry_label(%{type: type}), do: RelationshipTypes.name(type)

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :creatable,
        assigns.adding and can_create?(assigns.term, assigns.results)
      )

    ~H"""
    <div id={@id} class="space-y-2">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-medium text-base-content/60">{gettext("Organizations")}:</span>

        <span
          :if={@entries == [] and not @can_edit}
          class="text-xs text-base-content/50"
        >
          {gettext("None")}
        </span>

        <%= for entry <- @entries do %>
          <% uuid = entry.organization.uuid %>
          <span
            id={"#{@id}-org-#{uuid}"}
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
                  {gettext("%{name} would have no manager.",
                    name: PersonOrganizations.name(entry.organization)
                  )}
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
                <span>
                  {gettext("Remove from %{name}?", name: PersonOrganizations.name(entry.organization))}
                </span>
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
                <.pk_link
                  navigate={"/admin/users/view/#{uuid}"}
                  class="font-medium hover:underline"
                >
                  {PersonOrganizations.name(entry.organization)}
                </.pk_link>
                <span class="text-base-content/60">· {entry_label(entry)}</span>
                <button
                  :if={@can_edit}
                  type="button"
                  id={"#{@id}-remove-#{uuid}"}
                  phx-click="confirm_detach"
                  phx-value-uuid={uuid}
                  phx-target={@myself}
                  class="ml-0.5 rounded-full p-0.5 opacity-60 hover:opacity-100 hover:bg-base-200"
                  aria-label={
                    gettext("Remove from %{name}", name: PersonOrganizations.name(entry.organization))
                  }
                >
                  <.icon name="hero-x-mark" class="w-3 h-3" />
                </button>
            <% end %>
          </span>
        <% end %>

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

      <%!-- One box: type to find a company, Enter attaches the first match;
           a name nobody has creates the company (button or Enter). --%>
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
              placeholder={gettext("Find an organization or type a new name")}
              phx-debounce="150"
              phx-keydown="close"
              phx-key="Escape"
              phx-target={@myself}
              phx-mounted={Phoenix.LiveView.JS.focus()}
              class="grow"
            />
          </label>
          <select
            :if={length(@types) > 1}
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
            type="button"
            id={"#{@id}-new"}
            phx-click="create"
            phx-target={@myself}
            disabled={not @creatable}
            class="btn btn-sm btn-primary"
            title={gettext("Create a new organization with this name")}
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New")}
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
          :if={@results != [] or @creatable}
          id={"#{@id}-results"}
          class="menu menu-sm bg-base-100 rounded-box shadow-lg border border-base-300 mt-1 w-full z-20"
        >
          <li :for={{org, index} <- Enum.with_index(@results)}>
            <button
              type="button"
              id={"#{@id}-pick-#{org.uuid}"}
              phx-click="attach"
              phx-value-uuid={org.uuid}
              phx-target={@myself}
              class={["flex justify-between", index == 0 && "menu-active"]}
            >
              <span class="truncate">{PersonOrganizations.name(org)}</span>
              <span class="flex items-center gap-2 text-xs opacity-60 shrink-0">
                <span :if={not org.managed_by_members}>
                  {if @person.organization_uuid not in [nil, org.uuid],
                    do: gettext("own login · replaces the current one"),
                    else: gettext("own login")}
                </span>
                <kbd :if={index == 0} class="kbd kbd-xs">↵</kbd>
              </span>
            </button>
          </li>
          <li :if={@creatable}>
            <button
              type="button"
              id={"#{@id}-create"}
              phx-click="create"
              phx-target={@myself}
              class={["text-primary", @results == [] && "menu-active"]}
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {gettext("Create “%{name}” with this person as manager", name: String.trim(@term))}
              <kbd :if={@results == []} class="kbd kbd-xs ml-auto">↵</kbd>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
