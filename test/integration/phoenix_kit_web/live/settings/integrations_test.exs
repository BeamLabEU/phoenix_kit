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

  defp seed_openrouter(name) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", name)
    {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "sk-test-#{name}"})
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
        |> element("form[phx-submit=\"save_form\"]")
        |> render_submit(%{"name" => "", "api_key" => "sk-test-key"})

      # The Integrations.add_connection/3 path returns :empty_name on
      # blank input; the LV surfaces it as a flash-style error.
      assert html =~ "Please enter a connection name."
    end

    test "Test Connection on /new probes credentials without persisting",
         %{conn: conn} do
      # Pre-condition: no openrouter integration rows exist.
      assert Integrations.list_connections("openrouter") == []

      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element("button[phx-value-provider=\"openrouter\"]")
      |> render_click()

      # Submit with `_intent="test"` — `save_form` routes to
      # `test_credentials_dry_run/2` which probes the provider's
      # validation endpoint and reports the result, but writes
      # NOTHING to storage. Half-baked connection rows on a
      # failed pre-save test are exactly what this path avoids.
      view
      |> element("form[phx-submit=\"save_form\"]")
      |> render_submit(%{
        "name" => "test-no-save",
        "api_key" => "sk-not-real",
        "_intent" => "test"
      })

      # No row created — even though the test probably failed
      # against OpenRouter (network unreachable in tests anyway),
      # the dry-run path doesn't persist either way.
      assert Integrations.list_connections("openrouter") == []
    end

    test "Test Connection dry-run preserves the typed api_key in the rendered form",
         %{conn: conn} do
      # Regression: after a dry-run test, the api_key input would
      # re-render with `value=""` because `@data` (the saved row)
      # was empty — making it look like the form ate the user's
      # input. The fix captures typed values onto a `:form_values`
      # assign so the input re-renders with what the user typed.
      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element("button[phx-value-provider=\"openrouter\"]")
      |> render_click()

      html =
        view
        |> element("form[phx-submit=\"save_form\"]")
        |> render_submit(%{
          "name" => "preserve-typed",
          "api_key" => "sk-typed-but-not-saved",
          "_intent" => "test"
        })

      # The api_key input must re-render carrying the typed value
      # (not blanked back to ""). Operator's input survives the
      # round-trip even though nothing was persisted.
      assert html =~ ~s(value="sk-typed-but-not-saved")
      assert html =~ ~s(value="preserve-typed")
    end

    test "Test Connection on /new works with a blank Connection Name",
         %{conn: conn} do
      # `formnovalidate` on the Test button bypasses HTML5
      # required-field validation. The operator should be able to
      # verify "does this api_key work?" without inventing a
      # connection name first — that's needless friction. The
      # backend dry-run path doesn't need a name either; only
      # actual creation (`add_connection/3`) requires one.
      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element("button[phx-value-provider=\"openrouter\"]")
      |> render_click()

      # No name in params — render_submit doesn't enforce HTML5
      # validation in tests, but the Test button having
      # `formnovalidate` is what makes this work in the browser.
      # Either way the dry-run path completes without error.
      view
      |> element("form[phx-submit=\"save_form\"]")
      |> render_submit(%{
        "name" => "",
        "api_key" => "sk-no-name",
        "_intent" => "test"
      })

      # No row created (no save), and no crash — the dry-run path
      # doesn't require a name.
      assert Integrations.list_connections("openrouter") == []
    end

    test "Test button has formnovalidate (lets it submit with empty required fields)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element("button[phx-value-provider=\"openrouter\"]")
      |> render_click()

      html = render(view)

      # Pin the markup contract: the Test button must declare
      # `formnovalidate` so the browser bypasses HTML5
      # required-field checks when it submits. Without this,
      # Connection Name's `required` attribute would block Test
      # in the browser (visible as a tooltip "Please fill out
      # this field").
      assert html =~ ~r/<button[^>]*name="_intent"[^>]*value="test"[^>]*formnovalidate/
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

    test "renders the editable name input for default-named connections",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("default")

      {:ok, _view, html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      # No more disabled-Default-with-explainer branch; every row gets
      # a normal editable name input. The save form uses one unified
      # submit (`save_form`) that detects renames automatically.
      assert html =~ "Connection Name"
      assert html =~ ~s(value="default")
      assert html =~ "Save Changes"
    end

    test "renders the editable name input for custom-named connections",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("personal")

      {:ok, _view, html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      assert html =~ ~s(value="personal")
      assert html =~ "Save Changes"
    end

    test "renaming a connection via the unified save form updates the row in storage",
         %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("personal")

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      view
      |> element("form[phx-submit=\"save_form\"]")
      |> render_submit(%{"name" => "work", "api_key" => "sk-test-personal"})

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
      |> element("form[phx-submit=\"save_form\"]")
      |> render_submit(%{"name" => "primary", "api_key" => "sk-test-default"})

      {:ok, %{name: name}} = Integrations.get_integration_by_uuid(uuid)
      assert name == "primary"
    end

    test "rename to an existing name surfaces an error", %{conn: conn} do
      %{uuid: uuid} = seed_openrouter("personal")
      seed_openrouter("work")

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      html =
        view
        |> element("form[phx-submit=\"save_form\"]")
        |> render_submit(%{"name" => "work", "api_key" => "sk-test-personal"})

      assert html =~ "already exists"
    end

    test "Test Connection uses the inputted api_key, not the stale saved value",
         %{conn: conn} do
      # Save an initial key, then submit the form with a NEW key
      # via the "Test" path (form submit, not a separate event).
      # The integration row's `api_key` must reflect the inputted
      # value — proving the test path picked up what was in the
      # field, not whatever was saved last time.
      %{uuid: uuid} = seed_openrouter("test-with-new-key")

      # Sanity: stored value is the original.
      {:ok, %{data: %{"api_key" => initial}}} = Integrations.get_integration_by_uuid(uuid)
      assert initial == "sk-test-test-with-new-key"

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      # Submit the form with a different api_key. Same submit path
      # the Test Connection button uses (Test is a `type="submit"`
      # button on the same form, so it goes through `save_form`).
      view
      |> element("form[phx-submit=\"save_form\"]")
      |> render_submit(%{
        "name" => "test-with-new-key",
        "api_key" => "sk-fresh-from-the-field",
        "_intent" => "test"
      })

      {:ok, %{data: %{"api_key" => after_test}}} =
        Integrations.get_integration_by_uuid(uuid)

      assert after_test == "sk-fresh-from-the-field",
             "expected the test path to save the inputted api_key, not the stale one"
    end

    test "Test Connection on an `error`-status connection takes the auto-test path",
         %{conn: conn} do
      # Regression: `apply_save_outcome/2` originally only triggered
      # the auto-test for status `configured`/`connected`. A
      # connection in `error` state (previous validation failed) was
      # the most common case where the operator wants to re-test
      # after fixing the api_key — but the form would just show
      # "Saved" without re-running validation. The visibility guard
      # for the Test button includes "error", so the post-save
      # outcome handler must too.
      #
      # Assertion strategy: don't wait for the async HTTP validation
      # to complete (it'd flake on network timing). Check the
      # synchronous outcome of `apply_save_outcome/2` via the
      # rendered HTML — auto-test path leaves `:success` nil and
      # sets `:testing` true, so the loading affordance is present
      # and the "Saved" banner is NOT.
      %{uuid: uuid} = seed_openrouter("error-state-rerun")
      :ok = Integrations.record_validation(uuid, {:error, "previous failure"})

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      html =
        view
        |> element("form[phx-submit=\"save_form\"]")
        |> render_submit(%{
          "name" => "error-state-rerun",
          "api_key" => "sk-fixed-after-error",
          "_intent" => "test"
        })

      # Auto-test path → `:testing` true → button label flips to
      # "Testing..." and the literal "Saved" success banner does
      # NOT appear.
      assert html =~ "Testing..."
      refute html =~ ~s(class="alert alert-success)
    end

    test "Test Connection with empty api_key field preserves the saved key",
         %{conn: conn} do
      # Password fields render empty (the masked value isn't echoed
      # back into the DOM). When the user clicks Test without
      # touching the field, the form submits with `api_key=""` —
      # which `extract_setup_attrs/2` strips for password fields,
      # so the existing saved credential is preserved across the
      # round-trip.
      %{uuid: uuid} = seed_openrouter("preserve-on-empty-test")

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      view
      |> element("form[phx-submit=\"save_form\"]")
      |> render_submit(%{
        "name" => "preserve-on-empty-test",
        "api_key" => "",
        "_intent" => "test"
      })

      {:ok, %{data: %{"api_key" => preserved}}} =
        Integrations.get_integration_by_uuid(uuid)

      assert preserved == "sk-test-preserve-on-empty-test"
    end
  end
end
