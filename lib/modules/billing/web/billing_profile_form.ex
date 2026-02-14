defmodule PhoenixKit.Modules.Billing.Web.BillingProfileForm do
  @moduledoc """
  Billing profile form LiveView for creating and editing billing profiles.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.BillingProfile
  alias PhoenixKit.Modules.Billing.CountryData
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_project_title()
      %{users: users} = Auth.list_users_paginated(limit: 100)
      countries = CountryData.countries_for_select()

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:users, users)
        |> assign(:countries, countries)
        |> assign(:profile_type, "individual")
        |> load_profile(params["id"])

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  defp load_profile(socket, nil) do
    # New profile
    changeset = Billing.change_billing_profile(%BillingProfile{type: "individual"})

    socket
    |> assign(:page_title, "New Billing Profile")
    |> assign(:url_path, Routes.path("/admin/billing/profiles/new"))
    |> assign(:profile, nil)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_user_uuid, nil)
    |> assign(:subdivision_label, "Region")
  end

  defp load_profile(socket, id) do
    case Billing.get_billing_profile(id) do
      nil ->
        socket
        |> put_flash(:error, "Billing profile not found")
        |> push_navigate(to: Routes.path("/admin/billing/profiles"))

      profile ->
        changeset = Billing.change_billing_profile(profile)

        socket
        |> assign(:page_title, "Edit Billing Profile")
        |> assign(:url_path, Routes.path("/admin/billing/profiles/#{profile.uuid}/edit"))
        |> assign(:profile, profile)
        |> assign(:form, to_form(changeset))
        |> assign(:selected_user_uuid, profile.user_uuid)
        |> assign(:profile_type, profile.type)
        |> assign(:subdivision_label, CountryData.get_subdivision_label(profile.country))
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_user", %{"user_id" => user_id}, socket) do
    user_id = if user_id == "", do: nil, else: user_id
    {:noreply, assign(socket, :selected_user_uuid, user_id)}
  end

  @impl true
  def handle_event("change_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :profile_type, type)}
  end

  @impl true
  def handle_event("validate", %{"billing_profile" => params}, socket) do
    changeset =
      (socket.assigns.profile || %BillingProfile{})
      |> Billing.change_billing_profile(params)
      |> Map.put(:action, :validate)

    # Update subdivision label when country changes
    subdivision_label = CountryData.get_subdivision_label(params["country"])

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:subdivision_label, subdivision_label)}
  end

  @impl true
  def handle_event("save", %{"billing_profile" => params}, socket) do
    params =
      params
      |> Map.put("user_uuid", socket.assigns.selected_user_uuid)
      |> Map.put("type", socket.assigns.profile_type)

    save_profile(socket, params)
  end

  defp save_profile(socket, params) do
    result =
      if socket.assigns.profile do
        Billing.update_billing_profile(socket.assigns.profile, params)
      else
        case socket.assigns.selected_user_uuid do
          nil ->
            {:error, :no_user}

          user_id ->
            Billing.create_billing_profile(user_id, params)
        end
      end

    case result do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> put_flash(:info, "Billing profile saved successfully")
         |> push_navigate(to: Routes.path("/admin/billing/profiles"))}

      {:error, :no_user} ->
        {:noreply, put_flash(socket, :error, "Please select a user")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
