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
  alias PhoenixKitWeb.Components.Core.Select

  @impl true
  def mount(_params, session, socket) do
    with {:ok, actor} <- Actor.from_session(session),
         true <- available?(actor) do
      {:ok,
       socket
       |> assign(:actor, actor)
       |> assign(:people, [])
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

  def handle_event("search", %{"query" => query}, socket) do
    case available?(socket.assigns.actor) &&
           OrganizationManagers.search_for_creation(socket.assigns.actor, query) do
      {:ok, people} ->
        {:noreply, assign(socket, :people, people)}

      _ ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("This change is not available. Refresh the page and check your access.")
         )}
    end
  end

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
        <form id="managed-organization-search" phx-submit="search" class="flex gap-3 items-end">
          <Input.input name="query" value="" label={gettext("Find the first manager")} />
          <button type="submit" class="btn btn-outline">{gettext("Search")}</button>
        </form>
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
          <Select.select
            field={@form[:person_uuid]}
            label={gettext("First manager")}
            options={[
              {gettext("Choose a person"), ""}
              | Enum.map(@people, &{"#{User.display_name(&1)} (#{User.delivery_email(&1)})", &1.uuid})
            ]}
            required
          />
          <button type="submit" class="btn btn-primary">{gettext("Create managed organization")}</button>
        </.form>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
