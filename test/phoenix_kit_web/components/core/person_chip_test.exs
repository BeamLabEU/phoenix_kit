defmodule PhoenixKitWeb.Components.Core.PersonChipTest do
  @moduledoc """
  `<.person_chip>`: one look for a person in text and in lists (a mention, a
  task's assignees). Spans only, so it can sit in a paragraph; neutral and
  never underlined; a face from this site's storage or initials, never a
  third party's; a uuid makes it open the person's card.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.Modal
  alias PhoenixKitWeb.Components.Core.UserInfo

  @uuid "01a1a83a-1e58-7386-9267-19b9fcb46ae6"

  defp person(fields \\ %{}) do
    Map.merge(
      %{
        uuid: @uuid,
        first_name: "Anna",
        last_name: "Kask",
        email: "anna@example.com",
        custom_fields: %{}
      },
      fields
    )
  end

  test "a person with a link: one <a>, spans only, the name and initials" do
    html =
      render_component(&UserInfo.person_chip/1, person: person(), href: "/admin/users/view/x")

    assert html =~ ~s(href="/admin/users/view/x")
    assert html =~ ~s(data-mention-user="#{@uuid}")
    assert html =~ "Anna Kask"
    assert html =~ ">AK<"
    refute html =~ "<div"
    assert html =~ "no-underline!"
    assert html =~ "text-base-content!"
    # Its failure words ride on the chip, translated by the server.
    assert html =~ "data-card-error"
  end

  test "without a link it is a span, and the name given wins" do
    html = render_component(&UserInfo.person_chip/1, uuid: @uuid, name: "Gone Person")

    refute html =~ "<a "
    assert html =~ "Gone Person"
    assert html =~ ">GP<"
    # Reachable from the keyboard: a button, in the tab order.
    assert html =~ ~s(role="button")
    assert html =~ ~s(tabindex="0")
  end

  test "a person with only an OAuth or Gravatar picture shows initials, never a third party" do
    html =
      render_component(&UserInfo.person_chip/1,
        person: person(%{custom_fields: %{"oauth_avatar_url" => "https://lh3.example/a.png"}})
      )

    refute html =~ "lh3.example"
    refute html =~ "gravatar"
    refute html =~ "<img"
  end

  test "no uuid: no card to open" do
    html = render_component(&UserInfo.person_chip/1, name: "Someone")
    refute html =~ "data-mention-user"
    refute html =~ "tabindex"
  end

  test "confirm_modal takes an id, so two in one document stay apart" do
    html =
      render_component(&Modal.confirm_modal/1,
        id: "page-confirm",
        show: true,
        on_cancel: "confirm_action_cancel"
      )

    assert html =~ ~s(id="page-confirm")

    default =
      render_component(&Modal.confirm_modal/1, show: true, on_cancel: "confirm_action_cancel")

    assert default =~ ~s(id="pk-modal-confirm_action_cancel")
  end
end
