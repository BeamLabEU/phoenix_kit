defmodule PhoenixKitWeb.OAuth.ConsentController do
  @moduledoc """
  The consent screen of the authorization code flow:

    * `GET  <prefix>/oauth/consent/:id` - the screen of a stored request
      (`PhoenixKit.API.OAuth.Requests`; `:id` is its random capability token).
    * `POST <prefix>/oauth/consent/:id` - the answer, `decision=allow` or `decision=deny`.
    * `POST <prefix>/oauth/consent/:id/revoke` - disconnect one of the person's own grants, when
      the person is at the ceiling.

  The routes are the only ones of the flow behind `:phoenix_kit_require_authenticated`: it lets
  in any signed-in person (not only an administrator) and runs the account gate (confirmed
  e-mail, referral), and an anonymous visitor is sent to the sign-in with
  `:user_return_to` set to this very URL, so that after the sign-in they land back here. The
  controller then checks the rest itself, on a scope built from **all** of the person's roles
  (`narrow: false`, as the API computes rights):

    * not an impersonated session (`PhoenixKitWeb.Users.MultiSession.impersonated?/1`);
    * not a service account (`api_only`), not a managed organization;
    * holds `api_personal_keys` or `api`.

  Anyone else sees a page and gets no code.

  Everything the answer needs comes from the stored request, never from the form: the form
  carries only the decision, the chosen scopes (cut down to what may be offered) and the lifetime.
  The request is used once: a second click, a replayed form or a request that ran out meet the
  "start again" page. The protection against a form posted from another site is the host's
  `:browser` pipeline (`protect_from_forgery`), which these routes sit in: a host whose browser
  pipeline lacks it would let an attacker's consent id be answered from the victim's browser. A person at the ceiling of connections is not served: the page lists their
  grants and the request stays unused while they disconnect one.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Consent
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.API.OAuth.Scopes
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.OAuth.Pages
  alias PhoenixKitWeb.OAuth.Responses
  alias PhoenixKitWeb.Users.MultiSession
  alias Plug.CSRFProtection

  plug :secure_headers

  defp secure_headers(conn, _opts), do: Responses.secure(conn)

  @no_right_reasons [
    :forbidden,
    :impersonated,
    :impersonation_unknown,
    :owner_inactive,
    :owner_not_allowed
  ]

  @doc "The consent screen, or the page that says why there is none."
  def show(conn, %{"id" => id}) do
    with :ok <- enabled(conn),
         {:ok, request} <- fetch(conn, id),
         {:ok, user, scope} <- person(conn) do
      if Grants.count_live(user.uuid) >= Config.oauth_grants_per_person(),
        do: limit_page(conn, id, user),
        else: consent_page(conn, id, request, user, scope, nil)
    end
  end

  @doc "The person's answer."
  def decide(conn, %{"id" => id} = params) do
    with :ok <- enabled(conn),
         {:ok, request} <- fetch(conn, id),
         {:ok, user, scope} <- person(conn) do
      case params["decision"] do
        "allow" -> allow(conn, id, request, user, scope, params)
        "deny" -> deny(conn, request)
        _other -> start_again(conn)
      end
    end
  end

  @doc "Disconnects one grant of the person, then returns to the request."
  def revoke(conn, %{"id" => id} = params) do
    with :ok <- enabled(conn),
         {:ok, _request} <- fetch(conn, id),
         {:ok, user, _scope} <- person(conn) do
      with grant_uuid when is_binary(grant_uuid) <- params["grant"],
           %{user_uuid: owner} = grant <- Grants.get(grant_uuid),
           true <- owner == user.uuid do
        Grants.revoke(grant, actor_uuid: user.uuid)
      end

      redirect(conn, to: Routes.path("/oauth/consent/" <> id))
    end
  end

  # --- steps ---------------------------------------------------------------------------

  defp enabled(conn) do
    if Config.oauth_enabled?(), do: :ok, else: Responses.page(conn, 404, Pages.error(%{}))
  end

  defp fetch(conn, id) do
    case Requests.fetch(id) do
      {:ok, request} -> {:ok, request}
      :error -> start_again(conn)
    end
  end

  # The signed-in person and their full scope, or the page that refuses them.
  defp person(conn) do
    user = conn.assigns[:phoenix_kit_current_user]

    cond do
      is_nil(user) ->
        Responses.page(conn, 401, Pages.no_right(%{reason: :anonymous}))

      MultiSession.impersonated?(get_session(conn)) ->
        no_right(conn, :impersonated)

      user.api_only or user.managed_by_members ->
        no_right(conn, :not_allowed)

      true ->
        scope = Scope.for_user(user, narrow: false)

        if Scope.can?(scope, "api_personal_keys") or Scope.can?(scope, "api"),
          do: {:ok, user, scope},
          else: no_right(conn, :no_right)
    end
  end

  defp allow(conn, id, request, user, scope, params) do
    client = Clients.get(request.client_uuid)

    if is_nil(client) or not RedirectUri.allowed?(request.redirect_uri, snapshot_uris(request)) do
      start_again(conn)
    else
      opts = [
        scopes: list(params["scopes"]),
        days: integer(params["days"]),
        impersonated: MultiSession.impersonated?(get_session(conn)),
        ip: IpAddress.client_address(conn)
      ]

      case Consent.allow(scope, request, client, opts) do
        {:ok, code, _grant} ->
          Responses.to_client(conn, request.redirect_uri, code: code, state: request.state)

        {:error, :request_gone} ->
          start_again(conn)

        {:error, :no_scopes} ->
          conn |> put_status(422) |> consent_page(id, request, user, scope, :no_scopes)

        {:error, :grant_limit} ->
          conn |> put_status(409) |> limit_page(id, user)

        {:error, reason} when reason in @no_right_reasons ->
          no_right(conn, if(reason == :impersonated, do: :impersonated, else: :no_right))

        {:error, _other} ->
          Responses.page(conn, 400, Pages.error(%{}))
      end
    end
  end

  defp deny(conn, request) do
    case Consent.deny(request) do
      :ok ->
        Responses.to_client(conn, request.redirect_uri,
          error: "access_denied",
          error_description: "The person did not allow access.",
          state: request.state
        )

      :error ->
        start_again(conn)
    end
  end

  # --- pages -------------------------------------------------------------------------------

  defp consent_page(conn, id, %Request{} = request, user, _scope, error) do
    %{selectable: selectable, preselected: preselected} = Consent.options(user, request)
    snapshot = request.client_snapshot || %{}

    html =
      Pages.consent(%{
        csrf_token: CSRFProtection.get_csrf_token(),
        action: Routes.path("/oauth/consent/" <> id),
        client_name: Pages.client_label(snapshot["client_name"], snapshot["client_id"]),
        redirect_host: RedirectUri.host(request.redirect_uri),
        loopback?: RedirectUri.loopback?(request.redirect_uri),
        email: user.email,
        entries: Scopes.describe(selectable),
        preselected: preselected,
        days: Consent.days(),
        error: error
      })

    Responses.page(conn, conn.status || 200, html)
  end

  defp limit_page(conn, id, user) do
    html =
      Pages.limit(%{
        csrf_token: CSRFProtection.get_csrf_token(),
        action: Routes.path("/oauth/consent/" <> id <> "/revoke"),
        back: Routes.path("/oauth/consent/" <> id),
        grants: Grants.list_live(user.uuid)
      })

    Responses.page(conn, conn.status || 200, html)
  end

  defp no_right(conn, reason),
    do: Responses.page(conn, 403, Pages.no_right(%{reason: reason}))

  defp start_again(conn), do: Responses.page(conn, 400, Pages.start_again(%{}))

  defp snapshot_uris(%Request{client_snapshot: %{"redirect_uris" => uris}}) when is_list(uris),
    do: uris

  defp snapshot_uris(_request), do: []

  defp list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp list(_value), do: []

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp integer(_value), do: nil
end
