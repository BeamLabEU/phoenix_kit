defmodule PhoenixKitWeb.Hooks.InvitationHook do
  @moduledoc """
  LiveView on_mount hook for organization invitation banners.

  Loads pending invitations once per mount for confirmed person accounts,
  assigns them as `pk_pending_invitations`, and attaches event handlers
  for accept/decline actions.

  ## Usage in parent app router

      live_session :authenticated, on_mount: [PhoenixKitWeb.Hooks.InvitationHook] do
        ...
      end

  ## Events handled

  - `"accept_invitation"` — `phx-value-uuid` required
  - `"decline_invitation"` — `phx-value-uuid` required
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias PhoenixKit.Users.Invitations

  @doc false
  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:phoenix_kit_current_user]

    if confirmed_person?(user) do
      pending = Invitations.list_pending_for_email(user.email)

      socket =
        socket
        |> assign(:pk_pending_invitations, pending)
        |> attach_hook(:invitation_events, :handle_event, &handle_invitation_event/3)

      {:cont, socket}
    else
      {:cont, assign(socket, :pk_pending_invitations, [])}
    end
  end

  # Private Helpers

  defp confirmed_person?(nil), do: false

  defp confirmed_person?(%{account_type: "person", confirmed_at: confirmed_at})
       when not is_nil(confirmed_at),
       do: true

  defp confirmed_person?(_), do: false

  defp handle_invitation_event("accept_invitation", %{"uuid" => uuid}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    case Invitations.accept_invitation_by_uuid(uuid, user) do
      {:ok, {_inv, updated_user}} ->
        pending = Invitations.list_pending_for_email(updated_user.email)

        socket =
          socket
          |> assign(:phoenix_kit_current_user, updated_user)
          |> assign(:pk_pending_invitations, pending)
          |> put_flash(:info, "You joined the organization!")

        {:halt, socket}

      {:error, :expired} ->
        {:halt, put_flash(socket, :error, "This invitation has expired.")}

      {:error, _} ->
        {:halt, put_flash(socket, :error, "Failed to accept invitation. Please try again.")}
    end
  end

  defp handle_invitation_event("decline_invitation", %{"uuid" => uuid}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    case Invitations.decline_invitation_by_uuid(uuid) do
      {:ok, _} ->
        pending = Invitations.list_pending_for_email(user.email)

        socket =
          socket
          |> assign(:pk_pending_invitations, pending)
          |> put_flash(:info, "Invitation declined.")

        {:halt, socket}

      {:error, _} ->
        {:halt, put_flash(socket, :error, "Failed to decline invitation. Please try again.")}
    end
  end

  defp handle_invitation_event(_event, _params, socket) do
    {:cont, socket}
  end
end
