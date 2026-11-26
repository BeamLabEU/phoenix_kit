defmodule PhoenixKitWeb.Components.Core.PersonChipTest do
  @moduledoc """
  `<.person_chip>`: one look for a person in text and in lists (a mention, a
  task's assignees). Spans only, so it can sit in a paragraph; neutral and
  never underlined; the person's picture by the rule of every face
  (`user_avatar`: uploaded with its crop, OAuth, Gravatar) over their
  initials; a uuid makes it open the person's card.
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

  # Max, 2026-11-26: one person, one face, wherever they are shown; the
  # chip used to show initials where the picker showed their picture.
  test "the face follows user_avatar: an OAuth picture over the initials" do
    html =
      render_component(&UserInfo.person_chip/1,
        person: person(%{custom_fields: %{"oauth_avatar_url" => "https://lh3.example/a.png"}})
      )

    assert html =~ ~s(src="https://lh3.example/a.png")
    assert html =~ ">AK<"
    refute html =~ "<div"
  end

  test "with only an email, Gravatar (a transparent picture when there is none)" do
    html = render_component(&UserInfo.person_chip/1, person: person())

    assert html =~ "gravatar.com/avatar/"
    assert html =~ "d=blank"
    assert html =~ ">AK<"
  end

  test "an uploaded picture is placed by its stored crop" do
    file = "0198e004-2265-7000-8000-000000000000"

    html =
      render_component(&UserInfo.person_chip/1,
        person:
          person(%{
            custom_fields: %{
              "avatar_file_uuid" => file,
              "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 2, "ar" => 1}
            }
          })
      )

    assert html =~ "/#{file}/"
    assert html =~ "width:200.00%"
    assert html =~ "left:-50.00%"
    refute html =~ "object-cover"
    refute html =~ "<div"
  end

  test "an uploaded picture without a crop covers the face" do
    file = "0198e004-2265-7000-8000-000000000000"

    html =
      render_component(&UserInfo.person_chip/1,
        person: person(%{custom_fields: %{"avatar_file_uuid" => file}})
      )

    assert html =~ "/#{file}/"
    assert html =~ "object-cover"
  end

  test "avatar_brief gives the same picture and the crop's style" do
    file = "0198e004-2265-7000-8000-000000000000"

    brief =
      UserInfo.avatar_brief(
        person(%{
          custom_fields: %{
            "avatar_file_uuid" => file,
            "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 2, "ar" => 1}
          }
        }),
        "Anna Kask"
      )

    assert brief.url =~ "/#{file}/"
    assert brief.style =~ "width:200.00%"
    assert brief.initials == "AK"
    assert %{url: nil, style: nil} = UserInfo.avatar_brief(nil, "Someone")
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
