defmodule PhoenixKitWeb.Components.Core.CookieConsent do
  @moduledoc """
  Cookie consent widget component for GDPR/CCPA compliance.

  A refined glass-morphic consent interface with floating icon,
  preferences modal, and first-visit banner.

  ## Features

  - Floating cookie icon with position options (4 corners)
  - Glass-morphic preferences modal with category toggles
  - First-visit banner for opt-in frameworks
  - Google Consent Mode v2 integration
  - Cross-tab synchronization via localStorage
  - Dark mode support
  - Fully accessible (ARIA compliant)

  ## Examples

      <.cookie_consent
        frameworks={["gdpr"]}
        icon_position="bottom-right"
        policy_version="1.0"
        cookie_policy_url="/legal/cookie-policy"
        privacy_policy_url="/legal/privacy-policy"
        google_consent_mode={true}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  @opt_in_frameworks ~w(gdpr uk_gdpr lgpd pipeda)

  @consent_categories [
    %{
      id: "necessary",
      name: "Essential",
      icon: "🔒",
      description: "Required for core functionality. These cannot be disabled.",
      always_enabled: true
    },
    %{
      id: "analytics",
      name: "Analytics",
      icon: "📊",
      description: "Help us understand how you use our site to improve your experience."
    },
    %{
      id: "marketing",
      name: "Marketing",
      icon: "📢",
      description: "Used for personalized advertising and measuring ad effectiveness."
    },
    %{
      id: "preferences",
      name: "Preferences",
      icon: "⚙️",
      description: "Remember your settings like language and region preferences."
    }
  ]

  attr :frameworks, :list, default: [], doc: "Selected compliance frameworks"

  attr :icon_position, :string,
    default: "bottom-right",
    values: ~w(bottom-left bottom-right top-left top-right),
    doc: "Position of floating icon"

  attr :policy_version, :string, default: "1.0", doc: "Policy version for consent tracking"
  attr :cookie_policy_url, :string, default: "/legal/cookie-policy"
  attr :privacy_policy_url, :string, default: "/legal/privacy-policy"
  attr :google_consent_mode, :boolean, default: false, doc: "Enable Google Consent Mode v2"
  attr :class, :string, default: ""

  def cookie_consent(assigns) do
    show_icon = Enum.any?(assigns.frameworks, &(&1 in @opt_in_frameworks))

    assigns =
      assigns
      |> assign(:categories, @consent_categories)
      |> assign(:show_icon, show_icon)

    ~H"""
    <div
      id="pk-consent-root"
      phx-hook="CookieConsent"
      data-frameworks={Jason.encode!(@frameworks)}
      data-policy-version={@policy_version}
      data-google-consent-mode={to_string(@google_consent_mode)}
      data-icon-position={@icon_position}
      data-show-icon={to_string(@show_icon)}
      class={["pk-consent-widget", @class]}
    >
      <%!-- Custom Styles --%>
      <style>
        .pk-consent-widget {
          --pk-glass-bg: rgba(255, 255, 255, 0.85);
          --pk-glass-border: rgba(255, 255, 255, 0.3);
          --pk-glass-shadow: 0 8px 32px rgba(0, 0, 0, 0.12);
          --pk-accent: oklch(65% 0.19 255);
          --pk-accent-glow: oklch(65% 0.19 255 / 0.4);
        }

        [data-theme="dark"] .pk-consent-widget,
        .dark .pk-consent-widget {
          --pk-glass-bg: rgba(30, 30, 40, 0.9);
          --pk-glass-border: rgba(255, 255, 255, 0.1);
          --pk-glass-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
        }

        @keyframes pk-breathe {
          0%, 100% {
            box-shadow: 0 0 0 0 var(--pk-accent-glow),
                        0 4px 12px rgba(0, 0, 0, 0.15);
          }
          50% {
            box-shadow: 0 0 0 8px transparent,
                        0 4px 16px rgba(0, 0, 0, 0.2);
          }
        }

        @keyframes pk-slide-up {
          from {
            opacity: 0;
            transform: translateY(20px);
          }
          to {
            opacity: 1;
            transform: translateY(0);
          }
        }

        @keyframes pk-fade-in {
          from { opacity: 0; }
          to { opacity: 1; }
        }

        .pk-floating-icon {
          animation: pk-breathe 3s ease-in-out infinite;
          transition: transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1),
                      box-shadow 0.2s ease;
        }

        .pk-floating-icon:hover {
          transform: scale(1.1);
          animation: none;
          box-shadow: 0 0 0 4px var(--pk-accent-glow),
                      0 8px 24px rgba(0, 0, 0, 0.25);
        }

        .pk-floating-icon:active {
          transform: scale(0.95);
        }

        .pk-banner {
          animation: pk-slide-up 0.4s cubic-bezier(0.16, 1, 0.3, 1) forwards;
        }

        .pk-modal-backdrop {
          animation: pk-fade-in 0.2s ease forwards;
        }

        .pk-modal-content {
          animation: pk-slide-up 0.3s cubic-bezier(0.16, 1, 0.3, 1) forwards;
        }

        .pk-glass {
          background: var(--pk-glass-bg);
          backdrop-filter: blur(20px) saturate(180%);
          -webkit-backdrop-filter: blur(20px) saturate(180%);
          border: 1px solid var(--pk-glass-border);
          box-shadow: var(--pk-glass-shadow);
        }

        .pk-category-card {
          transition: all 0.2s ease;
        }

        .pk-category-card:hover {
          transform: translateY(-2px);
          box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
        }

        .pk-toggle-track {
          transition: background-color 0.2s ease;
        }

        .pk-toggle-thumb {
          transition: transform 0.2s cubic-bezier(0.34, 1.56, 0.64, 1);
        }

        input:checked + .pk-toggle-track .pk-toggle-thumb {
          transform: translateX(20px);
        }
      </style>

      <%!-- Floating Icon (only for opt-in frameworks) --%>
      <%= if @show_icon do %>
        <button
          id="pk-consent-icon"
          type="button"
          onclick="window.PhoenixKitConsent?.openPreferences()"
          class={[
            "pk-floating-icon pk-glass fixed z-50 w-12 h-12 rounded-full",
            "flex items-center justify-center cursor-pointer",
            "focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2",
            "transition-opacity duration-300",
            icon_position_class(@icon_position)
          ]}
          aria-label={gettext("Cookie preferences")}
          title={gettext("Cookie preferences")}
        >
          <svg class="w-6 h-6 text-primary" viewBox="0 0 24 24" fill="currentColor">
            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
          </svg>
        </button>
      <% end %>

      <%!-- First Visit Banner --%>
      <div
        id="pk-consent-banner"
        class="pk-banner pk-glass fixed bottom-0 left-0 right-0 z-50 hidden"
        role="dialog"
        aria-label={gettext("Cookie consent")}
        aria-hidden="true"
      >
        <div class="max-w-5xl mx-auto px-4 py-4 sm:px-6 sm:py-5">
          <div class="flex flex-col sm:flex-row items-start sm:items-center gap-4">
            <%!-- Cookie Icon & Text --%>
            <div class="flex-1 flex items-start gap-3">
              <div class="flex-shrink-0 w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center">
                <svg class="w-5 h-5 text-primary" viewBox="0 0 24 24" fill="currentColor">
                  <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
                </svg>
              </div>
              <div>
                <h3 class="font-semibold text-base-content text-sm sm:text-base">
                  {gettext("We value your privacy")}
                </h3>
                <p class="text-base-content/70 text-xs sm:text-sm mt-0.5 leading-relaxed max-w-xl">
                  {gettext(
                    "We use cookies to enhance your browsing experience and analyze our traffic."
                  )}
                  {" "}
                  <a
                    href={@cookie_policy_url}
                    class="link link-primary text-xs sm:text-sm"
                    target="_blank"
                  >
                    {gettext("Cookie Policy")}
                  </a>
                </p>
              </div>
            </div>

            <%!-- Action Buttons --%>
            <div class="flex items-center gap-2 w-full sm:w-auto">
              <button
                type="button"
                onclick="window.PhoenixKitConsent?.openPreferences()"
                class="btn btn-ghost btn-sm flex-1 sm:flex-none text-xs sm:text-sm"
              >
                {gettext("Customize")}
              </button>
              <button
                type="button"
                onclick="window.PhoenixKitConsent?.rejectAll()"
                class="btn btn-outline btn-sm flex-1 sm:flex-none text-xs sm:text-sm"
              >
                {gettext("Reject")}
              </button>
              <button
                type="button"
                onclick="window.PhoenixKitConsent?.acceptAll()"
                class="btn btn-primary btn-sm flex-1 sm:flex-none text-xs sm:text-sm"
              >
                {gettext("Accept All")}
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Preferences Modal --%>
      <div
        id="pk-consent-modal"
        class="fixed inset-0 z-[100] hidden"
        role="dialog"
        aria-modal="true"
        aria-label={gettext("Cookie preferences")}
      >
        <%!-- Backdrop --%>
        <div
          class="pk-modal-backdrop absolute inset-0 bg-black/40 backdrop-blur-sm"
          onclick="window.PhoenixKitConsent?.closePreferences()"
        >
        </div>

        <%!-- Modal Content --%>
        <div class="absolute inset-0 flex items-center justify-center p-4 pointer-events-none">
          <div class="pk-modal-content pk-glass rounded-2xl w-full max-w-lg max-h-[85vh] overflow-hidden pointer-events-auto">
            <%!-- Header --%>
            <div class="flex items-center justify-between px-6 py-4 border-b border-base-300/50">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center">
                  <svg class="w-5 h-5 text-primary" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z" />
                  </svg>
                </div>
                <div>
                  <h2 class="font-semibold text-lg text-base-content">
                    {gettext("Privacy Preferences")}
                  </h2>
                  <p class="text-xs text-base-content/60">
                    {gettext("Manage your cookie settings")}
                  </p>
                </div>
              </div>
              <button
                type="button"
                onclick="window.PhoenixKitConsent?.closePreferences()"
                class="btn btn-ghost btn-sm btn-circle"
                aria-label={gettext("Close")}
              >
                <svg
                  class="w-5 h-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>

            <%!-- Categories --%>
            <div class="px-6 py-4 overflow-y-auto max-h-[50vh] space-y-3">
              <%= for category <- @categories do %>
                <div class={[
                  "pk-category-card rounded-xl p-4",
                  "bg-base-200/50 border border-base-300/30"
                ]}>
                  <div class="flex items-start justify-between gap-3">
                    <div class="flex items-start gap-3 flex-1 min-w-0">
                      <span class="text-xl flex-shrink-0" role="img" aria-hidden="true">
                        {category.icon}
                      </span>
                      <div class="min-w-0">
                        <div class="flex items-center gap-2">
                          <span class="font-medium text-base-content text-sm">
                            {category.name}
                          </span>
                          <%= if Map.get(category, :always_enabled) do %>
                            <span class="badge badge-xs badge-ghost text-[10px]">
                              {gettext("Required")}
                            </span>
                          <% end %>
                        </div>
                        <p class="text-xs text-base-content/60 mt-1 leading-relaxed">
                          {category.description}
                        </p>
                      </div>
                    </div>

                    <%!-- Custom Toggle --%>
                    <label class="relative inline-flex items-center cursor-pointer flex-shrink-0">
                      <input
                        type="checkbox"
                        id={"pk-consent-#{category.id}"}
                        class="sr-only peer"
                        checked={Map.get(category, :always_enabled, false)}
                        disabled={Map.get(category, :always_enabled, false)}
                        data-category={category.id}
                      />
                      <div class={[
                        "pk-toggle-track relative w-11 h-6 rounded-full",
                        "bg-base-300 peer-checked:bg-primary",
                        "peer-disabled:opacity-60 peer-disabled:cursor-not-allowed",
                        "after:content-[''] after:absolute after:top-0.5 after:left-0.5",
                        "after:bg-white after:rounded-full after:h-5 after:w-5",
                        "after:shadow-sm after:transition-transform after:duration-200",
                        "peer-checked:after:translate-x-5",
                        "peer-focus:ring-2 peer-focus:ring-primary/30"
                      ]}>
                      </div>
                    </label>
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Footer --%>
            <div class="px-6 py-4 border-t border-base-300/50 bg-base-200/30">
              <div class="flex flex-col sm:flex-row items-stretch sm:items-center gap-3">
                <%!-- Policy Links --%>
                <div class="flex items-center gap-3 text-xs text-base-content/60">
                  <a
                    href={@privacy_policy_url}
                    class="link hover:text-primary transition-colors"
                    target="_blank"
                  >
                    {gettext("Privacy Policy")}
                  </a>
                  <span class="text-base-300">•</span>
                  <a
                    href={@cookie_policy_url}
                    class="link hover:text-primary transition-colors"
                    target="_blank"
                  >
                    {gettext("Cookie Policy")}
                  </a>
                </div>

                <%!-- Action Buttons --%>
                <div class="flex items-center gap-2 sm:ml-auto">
                  <button
                    type="button"
                    onclick="window.PhoenixKitConsent?.rejectAll()"
                    class="btn btn-ghost btn-sm flex-1 sm:flex-none text-xs"
                  >
                    {gettext("Reject All")}
                  </button>
                  <button
                    type="button"
                    onclick="window.PhoenixKitConsent?.savePreferences()"
                    class="btn btn-primary btn-sm flex-1 sm:flex-none text-xs"
                  >
                    {gettext("Save Preferences")}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Position classes for floating icon
  defp icon_position_class("bottom-left"), do: "bottom-4 left-4"
  defp icon_position_class("bottom-right"), do: "bottom-4 right-4"
  defp icon_position_class("top-left"), do: "top-4 left-4"
  defp icon_position_class("top-right"), do: "top-4 right-4"
  defp icon_position_class(_), do: "bottom-4 right-4"
end
