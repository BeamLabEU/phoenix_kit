defmodule PhoenixKitWeb.Live.Modules.Billing.SubscriptionPlanForm do
  @moduledoc """
  Subscription plan form LiveView for creating and editing plans.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Billing.SubscriptionPlan
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")
      default_currency = Settings.get_setting("billing_default_currency", "EUR")

      {plan, title, mode} =
        case params do
          %{"id" => id} ->
            case Billing.get_subscription_plan(id) do
              {:ok, plan} -> {plan, "Edit Plan", :edit}
              {:error, _} -> {nil, "Plan Not Found", :not_found}
            end

          _ ->
            {%SubscriptionPlan{
               currency: default_currency,
               interval: "month",
               interval_count: 1,
               active: true
             }, "Create Plan", :new}
        end

      if plan do
        changeset = SubscriptionPlan.changeset(plan, %{})

        url_path =
          case mode do
            :new -> Routes.path("/admin/billing/plans/new")
            :edit -> Routes.path("/admin/billing/plans/#{plan.id}/edit")
            _ -> Routes.path("/admin/billing/plans")
          end

        socket =
          socket
          |> assign(:page_title, title)
          |> assign(:project_title, project_title)
          |> assign(:url_path, url_path)
          |> assign(:mode, mode)
          |> assign(:plan, plan)
          |> assign(:changeset, changeset)
          |> assign(:features_input, format_features(plan.features))
          |> assign(:form, to_form(changeset))

        {:ok, socket}
      else
        {:ok,
         socket
         |> put_flash(:error, "Plan not found")
         |> push_navigate(to: Routes.path("/admin/billing/plans"))}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"subscription_plan" => params}, socket) do
    params = process_params(params, socket.assigns.features_input)

    changeset =
      socket.assigns.plan
      |> SubscriptionPlan.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("update_features", %{"features" => features}, socket) do
    {:noreply, assign(socket, :features_input, features)}
  end

  @impl true
  def handle_event("save", %{"subscription_plan" => params}, socket) do
    params = process_params(params, socket.assigns.features_input)

    result =
      case socket.assigns.mode do
        :new -> Billing.create_subscription_plan(params)
        :edit -> Billing.update_subscription_plan(socket.assigns.plan, params)
      end

    case result do
      {:ok, _plan} ->
        {:noreply,
         socket
         |> put_flash(:info, plan_saved_message(socket.assigns.mode))
         |> push_navigate(to: Routes.path("/admin/billing/plans"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save plan: #{inspect(reason)}")}
    end
  end

  defp process_params(params, features_input) do
    # Parse features from textarea (one per line)
    features =
      features_input
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # Parse price from string to decimal
    price =
      case params["price"] do
        "" -> nil
        nil -> nil
        p when is_binary(p) -> Decimal.new(p)
        p -> p
      end

    params
    |> Map.put("features", features)
    |> Map.put("price", price)
  end

  defp format_features(nil), do: ""
  defp format_features(features) when is_list(features), do: Enum.join(features, "\n")
  defp format_features(_), do: ""

  defp plan_saved_message(:new), do: "Plan created successfully"
  defp plan_saved_message(:edit), do: "Plan updated successfully"

  def error_to_string([]), do: ""

  def error_to_string(errors) when is_list(errors) do
    Enum.map_join(errors, ", ", fn
      {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      msg when is_binary(msg) ->
        msg
    end)
  end
end
