defmodule PhoenixKitWeb.Live.Settings.IntegrationFormObjectStorageTest do
  @moduledoc """
  The Object Storage form opens on a choice of service and asks only what that
  service needs (`ObjectStorageServices`). Checked through the system form; the
  personal one renders through the same functions.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKit.Utils.Routes

  @new_path Routes.path("/admin/settings/integrations/new?provider=object_storage")

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")
    %{conn: log_in_user(conn, user)}
  end

  defp field?(html, key), do: html =~ ~s(name="#{key}" id="field-#{key}")

  defp choose(view, service) do
    view |> element("#integration-setup-form") |> render_change(%{"service" => service})
  end

  test "opens on the service choice alone", %{conn: conn} do
    {:ok, view, html} = live(conn, @new_path)

    assert has_element?(view, "#integration-setup-form[phx-change=setup_changed]")
    refute has_element?(view, "#field-service[phx-change]")
    assert field?(html, "service")
    assert html =~ "Choose a service"
    refute field?(html, "access_key")
    refute field?(html, "region")
  end

  test "choosing a service shows its fields", %{conn: conn} do
    {:ok, view, _html} = live(conn, @new_path)

    html = choose(view, "aws_s3")
    assert field?(html, "region")
    assert html =~ "Europe (Frankfurt)"
    assert field?(html, "access_key")
    refute field?(html, "endpoint")

    html = choose(view, "cloudflare_r2")
    assert field?(html, "account_id")
    refute field?(html, "region")

    html = choose(view, "backblaze_b2")
    assert field?(html, "region")
    assert html =~ ~s(list="field-region-options")
    assert html =~ "Application Key ID"

    html = choose(view, "other")
    assert field?(html, "endpoint")
    refute field?(html, "account_id")
  end

  test "switching service keeps the keys typed so far", %{conn: conn} do
    {:ok, view, _html} = live(conn, @new_path)

    # The change event carries the whole form, as the browser sends it.
    view
    |> element("#integration-setup-form")
    |> render_change(%{
      "service" => "aws_s3",
      "access_key" => "AKIATYPED",
      "region" => "eu-north-1"
    })

    html = choose(view, "wasabi")

    assert html =~ "AKIATYPED"
    refute html =~ "eu-north-1"
  end

  test "editing a legacy R2 connection preserves its endpoint and saved secret", %{conn: conn} do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "legacy r2")
    endpoint = "acct.eu.r2.cloudflarestorage.com"

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "access_key" => "K",
        "secret_key" => "S",
        "endpoint" => endpoint
      })

    {:ok, view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))
    assert html =~ ~s(value="acct")
    assert html =~ ~r/<option[^>]*value="eu"[^>]*selected/

    view |> form("#integration-setup-form") |> render_change()
    refute render(view) =~ ~s(value="S")
    view |> form("#integration-setup-form") |> render_submit()

    assert {:ok, %{"endpoint" => ^endpoint, "secret_key" => "S"}} =
             Integrations.get_credentials(uuid)
  end

  test "editing and clearing a value survives a re-render, and saved secrets are masked", %{
    conn: conn
  } do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "edited")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "service" => "other",
        "access_key" => "K",
        "secret_key" => "S",
        "endpoint" => "minio.local:9000",
        "region" => "us-east-1"
      })

    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

    html =
      view
      |> form("#integration-setup-form", %{"region" => "", "secret_key" => "replacement-secret"})
      |> render_change()

    assert html =~ ~s(id="field-region" value="")
    html = view |> form("#integration-setup-form") |> render_submit()
    refute html =~ "replacement-secret"

    assert {:ok, %{"region" => "", "secret_key" => "replacement-secret"}} =
             Integrations.get_credentials(uuid)
  end

  test "creating a connection stores the endpoint the service works out", %{conn: conn} do
    {:ok, view, _html} = live(conn, @new_path)
    choose(view, "other")

    name = "Scratch #{System.unique_integer([:positive])}"

    view
    |> form("form[phx-submit=save_form]", %{
      "name" => name,
      "service" => "other",
      "endpoint" => "127.0.0.1:9",
      "region" => "us-east-1",
      "access_key" => "AKIATEST",
      "secret_key" => "secret"
    })
    |> render_submit()

    assert %{uuid: uuid} =
             "object_storage" |> Integrations.list_connections() |> Enum.find(&(&1.name == name))

    assert {:ok, %{"service" => "other", "endpoint" => "127.0.0.1:9", "access_key" => "AKIATEST"}} =
             Integrations.get_credentials(uuid)
  end

  test "a connection with no setup yet can make its initial service choice", %{conn: conn} do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "Not set up yet")
    {:ok, view, _} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))
    assert has_element?(view, "select[name=service]")
    refute has_element?(view, "input[type=hidden][name=service]")
  end

  test "an old connection opens on the service its endpoint names", %{conn: conn} do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "legacy b2")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "access_key" => "K",
        "secret_key" => "S",
        "region" => "us-west-002",
        "endpoint" => "s3.us-west-002.backblazeb2.com"
      })

    {:ok, view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

    assert has_element?(view, "input[type=hidden][name=service][value=backblaze_b2]")
    refute has_element?(view, "select[name=service]")
    assert html =~ ~s(value="us-west-002")
  end

  test "the list says which service an Object Storage connection is", %{conn: conn} do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "list me")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "access_key" => "K",
        "secret_key" => "S",
        "service" => "tigris",
        "endpoint" => "t3.storage.dev"
      })

    {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations"))

    assert html =~ "Object Storage (S3-compatible)"
    assert html =~ ~r/badge[^>]*>\s*Tigris\s*</
  end
end
