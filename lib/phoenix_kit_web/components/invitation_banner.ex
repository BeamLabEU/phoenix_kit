defmodule PhoenixKitWeb.Components.InvitationBanner do
  @moduledoc """
  Stacked alert banners for pending organization invitations.

  Rendered by LayoutWrapper when `pk_pending_invitations` is assigned
  via `PhoenixKitWeb.Hooks.InvitationHook`.

  Events are forwarded to the parent LiveView which must have the
  InvitationHook attached to handle `accept_invitation` / `decline_invitation`.
  """
  use Phoenix.Component

  @doc """
  Renders a stacked list of invitation banners, one per pending invitation.

  ## Attributes

  - `invitations` — list of `OrganizationInvitation` structs with `:organization` preloaded
  """
  attr :invitations, :list, default: []

  def invitation_banners(assigns) do
    ~H"""
    <%= for invitation <- @invitations do %>
      <.invitation_banner invitation={invitation} />
    <% end %>
    """
  end

  attr :invitation, :any, required: true

  defp invitation_banner(assigns) do
    ~H"""
    <div
      class="alert alert-info rounded-none border-b border-info-content/20 py-3"
      role="status"
      aria-live="polite"
    >
      <div class="flex w-full items-center justify-between gap-4 flex-wrap">
        <span class="text-sm">
          <strong>{@invitation.organization.organization_name}</strong>
          {" "}invited you to join their organization.
        </span>
        <div class="flex gap-2 shrink-0">
          <button
            type="button"
            class="btn btn-sm btn-success"
            phx-click="accept_invitation"
            phx-value-uuid={@invitation.uuid}
          >
            Accept
          </button>
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="decline_invitation"
            phx-value-uuid={@invitation.uuid}
          >
            Decline
          </button>
        </div>
      </div>
    </div>
    """
  end
end
