defmodule PhoenixKitWeb.Components.Core.AWSRegionSelect do
  @moduledoc """
  AWS Region Select Component.

  A component for selecting AWS regions with dynamic loading and search functionality.
  Provides a user-friendly dropdown with common regions and verification status.

  ## Features

  - Dynamic region loading from AWS API
  - Search and filter functionality
  - Loading states and error handling
  - Visual indicators for verification status
  - Keyboard navigation support

  ## Usage

      <.aws_region_select
        id="aws-region"
        name="aws_settings[region]"
        value={@aws_settings.region}
        regions={@available_regions}
        selected_region={@selected_region}
        verifying={@verifying_credentials}
        verified={@credential_verification_status}
        phx-change="select_region"
        phx-blur="fetch_available_regions"
      />
  """

  use Phoenix.Component
  import PhoenixKitWeb.Components.Core.Icon

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :regions, :list, default: []
  attr :selected_region, :string, default: ""
  attr :verifying, :boolean, default: false
  attr :verified, :atom, default: :pending, values: [:pending, :success, :error]
  attr :class, :string, default: ""
  attr :phx_change, :string, required: true

  def aws_region_select(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label" for={@id}>
        <span class="label-text font-medium">
          AWS Region
          <%= if @verified == :success do %>
            <span class="badge badge-success ml-2">Verified</span>
          <% end %>
          <%= if @verified == :error do %>
            <span class="badge badge-error ml-2">Error</span>
          <% end %>
        </span>
      </label>

      <div class="relative">
        <%= if @verifying do %>
          <!-- Loading state -->
          <div class="flex items-center justify-center h-10 bg-base-100 border border-base-300 rounded-md">
            <span class="loading loading-spinner loading-sm"></span>
            <span class="ml-2 text-sm">Loading regions...</span>
          </div>
        <% else %>
          <!-- Region dropdown -->
          <select
            id={@id}
            name={@name}
            value={@value}
            phx-change={@phx_change}
            class={[
              "select select-bordered w-full",
              "focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent",
              "transition-colors duration-200",
              if(@verified == :success, do: "border-success", else: ""),
              if(@verified == :error, do: "border-error", else: ""),
              @class
            ]}
            disabled={@verifying}
          >
            <%!-- Empty option with placeholder text (always available) --%>
            <option value="">
              <%= if Enum.empty?(@regions) do %>
                Not required - can be selected after saving credentials
              <% else %>
                Select a region (optional)
              <% end %>
            </option>

            <%!-- Show currently selected region first if it exists and not in regions list --%>
            <%= if @value != "" and @value not in @regions do %>
              <option value={@value} selected>
                {@value} (currently selected)
              </option>
            <% end %>

            <%!-- Region options from loaded list --%>
            <%= for region <- @regions do %>
              <option
                value={region}
                selected={region == @value}
                class="transition-colors duration-150 hover:bg-base-200"
              >
                {region}
              </option>
            <% end %>

            <%!-- Empty state when no regions loaded and no value --%>
            <%= if Enum.empty?(@regions) and !@verifying and @value == "" do %>
              <option disabled value="">
                Click "Refresh regions" to load available AWS regions
              </option>
            <% end %>
          </select>
          
    <!-- Status icons -->
          <div class="absolute inset-y-0 right-0 flex items-center pr-3 pointer-events-none">
            <%= case @verified do %>
              <% :success -> %>
                <.icon name="hero-check" class="w-5 h-5 text-success" />
              <% :error -> %>
                <.icon name="hero-x-mark" class="w-5 h-5 text-error" />
              <% :pending -> %>
                <.icon name="hero-information-circle" class="w-5 h-5 text-base-content/50" />
              <% nil -> %>
                <.icon name="hero-information-circle" class="w-5 h-5 text-base-content/50" />
            <% end %>
          </div>
        <% end %>
      </div>
      
    <%!-- Helper text below the select --%>
      <label class="label">
        <span class="label-text-alt text-sm text-base-content/70">
          <%= if @verified == :success do %>
            ✅ Region verified successfully. Available for AWS services.
          <% end %>

          <%= if @verified == :error do %>
            ❌ Unable to verify region. Please check your credentials.
          <% end %>

          <%= if @verified == :pending and @value != "" do %>
            Region selected. Verify credentials to confirm connectivity.
          <% end %>

          <%= if @verified == :pending and @value == "" do %>
            💡 Optional: Save credentials first, then select region and refresh list.
          <% end %>

          <%= if Enum.empty?(@regions) and @value == "" do %>
            First save your Access Key and Secret Key, then click "Refresh regions".
          <% end %>

          <%= if Enum.empty?(@regions) and @value != "" do %>
            Current region: {@value}. Click "Refresh regions" to load more options.
          <% end %>
        </span>
      </label>
    </div>
    """
  end
end
