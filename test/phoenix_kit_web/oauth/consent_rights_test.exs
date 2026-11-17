defmodule PhoenixKitWeb.OAuth.ConsentRightsTest do
  @moduledoc """
  The consent screen says what an application may do in words a person can read: per module, the
  module's own name and the titles and descriptions of its tools, reading apart from changing, and
  changing never ticked. A right the person does not hold is not listed. The screen also says that
  other rights mean connecting again.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [setup_api: 0]

  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleRegistry

  defmodule Rights do
    @moduledoc false
    # A module whose tools are written for a person; `humanrights.vault:write` needs a right
    # (`media`) the test person does not hold.
    def module_key, do: "humanrights"
    def module_name, do: "Invoices and billing"
    def enabled?, do: true

    def api_tools do
      [
        tool("humanrights.list_invoices", "humanrights.invoices:read", "dashboard",
          title: "List invoices",
          description: "Shows the invoices with their totals."
        ),
        tool("humanrights.open_invoice", "humanrights.invoices:read", "dashboard",
          title: "Open an invoice",
          description: "Shows one invoice."
        ),
        tool("humanrights.send_invoice", "humanrights.invoices:write", "dashboard",
          title: "Send an invoice",
          description: "Emails an invoice to the customer."
        ),
        tool("humanrights.empty_vault", "humanrights.vault:write", "media",
          title: "Empty the vault",
          description: "Deletes everything in the vault."
        )
      ]
    end

    def handle(_input, _ctx), do: {:ok, %{}}

    defp tool(name, scope, permission, opts) do
      Tool.new!(%{
        name: name,
        audience: :admin,
        scope: scope,
        permission: permission,
        title: Keyword.fetch!(opts, :title),
        description: Keyword.fetch!(opts, :description),
        input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        output_schema: %{"type" => "object"},
        handler: {__MODULE__, :handle}
      })
    end
  end

  @read "humanrights.invoices:read"
  @write "humanrights.invoices:write"
  @hidden "humanrights.vault:write"

  setup do
    setup_api()
    enable_oauth!()
    ModuleRegistry.register(Rights)
    on_exit(fn -> ModuleRegistry.unregister(Rights) end)
    {user, _role} = holder(["dashboard", "settings"])
    {_verifier, challenge} = pkce()
    client = client!()

    id =
      browser()
      |> authorize(
        authorize_params(client, challenge, %{"scope" => "#{@read} #{@write} #{@hidden}"})
      )
      |> consent_id()

    html = user |> browser() |> consent(id) |> Map.fetch!(:resp_body) |> Floki.parse_document!()
    %{html: html, text: Floki.text(html)}
  end

  test "the module is named, once, as the module names itself", %{html: html} do
    assert [heading] = Floki.find(html, "#consent-module-humanrights")
    assert Floki.text(heading) =~ "Invoices and billing"
  end

  test "reading and changing are listed apart under the module", %{html: html} do
    assert [_] = Floki.find(html, ~s(#consent-reads-humanrights input[value="#{@read}"]))
    assert [] = Floki.find(html, ~s(#consent-reads-humanrights input[value="#{@write}"]))
    assert [_] = Floki.find(html, ~s(#consent-writes-humanrights input[value="#{@write}"]))
  end

  test "reading is ticked and changing is not", %{html: html} do
    assert [_] = Floki.find(html, ~s(input[value="#{@read}"][checked]))
    assert [_] = Floki.find(html, ~s(input[value="#{@write}"]))
    assert [] = Floki.find(html, ~s(input[value="#{@write}"][checked]))
  end

  test "the tools of a right are named by their titles and described", %{text: text} do
    assert text =~ "List invoices"
    assert text =~ "Open an invoice"
    assert text =~ "Send an invoice"
    assert text =~ "Emails an invoice to the customer."
    assert text =~ "Shows the invoices with their totals."
  end

  test "no raw scope name or tool name is shown as text", %{text: text} do
    refute text =~ "humanrights.invoices"
    refute text =~ "humanrights.send_invoice"
    refute text =~ ":read"
  end

  test "a right the person does not hold is not listed", %{html: html, text: text} do
    assert [] = Floki.find(html, ~s(input[value="#{@hidden}"]))
    refute text =~ "Empty the vault"
    refute text =~ "Deletes everything in the vault."
    assert [] = Floki.find(html, "#consent-writes-humanrights input[value$=vault:write]")
  end

  test "it says that other rights mean connecting again", %{html: html} do
    assert [note] = Floki.find(html, "#consent-reconnect")
    assert Floki.text(note) =~ "connect it again"
  end
end
