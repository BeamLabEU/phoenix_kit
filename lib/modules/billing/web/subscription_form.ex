defmodule PhoenixKit.Modules.Billing.Web.SubscriptionForm do
  @moduledoc """
  Subscription form LiveView for creating subscriptions manually.

  Allows administrators to:
  - Search and select a user by email
  - Choose a subscription plan
  - Optionally assign a payment method
  - Configure trial period
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_project_title()
      plans = Billing.list_subscription_plans(active_only: true)

      socket =
        socket
        |> assign(:page_title, "Create Subscription")
        |> assign(:project_title, project_title)
        |> assign(:plans, plans)
        |> assign(:user_search, "")
        |> assign(:user_results, [])
        |> assign(:selected_user, nil)
        |> assign(:selected_plan_uuid, nil)
        |> assign(:payment_methods, [])
        |> assign(:selected_payment_method_uuid, nil)
        |> assign(:enable_trial, false)
        |> assign(:trial_days, "")
        |> assign(:error, nil)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_user", %{"query" => query}, socket) do
    if String.length(query) >= 2 do
      results = search_users(query)
      {:noreply, assign(socket, user_search: query, user_results: results)}
    else
      {:noreply, assign(socket, user_search: query, user_results: [])}
    end
  end

  @impl true
  def handle_event("select_user", %{"id" => user_id}, socket) do
    case Auth.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found")}

      user ->
        payment_methods = Billing.list_payment_methods(user.id, status: "active")

        {:noreply,
         socket
         |> assign(:selected_user, user)
         |> assign(:user_search, user.email)
         |> assign(:user_results, [])
         |> assign(:payment_methods, payment_methods)
         |> assign(:selected_payment_method_uuid, nil)}
    end
  end

  @impl true
  def handle_event("clear_user", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_user, nil)
     |> assign(:user_search, "")
     |> assign(:user_results, [])
     |> assign(:payment_methods, [])
     |> assign(:selected_payment_method_uuid, nil)}
  end

  @impl true
  def handle_event("select_plan", %{"plan_id" => plan_id}, socket) do
    plan_id = if plan_id == "", do: nil, else: plan_id

    # Get plan's default trial days
    trial_days =
      if plan_id do
        case Enum.find(socket.assigns.plans, &(to_string(&1.uuid) == plan_id)) do
          %{trial_days: days} when is_integer(days) and days > 0 -> to_string(days)
          _ -> ""
        end
      else
        ""
      end

    {:noreply,
     socket
     |> assign(:selected_plan_uuid, plan_id)
     |> assign(:trial_days, trial_days)
     |> assign(:enable_trial, trial_days != "")}
  end

  @impl true
  def handle_event("select_payment_method", %{"payment_method_id" => pm_id}, socket) do
    pm_id = if pm_id == "", do: nil, else: pm_id
    {:noreply, assign(socket, :selected_payment_method_uuid, pm_id)}
  end

  @impl true
  def handle_event("toggle_trial", %{"enable" => enable}, socket) do
    enable = enable == "true"
    {:noreply, assign(socket, :enable_trial, enable)}
  end

  @impl true
  def handle_event("update_trial_days", %{"days" => days}, socket) do
    {:noreply, assign(socket, :trial_days, days)}
  end

  @impl true
  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  @impl true
  def handle_event("save", _params, socket) do
    %{
      selected_user: user,
      selected_plan_uuid: plan_id,
      selected_payment_method_uuid: pm_id,
      enable_trial: enable_trial,
      trial_days: trial_days
    } = socket.assigns

    cond do
      is_nil(user) ->
        {:noreply, assign(socket, :error, "Please select a customer")}

      is_nil(plan_id) ->
        {:noreply, assign(socket, :error, "Please select a plan")}

      true ->
        attrs = %{
          plan_uuid: plan_id,
          payment_method_uuid: pm_id,
          trial_days:
            if(enable_trial && trial_days != "", do: String.to_integer(trial_days), else: 0)
        }

        try do
          case Billing.create_subscription(user.uuid, attrs) do
            {:ok, subscription} ->
              {:noreply,
               socket
               |> put_flash(:info, "Subscription created successfully")
               |> push_navigate(
                 to: Routes.path("/admin/billing/subscriptions/#{subscription.uuid}")
               )}

            {:error, %Ecto.Changeset{} = changeset} ->
              error_msg = format_changeset_errors(changeset)
              {:noreply, assign(socket, :error, error_msg)}

            {:error, reason} ->
              {:noreply,
               assign(socket, :error, "Failed to create subscription: #{inspect(reason)}")}
          end
        rescue
          e ->
            require Logger
            Logger.error("Subscription save failed: #{Exception.message(e)}")
            {:noreply, put_flash(socket, :error, "Something went wrong. Please try again.")}
        end
    end
  end

  # Private helpers

  defp search_users(query) do
    # Use paginated search with small page size
    %{users: users} = Auth.list_users_paginated(search: query, page_size: 10)
    users
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  # Helper functions for template

  def format_interval(interval, interval_count) do
    case {interval, interval_count} do
      {"month", 1} -> "Monthly"
      {"month", n} -> "Every #{n} months"
      {"year", 1} -> "Yearly"
      {"year", n} -> "Every #{n} years"
      {"week", 1} -> "Weekly"
      {"week", n} -> "Every #{n} weeks"
      {"day", 1} -> "Daily"
      {"day", n} -> "Every #{n} days"
      _ -> "#{interval_count} #{interval}(s)"
    end
  end

  def format_payment_method(pm) do
    case pm.type do
      "card" ->
        brand = pm.brand || "Card"
        last4 = pm.last4 || "****"
        "#{String.capitalize(brand)} ending in #{last4}"

      type ->
        String.capitalize(type)
    end
  end
end
