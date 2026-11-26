defmodule PhoenixKitWeb.Components.Core.FormDraftTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2, form: 1]
  import PhoenixKitWeb.Components.Core.SimpleForm

  alias PhoenixKitWeb.Components.Core.FormDraft

  defp render(template), do: rendered_to_string(template)

  test "attrs/1: the hook and its defaults" do
    assert FormDraft.attrs() == %{
             "phx-hook": "FormDraft",
             "data-draft-storage": "local",
             "data-draft-ttl": "604800",
             "data-draft-exclude": ""
           }
  end

  test "attrs/1: options" do
    attrs =
      FormDraft.attrs(
        storage: :session,
        exclude: ["slug", "user[email]"],
        key: "post:1",
        ttl: 60,
        event: "draft_found"
      )

    assert attrs[:"data-draft-storage"] == "session"
    assert attrs[:"data-draft-exclude"] == "slug,user[email]"
    assert attrs[:"data-draft-key"] == "post:1"
    assert attrs[:"data-draft-ttl"] == "60"
    assert attrs[:"data-draft-event"] == "draft_found"
    refute Map.has_key?(FormDraft.attrs(key: ""), :"data-draft-key")
  end

  test "attrs/1 spreads onto <.form>" do
    assigns = %{form: Phoenix.Component.to_form(%{}), draft: FormDraft.attrs(exclude: ["slug"])}

    html = render(~H|<.form for={@form} id="f" {@draft}>x</.form>|)

    assert html =~ ~s(phx-hook="FormDraft")
    assert html =~ ~s(data-draft-exclude="slug")
  end

  test "the bar is hidden until the hook finds a draft, and ignored by patches" do
    assigns = %{}
    html = render(~H|<FormDraft.form_draft_bar for="post-form" />|)

    assert html =~ ~s(id="post-form-draft-bar")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(data-pk-draft-bar="post-form")
    assert html =~ ~r/data-pk-draft-prompt\s+hidden/
    assert html =~ "Restore your unsaved draft?"
    assert html =~ "data-pk-draft-restore"
    assert html =~ "data-pk-draft-discard"
  end

  test "clear/2 pushes the clear event for that form" do
    socket = %Phoenix.LiveView.Socket{}
    socket = FormDraft.clear(socket, "post-form")

    assert [["pk:form-draft", %{id: "post-form", action: "clear"}]] =
             socket.private.live_temp.push_events
  end

  test "simple_form: off by default" do
    assigns = %{form: Phoenix.Component.to_form(%{})}

    html =
      render(~H"""
      <.simple_form for={@form} id="f">x</.simple_form>
      """)

    refute html =~ "FormDraft"
    refute html =~ "data-pk-draft-bar"
  end

  test "simple_form draft: the hook, the bar and the options" do
    assigns = %{form: Phoenix.Component.to_form(%{})}

    html =
      render(~H"""
      <.simple_form for={@form} id="post-form" draft={[exclude: ["slug"], storage: :session]}>
        x
      </.simple_form>
      """)

    assert html =~ ~s(phx-hook="FormDraft")
    assert html =~ ~s(data-draft-exclude="slug")
    assert html =~ ~s(data-draft-storage="session")
    assert html =~ ~s(data-pk-draft-bar="post-form")

    html = render(~H|<.simple_form for={@form} id="p" draft>x</.simple_form>|)
    assert html =~ ~s(data-draft-storage="local")
  end

  test "simple_form draft without an id is a mistake, said at render" do
    assigns = %{form: Phoenix.Component.to_form(%{})}

    assert_raise ArgumentError, ~r/needs an id/, fn ->
      render(~H|<.simple_form for={@form} draft>x</.simple_form>|)
    end
  end
end
