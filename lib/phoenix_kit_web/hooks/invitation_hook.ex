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

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations.Sessions, as: OrganizationSessions
  alias PhoenixKitWeb.Users.MultiSession

  @doc false
  def on_mount(
        :default,
        _params,
        _session,
        %{assigns: %{pk_invitation_hook_attached: true}} = socket
      ),
      do: {:cont, socket}

  def on_mount(:default, _params, session, socket) do
    socket = assign(socket, :pk_invitation_hook_attached, true)
    user = socket.assigns[:phoenix_kit_current_user]

    if confirmed_person?(user) and not MultiSession.impersonated?(session) do
      pending = Invitations.list_pending_for_email(user.email)

      socket =
        socket
        |> assign(:pk_invitation_session, session_ref(session))
        |> assign_pending(pending)
        |> attach_hook(:invitation_events, :handle_event, &handle_invitation_event/3)

      {:cont, socket}
    else
      {:cont, assign_pending(socket, [])}
    end
  end

  # Private Helpers

  defp assign_pending(socket, pending) do
    socket = assign(socket, :pk_pending_invitations, pending)

    case socket.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope ->
        assign(socket, :phoenix_kit_current_scope, %{scope | pending_invitations: pending})

      _ ->
        socket
    end
  end

  defp session_ref(session) do
    case SessionRef.from_session(session) do
      {:ok, ref} -> ref
      _ -> nil
    end
  end

  defp confirmed_person?(%{api_only: true}), do: false
  defp confirmed_person?(%{is_active: false}), do: false
  defp confirmed_person?(nil), do: false

  defp confirmed_person?(%{account_type: "person", confirmed_at: confirmed_at})
       when not is_nil(confirmed_at),
       do: true

  # With `require_email_confirmation` off, an unconfirmed account is a fully
  # usable one — gating the banner on `confirmed_at` would leave an invited
  # user no way to join their organization at all, since the auto-accept path
  # also only runs on confirmation.
  defp confirmed_person?(%{account_type: "person"}),
    do: not PhoenixKit.Settings.get_boolean_setting("require_email_confirmation", true)

  defp confirmed_person?(_), do: false

  defp current_user(socket) do
    with {token, uuid} <- socket.assigns[:pk_invitation_session],
         {:ok, scope} <- SessionRef.scope_for_session(token, uuid) do
      {:ok, scope.user}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp refresh_scope(socket) do
    case socket.assigns[:pk_invitation_session] do
      {token, uuid} ->
        case SessionRef.scope_for_session(token, uuid) do
          {:ok, fresh} ->
            scope = socket.assigns[:phoenix_kit_current_scope] || fresh

            organizations =
              if Auth.organization_accounts_enabled?(),
                do: OrganizationSessions.list_for(uuid),
                else: []

            scope = %{
              fresh
              | multi_session_accounts: scope.multi_session_accounts,
                multi_session_allowed?: scope.multi_session_allowed?,
                pending_invitations: scope.pending_invitations,
                organization_root: fresh.user,
                acting_organizations: organizations
            }

            socket
            |> assign(:phoenix_kit_current_user, fresh.user)
            |> assign(:phoenix_kit_current_scope, scope)

          _ ->
            socket
        end

      _ ->
        socket
    end
  end

  defp handle_invitation_event("accept_invitation", %{"uuid" => uuid}, socket) do
    result =
      with {:ok, user} <- current_user(socket),
           do: Invitations.accept_invitation_by_uuid(uuid, user)

    case result do
      {:ok, {invitation, updated_user}} ->
        pending = Invitations.list_pending_for_email(updated_user.email)

        socket =
          socket
          |> assign(:phoenix_kit_current_user, updated_user)
          |> assign_pending(pending)
          |> refresh_scope()
          |> put_flash(
            :info,
            if(invitation.kind == :manager,
              do: gettext("You can now act for the organization."),
              else: gettext("You joined the organization!")
            )
          )

        {:halt, socket}

      {:error, :expired} ->
        {:halt, put_flash(socket, :error, gettext("This invitation has expired."))}

      {:error, _} ->
        {:halt,
         put_flash(socket, :error, gettext("Failed to accept invitation. Please try again."))}
    end
  end

  defp handle_invitation_event("decline_invitation", %{"uuid" => uuid}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    result =
      with {:ok, fresh} <- current_user(socket),
           do: Invitations.decline_invitation_by_uuid(uuid, fresh)

    case result do
      {:ok, _} ->
        pending = Invitations.list_pending_for_email(user.email)

        socket =
          socket
          |> assign_pending(pending)
          |> put_flash(:info, gettext("Invitation declined."))

        {:halt, socket}

      {:error, _} ->
        {:halt,
         put_flash(socket, :error, gettext("Failed to decline invitation. Please try again."))}
    end
  end

  defp handle_invitation_event(_event, _params, socket) do
    {:cont, socket}
  end
end
