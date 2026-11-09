defmodule PhoenixKitWeb.Components.Core.UserAvatarCropTest do
  @moduledoc """
  The avatar component applying a stored non-destructive crop.

  The crop is data in `custom_fields["avatar_crop"]`; rendering turns it
  into an inline style on the `<img>` and, when zoomed, a sharper storage
  variant. No crop means the exact markup that always rendered.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.UserInfo

  @uuid "0198e004-2265-7000-8000-000000000000"

  defp user(custom_fields) do
    %{email: "crop@example.com", custom_fields: custom_fields}
  end

  defp avatar(custom_fields, opts \\ []) do
    render_component(
      &UserInfo.user_avatar/1,
      Keyword.merge([user: user(custom_fields), size: "sm"], opts)
    )
  end

  test "no crop renders the classic object-cover image" do
    html = avatar(%{"avatar_file_uuid" => @uuid})

    assert html =~ "object-cover"
    refute html =~ "max-width:none"
    assert html =~ "/#{@uuid}/small/"
  end

  test "a crop becomes an inline style instead of object-cover" do
    html =
      avatar(%{
        "avatar_file_uuid" => @uuid,
        "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 2, "ar" => 1}
      })

    assert html =~ "max-width:none"
    assert html =~ "width:200.00%"
    assert html =~ "left:-50.00%"
    refute html =~ "object-cover"
  end

  test "a zoomed-out crop paints the circle white behind the picture" do
    # A wide logo shown whole leaves part of the circle uncovered; without
    # the fill the initials placeholder showed there.
    out =
      avatar(%{
        "avatar_file_uuid" => @uuid,
        "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 0.4, "ar" => 3}
      })

    assert out =~ "box-shadow:0 0 0 9999px #fff"
    assert out =~ "background:#fff"
    assert out =~ "top:30.00%"

    zoomed_in =
      avatar(%{
        "avatar_file_uuid" => @uuid,
        "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 2, "ar" => 1}
      })

    refute zoomed_in =~ "box-shadow"
  end

  describe "peek (the hover preview)" do
    test "carries a picture sized for the preview, and marks the frame it clones" do
      html = avatar(%{"avatar_file_uuid" => @uuid}, peek: true)

      assert html =~ ~s(data-avatar-peek="/phoenix_kit/file/#{@uuid}/medium/)
      assert html =~ "data-avatar-frame"
    end

    test "a zoomed crop asks the preview for enough pixels too" do
      html =
        avatar(
          %{
            "avatar_file_uuid" => @uuid,
            "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 4, "ar" => 1}
          },
          peek: true
        )

      assert html =~ ~s(data-avatar-peek="/phoenix_kit/file/#{@uuid}/large/)
    end

    test "off by default: an avatar renders as it always did" do
      html = avatar(%{"avatar_file_uuid" => @uuid})

      refute html =~ "data-avatar-peek"
      refute html =~ "data-avatar-frame"
    end
  end

  test "zoom buys a sharper variant for the same box" do
    # A small (sm = 32px) box normally loads "small"; the xl settings
    # preview at 3x zoom needs more source than medium holds.
    html =
      avatar(%{
        "avatar_file_uuid" => @uuid,
        "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 3, "ar" => 1}
      })

    assert html =~ "/#{@uuid}/small/"

    xl =
      avatar(
        %{
          "avatar_file_uuid" => @uuid,
          "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 3, "ar" => 1}
        },
        size: "xl"
      )

    assert xl =~ "/#{@uuid}/large/"
  end

  test "the xl size loads medium, not the 150px thumbnail" do
    # The settings-page blur: a 160px circle fed the "thumbnail" variant.
    html = avatar(%{"avatar_file_uuid" => @uuid}, size: "xl")

    assert html =~ "/#{@uuid}/medium/"
    refute html =~ "/thumbnail/"
  end

  test "a crop without an uploaded file changes nothing" do
    # OAuth avatars have no variants; the crop key must not touch them.
    html =
      avatar(%{
        "oauth_avatar_url" => "https://example.com/pic.jpg",
        "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 2, "ar" => 1}
      })

    assert html =~ "object-cover"
    refute html =~ "max-width:none"
  end

  test "an invalid stored crop degrades to uncropped" do
    html =
      avatar(%{
        "avatar_file_uuid" => @uuid,
        "avatar_crop" => %{"x" => "junk"}
      })

    assert html =~ "object-cover"
    refute html =~ "max-width:none"
  end

  test "a landscape crop buys an even sharper variant" do
    # Width-scaled variants cover the frame with their SHORT side, so a
    # 2:1 image at xl needs large where a square one was fine on medium.
    html =
      avatar(
        %{
          "avatar_file_uuid" => @uuid,
          "avatar_crop" => %{"x" => 0.5, "y" => 0.5, "zoom" => 2, "ar" => 2}
        },
        size: "xl"
      )

    assert html =~ "/#{@uuid}/large/"
  end
end
