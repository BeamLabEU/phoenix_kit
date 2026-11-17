defmodule PhoenixKitWeb.Live.Settings.ApiGuideTest do
  @moduledoc """
  Settings -> API, the guide tab (`?tab=guide`): who may open it, what it says
  about the endpoints, the client snippets (decoded, not matched as text, so a
  broken file shows), the section on connecting with a sign-in (OAuth), the tools grouped by
  module, and the table of errors.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.MCP.Shape
  alias PhoenixKit.API.Problem
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Test.ApiFlowHarness
  alias PhoenixKit.Test.ApiFlowTools
  alias PhoenixKit.Test.ApiHarness
  alias PhoenixKit.Test.ApiLowercaseTools
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api?tab=guide")

  setup %{conn: conn} do
    ApiFlowHarness.setup_flow()
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.put_setting("project_title", "Acme Print")

    {admin, _token} = create_admin_user()
    {:ok, _} = Permissions.grant_permission(Roles.get_role_by_name("Admin").uuid, "api")

    %{conn: log_in_user(conn, admin)}
  end

  # The text of one element, entities decoded: what a person would copy.
  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("id")
  end

  defp base, do: Routes.base_url()

  describe "who may open the page" do
    test "an Admin without api is refused" do
      {admin, _token} = create_admin_user()
      :ok = Permissions.revoke_permission(Roles.get_role_by_name("Admin").uuid, "api")

      result = live(log_in_user(build_conn(), admin), @path)

      assert match?({:error, {kind, _}} when kind in [:redirect, :live_redirect], result)
    end

    test "a role that holds only api opens it" do
      {user, role} = KeyTestSupport.user_with([])
      assert Permissions.get_permissions_for_role(role.uuid) == ["api"]

      assert {:ok, view, _html} = live(log_in_user(build_conn(), user), @path)
      assert has_element?(view, "#api-guide-page")
    end
  end

  describe "Settings -> API" do
    test "has the guide as a tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/api"))

      assert has_element?(view, ~s([role="tablist"] [role="tab"][href="#{@path}"]), "API guide")
    end
  end

  describe "status" do
    test "says which sides are on and links to the switches", %{conn: conn} do
      ApiHarness.switch(:admin, true)
      ApiHarness.switch(:public, false)

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, ~s(#guide-status-admin[data-enabled="true"]))
      assert has_element?(view, ~s(#guide-status-public[data-enabled="false"]))

      assert has_element?(
               view,
               ~s(#guide-switches-link[href="#{Routes.path("/admin/settings/api")}"])
             )
    end
  end

  describe "endpoints" do
    test "are built from the base URL and the configured prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-base-url") == base()
      assert text(view, "#guide-rest-url") == base() <> Routes.path("/api/admin/v1")
      assert text(view, "#guide-mcp-url") == base() <> Routes.path("/mcp/admin")

      assert text(view, "#guide-openapi-url") ==
               base() <> Routes.path("/api/admin/v1") <> "/openapi.json"

      assert text(view, "#guide-rest-url") =~ "/phoenix_kit/api/admin/v1"
      assert has_element?(view, "#guide-domains-note")
    end

    test "name the headers and keep credentials out of URLs", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      for header <- ["Authorization", "Idempotency-Key", "RateLimit-Remaining", "Retry-After"] do
        assert has_element?(view, "#guide-headers code", header)
      end
    end
  end

  describe "client snippets" do
    test "Claude Code: the header comes after the URL, the key is a placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      command = text(view, "#guide-claude-code-command")

      assert command ==
               "claude mcp add --transport http acme-print-admin " <>
                 "'#{base()}#{Routes.path("/mcp/admin")}' --header 'Authorization: Bearer <your key>'"

      {url_at, _} = :binary.match(command, "/mcp/admin")
      {header_at, _} = :binary.match(command, "--header")
      assert url_at < header_at
      refute has_element?(view, "#guide-claude-code-command", "--scope")
    end

    test "Cursor: user-level file, url and headers", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-cursor-file") == "~/.cursor/mcp.json"

      assert %{
               "mcpServers" => %{
                 "acme-print-admin" => %{
                   "url" => url,
                   "headers" => %{"Authorization" => "Bearer <your key>"}
                 }
               }
             } = view |> text("#guide-cursor-config") |> Jason.decode!()

      assert url == base() <> Routes.path("/mcp/admin")
    end

    test "VS Code: asks for the key through inputs instead of storing it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert %{
               "inputs" => [
                 %{
                   "type" => "promptString",
                   "id" => "acme-print-admin-key",
                   "description" => "API key",
                   "password" => true
                 }
               ],
               "servers" => %{
                 "acme-print-admin" => %{
                   "type" => "http",
                   "url" => url,
                   "headers" => %{"Authorization" => "Bearer ${input:acme-print-admin-key}"}
                 }
               }
             } = view |> text("#guide-vscode-config") |> Jason.decode!()

      assert url == base() <> Routes.path("/mcp/admin")
    end

    test "no snippet or sentence on the page holds a real key", %{conn: conn} do
      %{key: key, token: token} = ApiFlowHarness.agent()
      assert token =~ ~r/\Apk_#{key.prefix}_/

      {:ok, view, _html} = live(conn, @path)
      html = view |> element("#api-tab-guide") |> render()

      assert has_element?(view, "#api-tab-guide #guide-key-warning")
      refute html =~ token
      refute html =~ key.prefix
      refute html =~ ~r/\bpk_[0-9a-f]{8}_/
    end

    test "the server name is the slug of the project title plus -admin", %{conn: conn} do
      KeyTestSupport.put_setting(
        "project_title",
        "Café Déco — Prints & Frames, the very long name"
      )

      {:ok, view, _html} = live(conn, @path)

      name = Regex.run(~r/--transport http (\S+) /, text(view, "#guide-claude-code-command"))
      assert [_, name] = name
      assert name =~ ~r/\A[a-z0-9-]+-admin\z/
      assert String.starts_with?(name, "cafe-deco")
      assert byte_size(name) <= 32 + byte_size("-admin")
    end

    test "a title in another script is romanized", %{conn: conn} do
      KeyTestSupport.put_setting("project_title", "Декор для дома")
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-claude-code-command") =~
               "--transport http dekor-dlya-doma-admin '"
    end

    test "a title cut at a word break leaves no dangling dash", %{conn: conn} do
      KeyTestSupport.put_setting("project_title", "abcdefghij abcdefghij abcdefghi xyz")
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-claude-code-command") =~
               "--transport http abcdefghij-abcdefghij-abcdefghi-admin '"
    end

    test "a title with nothing to slug falls back to site", %{conn: conn} do
      KeyTestSupport.put_setting("project_title", "日本語")
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-claude-code-command") =~ "--transport http site-admin '"
    end
  end

  describe "connecting with a sign-in (OAuth)" do
    test "has its own section with the server address, the documents and a link to the settings",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-tab-guide #guide-oauth")
      assert text(view, "#guide-oauth-url") == base() <> Routes.path("/mcp/admin")

      assert text(view, "#guide-oauth-metadata-url") ==
               base() <> "/.well-known/oauth-protected-resource" <> Routes.path("/mcp/admin")

      assert text(view, "#guide-oauth-server-metadata-url") ==
               base() <> "/.well-known/oauth-authorization-server"

      assert view |> element("#guide-oauth-settings-link") |> render() =~
               Routes.path("/admin/settings/api?tab=oauth")
    end

    test "says OAuth is off while it is, and not once it is on", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#guide-oauth-off")

      KeyTestSupport.put_setting("api_admin_enabled", "true")
      KeyTestSupport.put_setting("api_oauth_enabled", "true")

      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#guide-oauth-off")
    end

    test "Claude Code is added without a header and the key placeholder stays out of the section",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-oauth-claude-code-command") ==
               "claude mcp add --transport http acme-print-admin '#{base()}#{Routes.path("/mcp/admin")}'"

      section = view |> element("#guide-oauth") |> render()
      refute section =~ "your key"
      refute section =~ "Bearer"
      refute section =~ ~r/\bpk_[0-9a-f]{8}_/
    end

    test "the matrix marks every client as not tried live, and Cursor, VS Code and Codex as no promise",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      for client <- ~w(claude chatgpt claude-code inspector) do
        assert text(view, "#guide-oauth-matrix-#{client}") =~ "Not yet tried live"
      end

      assert text(view, "#guide-oauth-matrix-claude") =~ "Document and return address read"
      assert text(view, "#guide-oauth-matrix-chatgpt") =~ "Depends on the plan"

      assert text(view, "#guide-oauth-matrix-cursor") =~ "not promised"
      assert text(view, "#guide-oauth-matrix-cursor") =~ "Codex"
      refute has_element?(view, "#guide-oauth-codex")
      refute has_element?(view, "#guide-oauth-matrix-codex")
    end

    test "the status of the live checks is worded in one place" do
      root = Path.expand("../../../..", __DIR__)

      sources =
        for file <- ~w(api_guide_panel.ex api_guide_panel.html.heex),
            do: File.read!(Path.join([root, "lib/phoenix_kit_web/live/settings", file]))

      assert sources |> Enum.join("\n") |> String.split("tried live") |> length() == 2
    end

    test "tells that a lost right ends the connection at the next request", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#guide-oauth-rights", "stop at the next request")
    end

    test "tells that other rights mean disconnecting and connecting again", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#guide-oauth-reconnect", "disconnects the application")
      assert has_element?(view, "#guide-oauth-reconnect", "connects it again")
    end
  end

  describe "tools" do
    test "are grouped by module, with scope, title and flags", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#guide-tools-group-api_flow_tools", "API flow test tools")
      assert has_element?(view, "#guide-tools-group-apikeytest", "API key test module")
      assert has_element?(view, "#guide-tools-group-core", "Core")

      assert has_element?(view, "#guide-tool-system-get_identity")
      assert has_element?(view, "#guide-tools-group-core #guide-tool-system-get_identity")

      assert has_element?(
               view,
               "#guide-tools-group-api_flow_tools #guide-tool-flowkit-delete_items",
               "flowkit.items:delete"
             )

      assert has_element?(view, "#guide-tool-apikeytest-list_things", "List_things")
    end

    test "core's own tools come first, the modules follow by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert ids(view, "#guide-tools > .card-body > div[id^=guide-tools-group-]") == [
               "guide-tools-group-core",
               "guide-tools-group-api_flow_tools",
               "guide-tools-group-apikeytest",
               "guide-tools-group-api_test_tools"
             ]
    end

    test "show the MCP name beside the dotted one", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#guide-tool-flowkit-read_items", "flowkit.read_items")
      assert has_element?(view, "#guide-tool-flowkit-read_items", "flowkit_read_items")
    end

    test "mark writes and the tools that may ask for confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#guide-tool-flowkit-read_items .guide-tool-writes")
      assert has_element?(view, "#guide-tool-flowkit-touch_item .guide-tool-writes")
      refute has_element?(view, "#guide-tool-flowkit-touch_item .guide-tool-confirm")
      assert has_element?(view, "#guide-tool-flowkit-delete_items .guide-tool-writes")
      assert has_element?(view, "#guide-tool-flowkit-delete_items .guide-tool-confirm")
      assert has_element?(view, "#guide-tool-flowkit-set_values .guide-tool-confirm")
    end

    test "list no public tool", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#guide-tool-flowkit-mint_cart")
      refute has_element?(view, "#guide-tool-apikeytest-public_thing")
    end

    test "a module that is switched off is not listed", %{conn: conn} do
      ApiFlowTools.set_enabled(false)
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#guide-tools-group-api_flow_tools")
      refute has_element?(view, "#guide-tool-flowkit-read_items")
      assert has_element?(view, "#guide-tools-note")
    end

    test "the note says what is hidden and that any write tool may ask for confirmation",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      note = text(view, "#guide-tools-note")

      assert note =~ "switched off"
      assert note =~ "one by one"
      assert note =~ "Any write tool may also ask for confirmation"
    end

    test "a tool that is switched off by itself is not listed", %{conn: conn} do
      KeyTestSupport.put_setting("api_disabled_tools", "flowkit.read_items")
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#guide-tool-flowkit-read_items")
      assert has_element?(view, "#guide-tool-flowkit-touch_item")
    end

    test "modules are sorted by name regardless of case", %{conn: conn} do
      :ok = ModuleRegistry.register(ApiLowercaseTools)
      on_exit(fn -> ModuleRegistry.unregister(ApiLowercaseTools) end)

      {:ok, view, _html} = live(conn, @path)

      labels =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#guide-tools > .card-body > div[id^=guide-tools-group-] > h3")
        |> Enum.map(&LazyHTML.text/1)

      assert hd(labels) == "Core"
      assert "acme lowercase tools" in labels
      assert tl(labels) == Enum.sort_by(tl(labels), &String.downcase/1)
    end

    test "a title that equals the name is not repeated", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      # The flow test tools take their name as their title.
      row = text(view, "#guide-tool-flowkit-read_items")
      assert length(String.split(row, "flowkit.read_items")) == 2

      # A real title stays beside the name.
      assert text(view, "#guide-tool-system-get_identity") =~ "Get identity"
    end
  end

  describe "dangerous operations" do
    test "name the control fields and link to the approvals page", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      for field <- ["dry_run", "confirm_token", "idempotency_key"] do
        assert has_element?(view, "#guide-danger code", field)
      end

      assert has_element?(
               view,
               ~s(#guide-approvals-link[href="#{Routes.path("/admin/approvals")}"])
             )
    end

    test "state the live limits, not the defaults", %{conn: conn} do
      KeyTestSupport.put_setting("api_confirm_ttl_seconds", 33)
      KeyTestSupport.put_setting("api_confirm_batch_over", 77)
      KeyTestSupport.put_setting("api_approval_ttl_hours", 55)
      KeyTestSupport.put_setting("api_idempotency_ttl_hours", 41)

      {:ok, view, _html} = live(conn, @path)
      danger = text(view, "#guide-danger")

      assert danger =~ "within 33 seconds"
      assert danger =~ "more than 77 rows"
      assert danger =~ "waits up to 55 hours"
      assert danger =~ "kept for 41 hours"
    end

    test "say one hour and one row when the limit is one", %{conn: conn} do
      KeyTestSupport.put_setting("api_confirm_batch_over", 1)
      KeyTestSupport.put_setting("api_approval_ttl_hours", 1)
      KeyTestSupport.put_setting("api_idempotency_ttl_hours", 1)

      {:ok, view, _html} = live(conn, @path)
      danger = text(view, "#guide-danger")

      assert danger =~ "more than 1 row is"
      assert danger =~ "waits up to 1 hour for"
      assert danger =~ "kept for 1 hour."
    end
  end

  describe "errors" do
    test "one row per code, by status then code, with the advice", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      rows = ids(view, "#guide-errors tbody tr")

      assert length(rows) == map_size(Problem.statuses())
      assert length(Enum.uniq(rows)) == length(rows)

      first_ten =
        ~w(invalid_json token_in_url unauthorized forbidden ip_not_allowed module_write_disabled origin_not_allowed module_disabled not_found method_not_allowed)

      assert Enum.take(rows, 10) == Enum.map(first_ten, &"guide-error-#{&1}")

      assert List.last(rows) == "guide-error-internal_error"

      for {code, status} <- Problem.statuses() do
        row = "#guide-error-#{code}"
        assert has_element?(view, row, Integer.to_string(status))
        assert has_element?(view, row, Atom.to_string(code))
        assert text(view, row) =~ Shape.advice(code)
      end
    end
  end
end
