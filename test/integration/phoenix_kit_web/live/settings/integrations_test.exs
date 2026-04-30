defmodule PhoenixKitWeb.Live.Settings.IntegrationsTest do
  @moduledoc """
  Smoke tests for the integrations admin LiveViews.

  Covers the post-uuid-everywhere behavior:
  - List page renders connection names verbatim (no special-case for
    `"default"`)
  - /new always asks the user for a connection name (no silent default)
  - Edit page rename input is always editable, on every connection
  - URL is uuid-based (`/admin/settings/integrations/:uuid`)
  - Test Connection action available on connected / configured / error
    rows

  Auth + sandbox plumbing comes from `PhoenixKitWeb.ConnCase`.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Utils.Routes

  @list_path Routes.path("/admin/settings/integrations")
  @new_path Routes.path("/admin/settings/integrations/new")

  defp setup_admin(%{conn: conn}) do
    {user, _token} = create_admin_user()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  defp seed_openrouter(name \\ "default") do
    {:ok, _} = Integrations.add_connection("openrouter", name)
    {:ok, _} = Integrations.save_setup("openrouter:#{name}", %{"api_key" => "sk-test-#{name}"})
    [conn] = Integrations.list_connections("openrouter") |> Enum.filter(&(&1.name == name))
    conn
  end

  # ---------------------------------------------------------------------------
  # List page
  # ---------------------------------------------------------------------------

  describe "list page" do
    setup :setup_admin

    test "renders the page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, @list_path)
      assert html =~ "Integrations"
    end

    test "shows name verbatim for default-named connections (no special casing)",
         %{conn: conn} do
      seed_openrouter("default")

      {:ok, _view, html} = live(conn, @list_path)

      # Old behavior rendered `—` for default rows; new behavior shows
      # the literal name the user picked.
      assert html =~ "default"
    end

    test "shows custom names verbatim for non-default connections", %{conn: conn} do
      seed_openrouter("personal")

      {:ok, _view, html} = live(conn, @list_path)
      assert html =~ "personal"
    end

    test "Configure link points at the row's uuid (not provider/name)",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("default")

      {:ok, _view, html} = live(conn, @list_path)

      # Edit URL is uuid-based — renames don't break bookmarks
      assert html =~ "/admin/settings/integrations/#{uuid}"
      refute html =~ "/admin/settings/integrations/openrouter/default"
    end

    test "Test Connection action is present on `error` status rows",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("default")
      :ok = Integrations.record_validation(uuid, {:error, :invalid_credentials})

      {:ok, _view, html} = live(conn, @list_path)
      assert html =~ "Test Connection"
    end

    test "Remove action is available for any connection name (no default privilege)",
         %{conn: conn} do
      seed_openrouter("default")

      {:ok, view, _html} = live(conn, @list_path)
      assert render(view) =~ "Remove"
    end

    test "renders empty state with provider names when no connections exist",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, @list_path)

      assert html =~ "No integrations configured"
      # Empty-state subtitle lists the provider names dynamically
      assert html =~ "OpenRouter"
    end
  end

  # ---------------------------------------------------------------------------
  # /new — provider picker + name input
  # ---------------------------------------------------------------------------

  describe "/new flow" do
    setup :setup_admin

    test "renders the provider picker", %{conn: conn} do
      {:ok, _view, html} = live(conn, @new_path)
      assert html =~ "OpenRouter"
      assert html =~ "Google"
    end

    test "selecting a provider always shows the Connection Name input",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      html =
        view
        |> element("button[phx-value-provider=\"openrouter\"]")
        |> render_click()

      # No more silent "default" auto-naming — every new connection
      # asks the user for a name regardless of whether one already
      # exists for the provider.
      assert html =~ "Connection Name"
      assert html =~ ~s(name="name")
    end

    test "submitting the form with a blank name surfaces an error",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element("button[phx-value-provider=\"openrouter\"]")
      |> render_click()

      html =
        view
        |> element("form[phx-submit=\"create_connection\"]")
        |> render_submit(%{"name" => "", "api_key" => "sk-test-key"})

      # The Integrations.add_connection/3 path returns :empty_name on
      # blank input; the LV surfaces it as a flash-style error.
      assert html =~ "Please enter a connection name."
    end
  end

  # ---------------------------------------------------------------------------
  # Edit page — uuid URL + always-editable name
  # ---------------------------------------------------------------------------

  describe "edit page" do
    setup :setup_admin

    test "404-style flash for an unknown uuid", %{conn: conn} do
      ghost = "00000000-0000-7000-8000-000000000000"

      # Phoenix 1.8 LV calls `put_flash/3` while building the redirect,
      # which requires `fetch_flash/2` to have run. Prime it manually
      # so the test exercises the not-found redirect.
      conn = conn |> Phoenix.ConnTest.init_test_session(%{}) |> Phoenix.Controller.fetch_flash()

      {:error, {:live_redirect, %{to: target}}} =
        live(conn, Routes.path("/admin/settings/integrations/#{ghost}"))

      assert target == @list_path
    end

    test "renders the editable rename input for default-named connections",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("default")

      {:ok, _view, html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      # No more disabled-Default-with-explainer branch; every row gets
      # a normal rename input.
      assert html =~ "Connection Name"
      assert html =~ ~s(value="default")
      refute html =~ "disabled"
      assert html =~ "Rename"
    end

    test "renders the editable rename input for custom-named connections",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("personal")

      {:ok, _view, html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      assert html =~ ~s(value="personal")
      assert html =~ "Rename"
    end

    test "renaming a connection updates the row in storage", %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("personal")

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      view
      |> element("form[phx-submit=\"rename_connection\"]")
      |> render_submit(%{"name" => "work"})

      # URL stays uuid-based; the name changes inside the JSONB row.
      {:ok, %{name: name}} = Integrations.get_integration_by_uuid(uuid)
      assert name == "work"
    end

    test "renaming the default connection works (no privileged name)",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("default")

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      view
      |> element("form[phx-submit=\"rename_connection\"]")
      |> render_submit(%{"name" => "primary"})

      {:ok, %{name: name}} = Integrations.get_integration_by_uuid(uuid)
      assert name == "primary"
    end

    test "rename to an existing name surfaces an error flash", %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("personal")
      seed_openrouter("work")

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      html =
        view
        |> element("form[phx-submit=\"rename_connection\"]")
        |> render_submit(%{"name" => "work"})

      assert html =~ "already exists"
    end
  end
end
