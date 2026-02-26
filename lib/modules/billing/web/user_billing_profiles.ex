defmodule PhoenixKit.Modules.Billing.Web.UserBillingProfiles do
  @moduledoc """
  User billing profiles list LiveView.

  Allows users to manage their own billing profiles.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Events
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    user = get_current_user(socket)

    cond do
      not Billing.enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, "Billing module is not enabled")
         |> push_navigate(to: Routes.path("/dashboard"))}

      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "Please log in to view your billing profiles")
         |> push_navigate(to: Routes.path("/phoenix_kit/users/log-in"))}

      true ->
        # Subscribe to billing profile events for real-time updates
        if connected?(socket), do: Events.subscribe_profiles()

        profiles = Billing.list_user_billing_profiles(user.uuid)

        socket =
          socket
          |> assign(:page_title, "My Billing Profiles")
          |> assign(:profiles, profiles)
          |> assign(:user, user)

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("set_default", %{"uuid" => uuid}, socket) do
    profile = Enum.find(socket.assigns.profiles, &(&1.uuid == uuid))

    if profile && profile.user_uuid == socket.assigns.user.uuid do
      case Billing.set_default_billing_profile(profile) do
        {:ok, _profile} ->
          profiles = Billing.list_user_billing_profiles(socket.assigns.user.uuid)

          {:noreply,
           socket
           |> assign(:profiles, profiles)
           |> put_flash(:info, "Default profile updated")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to set default profile")}
      end
    else
      {:noreply, put_flash(socket, :error, "Profile not found")}
    end
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    profile = Enum.find(socket.assigns.profiles, &(&1.uuid == uuid))

    if profile && profile.user_uuid == socket.assigns.user.uuid do
      case Billing.delete_billing_profile(profile) do
        {:ok, _} ->
          profiles = Billing.list_user_billing_profiles(socket.assigns.user.uuid)

          {:noreply,
           socket
           |> assign(:profiles, profiles)
           |> put_flash(:info, "Profile deleted successfully")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete profile")}
      end
    else
      {:noreply, put_flash(socket, :error, "Profile not found")}
    end
  end

  # PubSub event handlers for real-time updates
  @impl true
  def handle_info({event, _profile}, socket)
      when event in [:profile_created, :profile_updated, :profile_deleted] do
    # Only refresh if we have a user assigned
    if socket.assigns[:user] do
      profiles = Billing.list_user_billing_profiles(socket.assigns.user.uuid)
      {:noreply, assign(socket, :profiles, profiles)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="p-6 max-w-4xl mx-auto">
        <%!-- Header --%>
        <div class="flex flex-col sm:flex-row justify-between items-start sm:items-center mb-8 gap-4">
          <div>
            <h1 class="text-3xl font-bold">My Billing Profiles</h1>
            <p class="text-base-content/60 mt-1">
              Manage your billing information for orders and invoices
            </p>
          </div>
          <.link
            navigate={Routes.path("/dashboard/billing-profiles/new")}
            class="btn btn-primary"
          >
            <.icon name="hero-plus" class="w-5 h-5 mr-2" /> New Profile
          </.link>
        </div>

        <%!-- Profiles List --%>
        <%= if Enum.empty?(@profiles) do %>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body text-center py-16">
              <.icon name="hero-identification" class="w-16 h-16 mx-auto mb-4 opacity-30" />
              <h2 class="text-xl font-medium text-base-content/60">No billing profiles yet</h2>
              <p class="text-base-content/50 mb-6">
                Create a billing profile to use for your orders
              </p>
              <.link navigate={Routes.path("/dashboard/billing-profiles/new")} class="btn btn-primary">
                Create Your First Profile
              </.link>
            </div>
          </div>
        <% else %>
          <div class="space-y-4">
            <%= for profile <- @profiles do %>
              <div class="card bg-base-100 shadow-lg">
                <div class="card-body">
                  <div class="flex flex-col sm:flex-row justify-between gap-4">
                    <%!-- Profile Info --%>
                    <div class="flex-1">
                      <div class="flex items-center gap-3 mb-2">
                        <span class={"badge #{if profile.type == "company", do: "badge-primary", else: "badge-secondary"}"}>
                          {String.capitalize(profile.type)}
                        </span>
                        <%= if profile.is_default do %>
                          <span class="badge badge-success">Default</span>
                        <% end %>
                      </div>

                      <%= if profile.type == "company" do %>
                        <h3 class="text-lg font-semibold">{profile.company_name}</h3>
                        <%= if profile.company_vat_number do %>
                          <p class="text-sm text-base-content/60">
                            VAT: {profile.company_vat_number}
                          </p>
                        <% end %>
                      <% else %>
                        <h3 class="text-lg font-semibold">
                          {profile.first_name} {profile.last_name}
                        </h3>
                        <%= if profile.email do %>
                          <p class="text-sm text-base-content/60">{profile.email}</p>
                        <% end %>
                      <% end %>

                      <%= if profile.address_line1 do %>
                        <p class="text-sm text-base-content/60 mt-2">
                          {profile.address_line1}
                          <%= if profile.city do %>
                            , {profile.city}
                          <% end %>
                          <%= if profile.country do %>
                            , {profile.country}
                          <% end %>
                        </p>
                      <% end %>
                    </div>

                    <%!-- Actions --%>
                    <div class="flex flex-wrap gap-2 sm:flex-col">
                      <.link
                        navigate={Routes.path("/dashboard/billing-profiles/#{profile.uuid}/edit")}
                        class="btn btn-outline btn-sm"
                      >
                        <.icon name="hero-pencil" class="w-4 h-4" /> Edit
                      </.link>

                      <%= if not profile.is_default do %>
                        <button
                          phx-click="set_default"
                          phx-value-uuid={profile.uuid}
                          class="btn btn-outline btn-sm"
                        >
                          <.icon name="hero-star" class="w-4 h-4" /> Set Default
                        </button>
                      <% end %>

                      <button
                        phx-click="delete"
                        phx-value-uuid={profile.uuid}
                        data-confirm="Are you sure you want to delete this billing profile?"
                        class="btn btn-outline btn-error btn-sm"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" /> Delete
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end

  # Private helpers

  defp get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: _} = user} -> user
      _ -> nil
    end
  end
end
