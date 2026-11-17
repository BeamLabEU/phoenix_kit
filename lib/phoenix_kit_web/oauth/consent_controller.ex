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

  The request belongs to the browser that made the authorization request
  (`PhoenixKit.API.OAuth.Requests`): the page, the answer and the disconnect form find it only
  from that browser, so a consent URL relayed to a signed-in person elsewhere ("open this link to
  continue") shows "start again" and grants nothing. The sign-in does not drop the binding: it
  rides a cookie, not the session, which the sign-in clears.

  Everything the answer needs comes from the stored request, never from the form: the form
  carries only the decision, the chosen scopes (cut down to what may be offered) and the lifetime.
  The request is used once: a second click, a replayed form or a request that ran out meet the
  "start again" page. A consent id answered from the wrong browser is not found (the binding
  above), and the cookie is `SameSite=Lax`, which a cross-site form post does not carry; the
  host's `:browser` pipeline (`protect_from_forgery`), which these routes sit in, is the second
  layer, and a host whose pipeline lacks it relies on the binding alone. A client the policy
  (`PhoenixKit.API.OAuth.ClientPolicy`) no longer allows gets the error page instead of the
  screen, and no code; a "no" is always taken.

  The pages are in the language `PhoenixKitWeb.OAuth.Language` chooses: the `lang` query parameter,
  the person's `preferred_locale`, the `Accept-Language` header, the site's default, each only when
  the install has that language enabled. A `lang` the person chose on the switcher rides the form
  actions and links of the page, so the language survives the answer.

  A person at the ceiling of connections is not served: the page lists their grants and the
  request stays unused while they disconnect one.
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
  alias PhoenixKitWeb.Live.Settings.Api
  alias PhoenixKitWeb.OAuth.Language
  alias PhoenixKitWeb.OAuth.Pages
  alias PhoenixKitWeb.OAuth.Responses
  alias PhoenixKitWeb.Users.MultiSession
  alias Plug.CSRFProtection

  plug :secure_headers
  plug Language, person: true

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
         :ok <- client_allowed(conn, request),
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

  @doc """
  Disconnects one grant of the person, then returns to the request. The first answer to a
  disconnect form is a question (`Pages.confirm_disconnect/1`); the grant ends only when the
  form that question holds comes back with `confirm=yes`.
  """
  def revoke(conn, %{"id" => id} = params) do
    with :ok <- enabled(conn),
         {:ok, _request} <- fetch(conn, id),
         {:ok, user, _scope} <- person(conn) do
      case params["confirm"] do
        "yes" -> disconnect(conn, id, user, params["grant"])
        _ -> ask_disconnect(conn, id, user, params["grant"])
      end
    end
  end

  defp disconnect(conn, id, user, grant_uuid) do
    with grant_uuid when is_binary(grant_uuid) <- grant_uuid,
         %{user_uuid: owner} = grant <- Grants.get(grant_uuid),
         true <- owner == user.uuid do
      Grants.revoke(grant, actor_uuid: user.uuid)
    end

    redirect(conn, to: consent_url(conn, id))
  end

  # Only a live connection of the person is asked about; any other value goes back to the request.
  defp ask_disconnect(conn, id, user, grant_uuid) do
    case Enum.find(Grants.list_live(user.uuid), &(&1.uuid == grant_uuid)) do
      nil ->
        redirect(conn, to: consent_url(conn, id))

      grant ->
        # No switcher: this page answers a POST, and a language link is a GET.
        html =
          Pages.confirm_disconnect(
            Map.merge(Language.assigns(conn, nil), %{
              csrf_token: CSRFProtection.get_csrf_token(),
              action: revoke_url(conn, id),
              back: consent_url(conn, id),
              grant: grant
            })
          )

        Responses.page(conn, 200, html)
    end
  end

  # --- steps ---------------------------------------------------------------------------

  defp enabled(conn) do
    if Config.oauth_enabled?(), do: :ok, else: page(conn, 404, &Pages.error/1)
  end

  # The request is found only for the browser that started it (its cookie, see `Requests`): the
  # same URL in another browser is a request that is gone.
  defp fetch(conn, id) do
    case Requests.fetch(id, Responses.browser_nonce(conn)) do
      {:ok, request} -> {:ok, request}
      :error -> start_again(conn)
    end
  end

  # The client policy may have changed in the minutes the request waited: the screen is not shown
  # for a client that is no longer allowed (the answer is refused by `Consent.allow/4`).
  defp client_allowed(conn, request) do
    if Consent.client_allowed?(request),
      do: :ok,
      else: page(conn, 400, &Pages.error/1)
  end

  # The signed-in person and their full scope, or the page that refuses them.
  defp person(conn) do
    user = conn.assigns[:phoenix_kit_current_user]

    cond do
      is_nil(user) ->
        page(conn, 401, &Pages.no_right/1, %{reason: :anonymous})

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

        {:error, reason} when reason in [:request_gone, :client_gone] ->
          start_again(conn)

        {:error, :no_scopes} ->
          conn |> put_status(422) |> consent_page(id, request, user, scope, :no_scopes)

        {:error, :grant_limit} ->
          conn |> put_status(409) |> limit_page(id, user)

        {:error, :client_not_allowed} ->
          page(conn, 400, &Pages.error/1)

        {:error, reason} when reason in @no_right_reasons ->
          no_right(conn, if(reason == :impersonated, do: :impersonated, else: :no_right))

        {:error, _other} ->
          page(conn, 400, &Pages.error/1)
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
    address = RedirectUri.address(request.redirect_uri) || %{host: nil, port: nil, path: ""}

    html =
      Pages.consent(
        Map.merge(switcher(conn), %{
          csrf_token: CSRFProtection.get_csrf_token(),
          action: consent_url(conn, id),
          client_name: Pages.client_label(snapshot["client_name"], snapshot["client_id"]),
          redirect_host: host_and_port(address),
          redirect_path: address.path,
          loopback?: RedirectUri.loopback?(request.redirect_uri),
          unverified?: snapshot["kind"] != "preregistered",
          client_address: client_address(snapshot),
          email: user.email,
          sections: sections(Scopes.describe(selectable)),
          preselected: preselected,
          days: Consent.days(),
          error: error
        })
      )

    Responses.page(conn, conn.status || 200, html)
  end

  # The rights by module, each module with its reading rights and its changing ones.
  defp sections(entries) do
    entries
    |> Enum.chunk_by(& &1.module_key)
    |> Enum.map(fn [first | _] = module_entries ->
      {reads, writes} = Enum.split_with(module_entries, & &1.read?)

      %{
        key: first.module_key,
        label: Api.module_label(%{key: first.module_key, name: first.module_name}),
        reads: reads,
        writes: writes
      }
    end)
  end

  defp host_and_port(%{host: host, port: nil}), do: host
  defp host_and_port(%{host: host, port: port}), do: "#{host}:#{port}"

  # Where a metadata document client says it lives: the host of its `client_id`, shown beside
  # its self-given name so a name that borrows another brand shows another address.
  defp client_address(%{"kind" => "cimd", "client_id" => client_id}) when is_binary(client_id) do
    case URI.parse(client_id) do
      %URI{host: host} when is_binary(host) and host != "" -> Pages.client_name(host)
      _ -> nil
    end
  end

  defp client_address(_snapshot), do: nil

  defp limit_page(conn, id, user) do
    html =
      Pages.limit(
        Map.merge(switcher(conn), %{
          csrf_token: CSRFProtection.get_csrf_token(),
          action: revoke_url(conn, id),
          back: consent_url(conn, id),
          grants: Grants.list_live(user.uuid)
        })
      )

    Responses.page(conn, conn.status || 200, html)
  end

  defp no_right(conn, reason), do: page(conn, 403, &Pages.no_right/1, %{reason: reason})

  defp start_again(conn), do: page(conn, 400, &Pages.start_again/1)

  defp page(conn, status, render, assigns \\ %{}),
    do: Responses.page(conn, status, render.(Map.merge(switcher(conn), assigns)))

  # The language of the page and its switcher, which links to the consent page of this request
  # (a GET), whatever route the person is on; no links for an id that is not a token.
  defp switcher(%{path_params: %{"id" => id}} = conn) do
    if Requests.token?(id),
      do: Language.assigns(conn, consent_path(id)),
      else: Language.assigns(conn, nil)
  end

  defp switcher(conn), do: Language.assigns(conn, nil)

  defp consent_path(id), do: Routes.path("/oauth/consent/" <> id)
  defp consent_url(conn, id), do: Language.url(conn, consent_path(id))
  defp revoke_url(conn, id), do: Language.url(conn, consent_path(id) <> "/revoke")

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
