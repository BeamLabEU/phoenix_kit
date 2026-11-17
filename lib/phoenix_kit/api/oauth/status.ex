defmodule PhoenixKit.API.OAuth.Status do
  @moduledoc """
  What an administrator looks at to see whether an application can connect: the switches, the
  addresses a client will fetch (the same ones the discovery documents publish, built from the
  same code, so this page cannot name an address the server does not serve) and the things that
  stop a connection from working.

  The report reads settings and the canonical origin only; it makes no request and shows no
  secret. The addresses are public by design (`PhoenixKit.API.OAuth.Metadata`).

  ## Warnings

    * `:admin_api_off` - OAuth needs the admin API (`api_admin_enabled`); while it is off every
      address answers 404 whatever the OAuth switch says.
    * `:origin_not_https` - the site address clients are told to use (`site_url`, else the
      endpoint's URL) is not `https`: web assistants refuse to connect to it.
    * `:allow_list_empty` - the client policy is "only the listed hosts" and the list is empty
      (or cannot be read): no application can connect, except one added by hand.
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Metadata
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.Utils.Routes

  @type warning ::
          :admin_api_off | :origin_not_https | :allow_list_empty | :approvals_waiting
  @type url_id ::
          :resource
          | :protected_resource_metadata
          | :authorization_server_metadata
          | :authorization
          | :token
          | :revocation
          | :registration

  @type t :: %{
          admin_enabled: boolean(),
          oauth_enabled: boolean(),
          dcr_enabled: boolean(),
          policy: :any | :allow_list | :approval,
          waiting: non_neg_integer(),
          issuer: String.t(),
          urls: [{url_id(), String.t()}],
          warnings: [warning()]
        }

  @doc "The report, as it stands now."
  @spec report() :: t()
  def report do
    admin? = Config.admin_enabled?()
    oauth? = Config.oauth_enabled?()
    policy = Config.oauth_client_policy()
    issuer = Resource.issuer()
    waiting = waiting()

    %{
      admin_enabled: admin?,
      oauth_enabled: oauth?,
      dcr_enabled: Config.oauth_dcr_enabled?(),
      policy: policy,
      waiting: waiting,
      issuer: issuer,
      urls: urls(issuer),
      warnings: warnings(admin?, issuer, policy, waiting)
    }
  end

  # The endpoints come out of the authorization server document, so they cannot drift from it;
  # the registration endpoint is named even while Dynamic Client Registration is off (the
  # document leaves it out then), and the page shows its state.
  defp urls(issuer) do
    document = Metadata.authorization_server()

    [
      resource: Resource.resource(),
      protected_resource_metadata: Resource.metadata_url(),
      authorization_server_metadata: issuer <> "/.well-known/oauth-authorization-server",
      authorization: document["authorization_endpoint"],
      token: document["token_endpoint"],
      revocation: document["revocation_endpoint"],
      registration: issuer <> Routes.path("/oauth/register")
    ]
  end

  defp warnings(admin?, issuer, policy, waiting) do
    Enum.reject(
      [
        if(admin?, do: nil, else: :admin_api_off),
        if(String.starts_with?(issuer, "https://"), do: nil, else: :origin_not_https),
        if(policy == :allow_list and allow_list_empty?(), do: :allow_list_empty),
        if(waiting > 0, do: :approvals_waiting)
      ],
      &is_nil/1
    )
  end

  # A report is information: a database that cannot be read shows no waiting connection rather
  # than failing the page.
  defp waiting do
    Grants.count_pending()
  rescue
    _error -> 0
  catch
    :exit, _reason -> 0
  end

  defp allow_list_empty? do
    case Config.fetch_oauth_allow_hosts() do
      {:ok, []} -> true
      {:ok, _hosts} -> false
      :unreadable -> true
    end
  end
end
