defmodule PhoenixKitWeb.Live.Users.ManagedOrganizationNew do
  @moduledoc "Creates a managed organization with an explicit first manager."
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Input

  @impl true
  def mount(_params, session, socket) do
    with {:ok, actor} <- Actor.from_session(session),
         true <- available?(actor) do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:people, [])
       |> assign(:manager, nil)
       |> assign(:error, nil)
       |> assign(:page_title, gettext("New managed organization"))
       |> assign(:page_section, gettext("Users"))
       |> assign(:page_section_path, Routes.path("/admin/users"))
       |> assign(
         :form,
         to_form(%{"organization_name" => "", "contact_email" => "", "person_uuid" => ""},
           as: :organization
         )
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(
           :error,
           gettext("Use your own administrator account to create a managed organization.")
         )
         |> push_navigate(to: Routes.path("/admin/users"))}
    end
  end

  @impl true
  def handle_event("validate", %{"organization" => attrs}, socket),
    do: {:noreply, assign(socket, :form, to_form(attrs, as: :organization))}

  # An empty query is the picker opening on focus: it answers with a first page.
  def handle_event("picker_search", %{"q" => query}, socket) when is_binary(query) do
    case available?(socket.assigns.actor) &&
           OrganizationManagers.search_for_creation(socket.assigns.actor, query) do
      {:ok, people} ->
        {:noreply, socket |> assign(:people, people) |> push_results(query, people)}

      _ ->
        {:noreply,
         socket
         |> assign(
           :error,
           gettext("This change is not available. Refresh the page and check your access.")
         )
         |> push_results(query, [])}
    end
  end

  # Only a person the search offered can be picked; `create` checks them again.
  def handle_event("picker_pick", %{"uuid" => uuid}, socket) do
    manager = Enum.find(socket.assigns.people, &(&1.uuid == uuid))
    {:noreply, socket |> assign(:manager, manager) |> assign(:error, nil)}
  end

  def handle_event("picker_clear", _params, socket),
    do: {:noreply, assign(socket, :manager, nil)}

  def handle_event("create", %{"organization" => attrs}, socket) do
    result =
      if available?(socket.assigns.actor),
        do: ManagedOrganizations.create(socket.assigns.actor, attrs, attrs["person_uuid"]),
        else: {:error, :forbidden}

    case result do
      {:ok, org} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Managed organization created"))
         |> push_navigate(to: Routes.path("/admin/users/view/#{org.uuid}"))}

      _ ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Check the organization name, contact email and first manager.")
         )}
    end
  end

  defp available?(actor),
    do: Auth.organization_accounts_enabled?() and match?({:ok, _}, Actor.admin(actor))

  defp push_results(socket, query, people) do
    results =
      Enum.map(people, fn person ->
        %{
          kind: "person",
          uuid: person.uuid,
          label: User.display_name(person),
          sublabel: User.delivery_email(person)
        }
      end)

    push_event(socket, "picker_results", %{q: query, results: results, has_more: false})
  end

  defp manager_label(nil), do: nil
  defp manager_label(person), do: "#{User.display_name(person)} (#{User.delivery_email(person)})"

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      page_title={@page_title}
      page_section={@page_section}
      page_section_path={@page_section_path}
      current_path={Routes.path("/admin/users/new/managed")}
    >
      <div class="max-w-2xl mx-auto px-4 py-6 space-y-5">
        <p>
          {gettext(
            "The organization has no login of its own. Choose an active person who will manage it using their own account."
          )}
        </p>
        <div :if={@error} class="alert alert-error" role="alert">{@error}</div>
        <.form
          for={@form}
          id="managed-organization-create"
          phx-change="validate"
          phx-submit="create"
          class="space-y-4"
        >
          <Input.input
            field={@form[:organization_name]}
            label={gettext("Organization name")}
            required
          />
          <Input.input field={@form[:contact_email]} type="email" label={gettext("Contact email")} />
          <div>
            <label class="label mb-2" for="managed-organization-manager">
              <span class="font-semibold">{gettext("First manager")}</span>
              <span class="text-error ml-0.5" aria-hidden="true">*</span>
            </label>
            <.search_picker
              id="managed-organization-manager"
              dropdown_id="managed-organization-manager-list"
              chosen={manager_label(@manager)}
              search_on_focus
              close_on_pick
              required
              placeholder={gettext("Type a name, username or email")}
              searching_label={gettext("Searching…")}
              no_matches_label={gettext("No active person with that name, username or email")}
              clear_label={gettext("Clear")}
            />
            <input
              type="hidden"
              name={@form[:person_uuid].name}
              value={@manager && @manager.uuid}
            />
          </div>
          <button type="submit" class="btn btn-primary">{gettext("Create managed organization")}</button>
        </.form>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
