defmodule PhoenixKitWeb.Live.Settings.ApiGuidePanel do
  @moduledoc """
  The "API guide" tab of Settings -> API (`?tab=guide`): how a program or an AI agent
  connects to the admin API with a key. Read-only, no events; generated from the live
  tool registry, so a tool or a module added later shows up without an edit here.

  `assign_guide/1` puts everything the tab shows into one `:guide` assign and
  `api_guide_panel/1` renders it. `PhoenixKitWeb.Live.Settings.Api` builds it each time
  the tab is opened, not at mount, so the other tabs do not pay for the tool registry,
  and the status of the switches is the current one. The tab is gated like the page,
  by the `api` permission.

  ## What the guide must never hold

  A key. Every snippet carries the placeholder `<your key>` (or, for VS Code, an
  `inputs` prompt that keeps the key out of the file), and the guide warns that a key
  must not be committed. The guide reads no key and no token from anywhere.

  ## Where the numbers come from

  The base URL is `PhoenixKit.Utils.Routes.base_url/0` (a LiveView has no conn, and on a
  site with several domains every domain serves the same API). The tools are
  `PhoenixKit.API.Registry.visible_tools(:admin, :all)`, grouped by the display name of
  the module that declared them (`c:PhoenixKit.Module.module_name/0`); core's own
  `system.*` tools have no module and go under "Core". The error table is
  `PhoenixKit.API.Problem.statuses/0` with `PhoenixKit.API.MCP.Shape.advice/1`.
  """
  use PhoenixKitWeb, :html

  alias PhoenixKit.API.ClientName
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.FlowConfig
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.API.MCP.Shape
  alias PhoenixKit.API.Paths
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.Registry
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.ProfileSettingsTabs

  @key_placeholder "<your key>"

  @doc "Renders the guide from the `:guide` assign that `assign_guide/1` builds."
  attr :guide, :map, required: true
  def api_guide_panel(assigns)

  embed_templates "api_guide_panel.html"

  @doc "Builds the guide into the `:guide` assign."
  @spec assign_guide(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_guide(socket) do
    base = Routes.base_url()
    rest = base <> Routes.path(Paths.rest_path(:admin))
    mcp = base <> Routes.path(Paths.mcp_path(:admin))
    name = server_name(Settings.get_project_title())

    assign(socket, :guide, %{
      settings_path: Routes.path("/admin/settings/api"),
      approvals_path: Routes.path("/admin/approvals"),
      personal_keys_path: ProfileSettingsTabs.path("api-keys"),
      admin_enabled: Config.admin_enabled?(),
      public_enabled: Config.public_enabled?(),
      base_url: base,
      rest_url: rest,
      mcp_url: mcp,
      openapi_url: rest <> "/openapi.json",
      claude_code_command: claude_code_command(name, mcp),
      cursor_config: cursor_config(name, mcp),
      vscode_config: vscode_config(name, mcp),
      tool_groups: tool_groups(),
      confirm_ttl_seconds: FlowConfig.confirm_ttl_seconds(),
      confirm_batch_over: FlowConfig.confirm_batch_over(),
      approval_ttl_hours: FlowConfig.approval_ttl_hours(),
      idempotency_ttl_hours: FlowConfig.idempotency_ttl_hours(),
      errors: errors()
    })
  end

  # ── Snippets ─────────────────────────────────────────────────────

  # The public server of the same site is named after the project too, so this one
  # carries a suffix and the two can sit in one client.
  defp server_name(project_title), do: ClientName.slug(project_title) <> "-admin"

  # `--header` takes any number of values, so it must follow the URL or the URL
  # would be read as a header. The default scope is `local`: the key stays out of
  # the shared project file.
  defp claude_code_command(name, url) do
    "claude mcp add --transport http #{name} #{shell_quote(url)} " <>
      "--header #{shell_quote("Authorization: Bearer " <> @key_placeholder)}"
  end

  defp cursor_config(name, url) do
    json(%{
      "mcpServers" => %{
        name => %{"url" => url, "headers" => %{"Authorization" => "Bearer " <> @key_placeholder}}
      }
    })
  end

  defp vscode_config(name, url) do
    input_id = name <> "-key"

    json(%{
      "inputs" => [
        %{
          "type" => "promptString",
          "id" => input_id,
          "description" => "API key",
          "password" => true
        }
      ],
      "servers" => %{
        name => %{
          "type" => "http",
          "url" => url,
          "headers" => %{"Authorization" => "Bearer ${input:#{input_id}}"}
        }
      }
    })
  end

  defp json(term), do: Jason.encode!(term, pretty: true)

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  # ── Tools ────────────────────────────────────────────────────────

  # Core's own tools first, then the modules by display name.
  defp tool_groups do
    :admin
    |> Registry.visible_tools(:all)
    |> Enum.group_by(&group_of/1, &tool_row/1)
    |> Enum.map(fn {{key, label}, rows} ->
      %{
        key: key,
        dom_id: "guide-tools-group-" <> Regex.replace(~r/[^A-Za-z0-9_-]/, key, "-"),
        label: label,
        tools: Enum.sort_by(rows, & &1.name)
      }
    end)
    |> Enum.sort_by(&{&1.key != "core", String.downcase(&1.label)})
  end

  defp group_of(%{module: nil}), do: {"core", gettext("Core")}

  defp group_of(%{module: module}),
    do: {module_text(module, :module_key), module_text(module, :module_name)}

  defp module_text(module, function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 0) do
      module |> apply(function, []) |> to_string()
    else
      inspect(module)
    end
  rescue
    _error -> inspect(module)
  end

  defp tool_row(tool) do
    %{
      name: tool.name,
      mcp_name: Names.to_mcp(tool.name),
      dom_id: "guide-tool-" <> String.replace(tool.name, ".", "-"),
      title: if(tool.title != tool.name, do: tool.title),
      scope: tool.scope,
      writes?: ControlFields.write_tool?(tool),
      confirms?: tool.danger != nil
    }
  end

  # ── Errors ───────────────────────────────────────────────────────

  defp errors do
    Problem.statuses()
    |> Enum.sort_by(fn {code, status} -> {status, Atom.to_string(code)} end)
    |> Enum.map(fn {code, status} ->
      %{code: Atom.to_string(code), status: status, advice: Shape.advice(code)}
    end)
  end
end
