defmodule PhoenixKit.API.OAuth.StatusTest do
  @moduledoc """
  The report of the OAuth tab of Settings -> API: its addresses are the ones the server publishes
  and serves, and each thing that stops a connection is a named warning.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.API.OAuth.Metadata
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Status
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  setup do
    start_cache_registry!()
    :ok
  end

  defp url(report, id), do: Keyword.fetch!(report.urls, id)

  test "names every address a client fetches, the way the discovery documents name them" do
    report = Status.report()
    document = Metadata.authorization_server()

    assert url(report, :resource) == Resource.resource()
    assert url(report, :protected_resource_metadata) == Resource.metadata_url()
    assert url(report, :authorization) == document["authorization_endpoint"]
    assert url(report, :token) == document["token_endpoint"]
    assert url(report, :revocation) == document["revocation_endpoint"]

    assert url(report, :authorization_server_metadata) ==
             report.issuer <> "/.well-known/oauth-authorization-server"

    assert url(report, :registration) ==
             report.issuer <> Routes.path("/oauth/register")

    assert Enum.all?(report.urls, fn {_id, url} -> String.starts_with?(url, report.issuer) end)
  end

  test "a fresh install: everything off, the admin API is the first thing to switch on" do
    report = Status.report()

    refute report.oauth_enabled
    refute report.dcr_enabled
    assert report.policy == :any
    assert :admin_api_off in report.warnings
  end

  test "the switches show as they are, and DCR counts only while OAuth is on" do
    write_setting(fn -> Settings.update_boolean_setting("api_admin_enabled", true) end)
    write_setting(fn -> Settings.update_boolean_setting("api_oauth_dcr_enabled", true) end)
    refute Status.report().dcr_enabled

    write_setting(fn -> Settings.update_boolean_setting("api_oauth_enabled", true) end)
    report = Status.report()

    assert report.oauth_enabled and report.dcr_enabled
    refute :admin_api_off in report.warnings
  end

  test "an allow-list policy with no hosts is a warning, and goes away with a host" do
    write_setting(fn -> Settings.update_setting("api_oauth_client_policy", "allow_list") end)
    assert :allow_list_empty in Status.report().warnings

    write_setting(fn -> Settings.update_setting("api_oauth_client_allow_hosts", "claude.ai") end)
    refute :allow_list_empty in Status.report().warnings
  end

  test "a site address that is not https is a warning, an https one is not" do
    report = Status.report()

    assert :origin_not_https in report.warnings ==
             not String.starts_with?(report.issuer, "https://")
  end
end
