defmodule PhoenixKitWeb.Users.ManageNotice do
  @moduledoc """
  Why this session may not change who acts for an organization, said in a line
  instead of an empty panel or a missing button (2026-11-09, from WoodMatrix:
  an Owner who had switched to a test account saw an empty People tab).

  It reads only the shape of the session's `ManagedOrganizations.Actor`
  (`current` and `root`); `Actor.authorize/2` still decides, so a wrong guess
  here costs a sentence, never a permission.
  """
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Users.ManagedOrganizations.Actor

  @type reason :: :no_session | :switched | :acting | :not_admin

  @doc """
  The likely reason a change was refused for `actor` on `organization_uuid`:

    * `:no_session` — no session to act from;
    * `:acting` — the session acts for this organization through a link
      that does not let it do this;
    * `:switched` — the session is in a borrowed account of its stack (an
      impersonation) or another organization's slot;
    * `:not_admin` — an account of the person's own (the first one or one
      added with its password), which is neither an Owner nor an Admin.
  """
  @spec reason(term(), String.t() | nil) :: reason()
  def reason(%Actor{current: same, root: same}, _organization_uuid), do: :not_admin

  def reason(%Actor{current: {_token, uuid}}, organization_uuid)
      when is_binary(uuid) and uuid == organization_uuid,
      do: :acting

  def reason(%Actor{}, _organization_uuid), do: :switched
  def reason(_actor, _organization_uuid), do: :no_session

  @doc "The sentence for `reason/2`."
  @spec message(reason()) :: String.t()
  def message(:switched), do: gettext("Switch back to your own account to make changes here.")
  def message(:not_admin), do: gettext("Only an Owner or Admin can make changes here.")

  def message(:acting),
    do: gettext("Your link to this organization does not let you change who acts for it.")

  def message(:no_session), do: gettext("Sign in again to make changes here.")
end
