defmodule PhoenixKit.API.OAuth.Consent do
  @moduledoc """
  What a person's answer to a waiting authorization request does (`PhoenixKit.API.OAuth.Requests`).

  ## What may be offered

  `options/2` lists the scopes the person can hand out: the ones they hold right now
  (`PhoenixKit.API.Keys.allowed_scopes_for/1`, computed from **all** their roles, as the API
  does), and, when the client asked for particular scopes, only those. The preselection is the
  **reading** scopes among them (when the client asked for none: all the reading scopes the
  person holds): writing is never on unless the person turns it on, whatever the client asked.

  ## Allowing

  `allow/4` runs in one transaction: the request is used (atomically: a second click or a
  replayed form finds it gone), the grant and its hidden key are made under the person's
  advisory lock with the ceiling counted inside it (`PhoenixKit.API.OAuth.Grants.create/4`), and
  the authorization code is issued. Any refusal rolls all of it back, **the request included**,
  so a person who is turned away at the ceiling can revoke a grant and carry on with the same
  request. The grant is not active yet: it becomes so when the code is exchanged.

  ## Denying

  `deny/1` only uses the request up.
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Codes
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.API.OAuth.Scopes
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  @default_days 30
  @day_choices [1, 7, 30, 90, 180, 365]

  @type options :: %{selectable: [String.t()], preselected: [String.t()]}

  @doc "The scopes `user` can offer for `request` and the ones to preselect (see the moduledoc)."
  @spec options(User.t(), Request.t()) :: options()
  def options(%User{} = user, %Request{requested_scopes: requested}) do
    allowed = Keys.allowed_scopes_for(user)

    # A client that named scopes gets at most those; when it named none the person may grant
    # anything they hold. Scopes it named that the person does not hold are not replaced by
    # others: the person is offered nothing rather than more than was asked.
    selectable =
      if requested == [], do: allowed, else: Enum.filter(requested, &(&1 in allowed))

    %{selectable: selectable, preselected: Enum.filter(selectable, &Scopes.read?/1)}
  end

  @doc "How long a grant may last: `{default_days, [day choices up to the personal key ceiling]}`."
  @spec days() :: {pos_integer(), [pos_integer()]}
  def days do
    max_days = PersonalKeysConfig.max_days()
    default = min(@default_days, max_days)

    choices =
      [default | @day_choices]
      |> Enum.filter(&(&1 <= max_days))
      |> Enum.uniq()
      |> Enum.sort()

    {default, choices}
  end

  @doc """
  Turns the person's choice into a grant and a code.

  `chosen` are the scope names the form sent: only those among `options/2`'s `selectable` are
  kept, and an empty result is `{:error, :no_scopes}`. `days` is clamped to `days/0`'s range.
  `opts` take `:impersonated` (boolean, required; an impersonated session may not connect an
  application) and `:ip`.

  Returns `{:ok, code, grant}`, or `{:error, reason}`: `:request_gone` (used or run out),
  `:no_scopes`, `:grant_limit` (the person already has as many live grants as the ceiling
  allows), and the refusals of `PhoenixKit.API.Keys.create_oauth_key/3` (`:forbidden`,
  `:impersonated`, `:owner_inactive`, `:owner_not_allowed`, ...).
  """
  @spec allow(Scope.t(), Request.t(), Client.t(), keyword()) ::
          {:ok, String.t(), PhoenixKit.API.OAuth.Grant.t()} | {:error, term()}
  def allow(%Scope{user: %User{} = user} = scope, %Request{} = request, %Client{} = client, opts) do
    %{selectable: selectable} = options(user, request)
    scopes = opts |> Keyword.get(:scopes, []) |> Enum.filter(&(&1 in selectable)) |> Enum.uniq()

    if scopes == [] do
      {:error, :no_scopes}
    else
      attrs = %{
        scopes: scopes,
        expires_at: expiry(Keyword.get(opts, :days)),
        resource: request.resource,
        created_ip: Keyword.get(opts, :ip)
      }

      grant_opts = [
        impersonated: Keyword.get(opts, :impersonated),
        ceiling: Config.oauth_grants_per_person()
      ]

      case repo().transaction(fn -> make(scope, request, client, attrs, grant_opts) end) do
        {:ok, {code, grant}} -> {:ok, code, grant}
        {:error, _reason} = error -> error
      end
    end
  end

  defp make(scope, request, client, attrs, grant_opts) do
    with :ok <- use_up(request),
         {:ok, grant, _key} <- Grants.create(scope, client, attrs, grant_opts),
         {:ok, code, _row} <-
           Codes.issue(grant, %{
             redirect_uri: request.redirect_uri,
             code_challenge: request.code_challenge
           }) do
      {code, grant}
    else
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp use_up(request) do
    case Requests.consume(request) do
      :ok -> :ok
      :error -> {:error, :request_gone}
    end
  end

  @doc "The person said no: the request is used up. `:ok`, or `:error` when it already was."
  @spec deny(Request.t()) :: :ok | :error
  def deny(%Request{} = request), do: Requests.consume(request)

  defp expiry(days) do
    {default, _choices} = days()

    days =
      if is_integer(days) and days >= 1,
        do: min(days, PersonalKeysConfig.max_days()),
        else: default

    DateTime.add(DateTime.utc_now(), days * 86_400, :second)
  end

  defp repo, do: RepoHelper.repo()
end
