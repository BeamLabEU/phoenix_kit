defmodule PhoenixKitWeb.Components.Core.LibraryLoadNotice do
  @moduledoc """
  Tells an administrator, in the page, when a viewer/editor library failed
  to load — instead of leaving them a "half working" photo viewer and a
  `console.error` to find.

  The libraries (Fresco, Tessera, Etcher, Leaf, SortableJS, Panzoom,
  wavesurfer) load lazily in the browser through the shared `loadLibrary`
  in `phoenix_kit.js`, which records each final failure and announces it as
  a `pk:library-failed` window event. This component renders a hidden shell
  carrying all the translated copy in `data-*` attributes; the
  `LibraryLoadNotice` hook fills it from the recorded failures and shows it.
  See `dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md`, Part A.

  Rendered only for the active scope's Owner, Admin or superadmin — the
  people who can act on a deployment problem. Not
  `Scope.can_access_admin_area?/1`: that is true for any single-permission
  holder, a restricted media viewer included, who can do nothing about a
  Content-Security-Policy. Everyone else gets nothing new: the features
  degrade exactly as they did.

  Sits beside the flash group in each layout shell (LayoutWrapper's
  branches and the dashboard), inside the LiveView tree; `id` keeps two
  shells on one page from colliding.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Role

  attr :scope, :any, default: nil
  attr :id, :string, default: "pk-library-notice"

  def library_load_notice(assigns) do
    ~H"""
    <div
      :if={notice_audience?(@scope)}
      id={@id}
      phx-hook="LibraryLoadNotice"
      phx-update="ignore"
      hidden
      role="alert"
      data-title={gettext("Some features on this page could not load")}
      data-csp-other={
        gettext(
          "Blocked by this site's Content-Security-Policy (%{directive}), which does not allow %{origin}."
        )
      }
      data-csp-self={
        gettext(
          "Blocked by this site's Content-Security-Policy (%{directive}). Check that the site's asset serving and its policy allow this file."
        )
      }
      data-load={
        gettext(
          "Could not be loaded or run; the cause is unknown. Check the network, and that the site's build includes PhoenixKit's JavaScript (the :phoenix_kit_js_sources compiler, or mix phoenix_kit.update)."
        )
      }
      data-audience={gettext("Only administrators see this message.")}
      class="fixed bottom-4 right-4 z-[60] w-[min(28rem,calc(100vw-2rem))] rounded-lg border border-warning/60 bg-base-100 p-3 text-sm shadow-xl"
    >
      <div class="flex items-start gap-2">
        <span class="text-warning" aria-hidden="true">⚠</span>
        <div class="min-w-0 flex-1">
          <p data-notice-title class="font-semibold"></p>
          <ul data-notice-list class="mt-1 space-y-1.5"></ul>
          <p data-notice-audience class="mt-2 text-xs text-base-content/60"></p>
        </div>
        <button
          type="button"
          data-notice-dismiss
          class="btn btn-ghost btn-xs"
          aria-label={gettext("Dismiss")}
        >
          ✕
        </button>
      </div>
    </div>
    """
  end

  @doc false
  # Owner or Admin of the ACTIVE scope (an active-role session narrows
  # `cached_roles` to the role being acted as), or the explicit superadmin
  # grant — which does not imply Owner, so both are asked.
  def notice_audience?(scope) do
    roles = Role.system_roles()

    Scope.owner?(scope) or Scope.has_role?(scope, roles.admin) or Scope.superadmin?(scope)
  end
end
