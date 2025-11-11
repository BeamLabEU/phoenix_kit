defmodule PhoenixKitWeb.Components.Core.AWSCredentialsVerify do
  @moduledoc """
  AWS Credentials Verification Component.

  A component for verifying AWS credentials with real-time feedback.
  Provides validation interface for Access Key ID, Secret Access Key, and Region.

  ## Features

  - Real-time credential validation
  - Loading states and visual feedback
  - Detailed error messages
  - Integration with AWS region selector
  - Success status display with account information

  ## Usage

      <.aws_credentials_verify
        access_key_id={@aws_settings.access_key_id}
        secret_access_key={@aws_settings.secret_access_key}
        region={@aws_settings.region}
        verifying={@verifying_credentials}
        verified={@credential_verification_status}
        message={@credential_verification_message}
        phx-click="verify_aws_credentials"
        disabled={@verifying_credentials or saving}
      />
  """

  use Phoenix.Component
  import PhoenixKitWeb.Components.Core.Icon

  attr :access_key_id, :string, required: true
  attr :secret_access_key, :string, required: true
  attr :region, :string, required: true
  attr :verifying, :boolean, default: false
  attr :verified, :atom, default: :pending, values: [:pending, :success, :error]
  attr :message, :string, default: ""
  attr :disabled, :boolean, default: false
  attr :phx_click, :string, required: true
  attr :class, :string, default: ""
  attr :permissions, :map, default: %{}

  def aws_credentials_verify(assigns) do
    ~H"""
    <div class="form-control">
      <div class="flex items-center justify-between">
        <label class="label">
          <span class="label-text font-medium">
            AWS Credentials Verification
          </span>
        </label>
        
    <!-- Verify button -->
        <button
          type="button"
          phx-click={@phx_click}
          disabled={@disabled}
          class={[
            "btn btn-sm",
            "transition-all duration-200",
            "flex items-center gap-2",
            if(@verified == :success, do: "btn-success", else: ""),
            if(@verifying, do: "btn-ghost loading", else: ""),
            if(!@verified and !@verifying, do: "btn-primary", else: ""),
            if(@verified == :error, do: "btn-error", else: ""),
            @class
          ]}
        >
          <%= if @verifying do %>
            <span class="loading loading-spinner loading-xs"></span>
            <span>Verifying...</span>
          <% else %>
            <.icon name="hero-shield-check" class="w-4 h-4" />
            <span>Verify Credentials</span>
          <% end %>
        </button>
      </div>
      
    <!-- Verification status and message -->
      <div class="mt-3">
        <%= case @verified do %>
          <% :success -> %>
            <div class="alert alert-success">
              <.icon name="hero-check-circle" class="w-5 h-5" />
              <div>
                <p class="font-semibold">✅ Verification Successful</p>
                <p class="text-sm mt-1">{@message}</p>
              </div>
            </div>
          <% :error -> %>
            <div class="alert alert-error">
              <.icon name="hero-x-circle" class="w-5 h-5" />
              <div>
                <p class="font-semibold">❌ Verification Failed</p>
                <p class="text-sm mt-1">{@message}</p>
              </div>
            </div>
          <% :pending -> %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <div>
                <p class="font-semibold">Ready for Verification</p>
                <p class="text-sm mt-1">
                  Enter your AWS credentials and click "Verify Credentials" to test connectivity.
                </p>
              </div>
            </div>
          <% nil -> %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <div>
                <p class="font-semibold">Ready for Verification</p>
                <p class="text-sm mt-1">
                  Enter your AWS credentials and click "Verify Credentials" to test connectivity.
                </p>
              </div>
            </div>
        <% end %>
      </div>

      <%!-- Permissions Check Section (shown only when verification succeeded) --%>
      <%= if @verified == :success and map_size(@permissions) > 0 do %>
        <div class="mt-4 border-t border-base-300 pt-4">
          <h3 class="text-sm font-semibold mb-2 flex items-center gap-2">
            <.icon name="hero-shield-check" class="w-4 h-4" /> AWS Permissions Check
          </h3>
          <div class="alert alert-info mb-3 py-2 text-xs">
            <.icon name="hero-information-circle" class="w-4 h-4" />
            <p class="text-xs">
              ℹ️ Basic permissions checked using List operations. Actual CREATE permissions will be verified during "Setup AWS Infrastructure".
            </p>
          </div>

          <div class="space-y-3">
            <%!-- SQS Permissions --%>
            <%= if Map.has_key?(@permissions, :sqs) do %>
              <div class="bg-base-200 rounded-lg p-3">
                <h4 class="text-xs font-semibold text-base-content/70 mb-2">
                  SQS (Simple Queue Service)
                </h4>
                <div class="space-y-1">
                  <%= for {permission, status} <- @permissions.sqs do %>
                    <.permission_row permission={permission} status={status} />
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- SNS Permissions --%>
            <%= if Map.has_key?(@permissions, :sns) do %>
              <div class="bg-base-200 rounded-lg p-3">
                <h4 class="text-xs font-semibold text-base-content/70 mb-2">
                  SNS (Simple Notification Service)
                </h4>
                <div class="space-y-1">
                  <%= for {permission, status} <- @permissions.sns do %>
                    <.permission_row permission={permission} status={status} />
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- SES Permissions --%>
            <%= if Map.has_key?(@permissions, :ses) do %>
              <div class="bg-base-200 rounded-lg p-3">
                <h4 class="text-xs font-semibold text-base-content/70 mb-2">
                  SES (Simple Email Service)
                </h4>
                <div class="space-y-1">
                  <%= for {permission, status} <- @permissions.ses do %>
                    <.permission_row permission={permission} status={status} />
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- EC2 Permissions (Optional - for auto-loading regions) --%>
            <%= if Map.has_key?(@permissions, :ec2) do %>
              <div class="bg-base-200 rounded-lg p-3 border border-info/30">
                <h4 class="text-xs font-semibold text-base-content/70 mb-1 flex items-center gap-2">
                  EC2 (Optional Feature)
                  <span class="badge badge-info badge-xs">auto-loading regions</span>
                </h4>
                <p class="text-xs text-base-content/60 mb-2">
                  Used for automatic region discovery. Manual region selection available if denied.
                </p>
                <div class="space-y-1">
                  <%= for {permission, status} <- @permissions.ec2 do %>
                    <%= if permission != :optional do %>
                      <.permission_row permission={permission} status={status} />
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Warning if critical permissions are missing (SQS/SNS/SES only, EC2 is optional) --%>
          <%= if has_denied_permissions(@permissions) do %>
            <div class="alert alert-warning mt-3 text-xs">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              <div>
                <p class="font-semibold">Missing Critical Permissions (SQS/SNS/SES)</p>
                <p class="text-xs mt-1">
                  Some required List permissions are denied. "Setup AWS Infrastructure" will likely fail without CREATE permissions. Please review your IAM policy.
                </p>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper component for displaying permission row
  attr :permission, :string, required: true
  attr :status, :atom, required: true

  defp permission_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between text-xs">
      <span class="font-mono text-base-content/80">{@permission}</span>
      <%= case @status do %>
        <% :granted -> %>
          <span class="flex items-center gap-1 text-success">
            <.icon name="hero-check-circle" class="w-4 h-4" /> Granted
          </span>
        <% :denied -> %>
          <span class="flex items-center gap-1 text-error">
            <.icon name="hero-x-circle" class="w-4 h-4" /> Denied
          </span>
        <% :unknown -> %>
          <span class="flex items-center gap-1 text-warning">
            <.icon name="hero-question-mark-circle" class="w-4 h-4" /> Unknown
          </span>
      <% end %>
    </div>
    """
  end

  # Helper to check if any CRITICAL permissions are denied
  # EC2 is optional (for auto-loading regions), so we ignore it here
  defp has_denied_permissions(permissions) when is_map(permissions) do
    [:sqs, :sns, :ses]
    |> Enum.any?(fn service ->
      case Map.get(permissions, service) do
        nil ->
          false

        perms when is_map(perms) ->
          perms
          |> Enum.any?(fn
            {_perm, :denied} -> true
            _ -> false
          end)
      end
    end)
  end

  defp has_denied_permissions(_), do: false
end
