defmodule PhoenixKit.Modules.Billing.Web.Components.BillingTabs do
  @moduledoc """
  Billing-specific tab configuration for settings pages.

  Wraps the generic `nav_tabs` component with billing tab definitions.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]

  @billing_tabs [
    %{id: "general", label: "General", icon: "hero-cog-6-tooth", path: "/admin/settings/billing"},
    %{
      id: "providers",
      label: "Payment Providers",
      icon: "hero-credit-card",
      path: "/admin/settings/billing/providers"
    },
    %{
      id: "currencies",
      label: "Currencies",
      icon: "hero-currency-dollar",
      path: "/admin/billing/currencies"
    },
    %{
      id: "subscription_types",
      label: "Subscription Types",
      icon: "hero-clipboard-document-list",
      path: "/admin/billing/subscription-types"
    }
  ]

  attr :active_tab, :string,
    required: true,
    values: ~w(general providers currencies subscription_types)

  def billing_settings_tabs(assigns) do
    assigns = assign(assigns, :tabs, @billing_tabs)

    ~H"""
    <.nav_tabs active_tab={@active_tab} tabs={@tabs} class="mb-6" />
    """
  end
end
