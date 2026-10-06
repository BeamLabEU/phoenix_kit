defmodule PhoenixKitWeb.Components.MediaCanvasViewerPaletteTest do
  @moduledoc """
  The palette the viewer hands Etcher.

  A user with a saved palette gets exactly that. A user with nothing
  saved — never touched the slots, or just pressed "Reset annotation
  settings" — gets `nil`, so Etcher seeds its slots from its own
  CURRENT presets.

  Regression: phoenix_kit used to keep a copy of Etcher's presets as a
  fallback constant, and the copy went stale when Etcher moved from
  pastels to full-strength hues (0.16, 2026-09-20). From then on, a
  reset — or a fresh user — drew in the washed-out pastels the rest of
  the product had moved off of, until they picked a color by hand.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @file_uuid "01900000-0000-7000-8000-0000000c0105"

  defp register!(custom_fields) do
    {:ok, user} =
      Auth.register_user(%{
        email: "viewer-palette-#{System.unique_integer([:positive])}@example.com",
        password: "hello world!"
      })

    case custom_fields do
      map when map_size(map) > 0 ->
        {:ok, user} = Auth.merge_user_custom_fields(user, map)
        user

      _ ->
        user
    end
  end

  defp open_viewer(user) do
    {:ok, socket} =
      MediaCanvasViewer.mount(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    {:ok, socket} =
      MediaCanvasViewer.update(
        %{
          id: "viewer-palette-test",
          file: %{
            file_uuid: @file_uuid,
            filename: "test.jpg",
            file_type: "image",
            mime_type: "image/jpeg",
            width: 800,
            height: 600,
            urls: %{"small" => "/f/small.jpg"}
          },
          current_user: user,
          parent_id: "mb-test"
        },
        socket
      )

    socket.assigns
  end

  test "nothing saved (a fresh user, or right after a reset): Etcher gets nil" do
    assert is_nil(open_viewer(register!(%{})).etcher_colors)
    assert is_nil(open_viewer(nil).etcher_colors)
  end

  test "a saved palette still wins over Etcher's presets" do
    user = register!(%{"etcher_colors" => ["#123456", "#abcdef"]})

    assert open_viewer(user).etcher_colors == ["#123456", "#abcdef"]
  end

  test "a saved palette of nothing but garbage reads as nothing saved" do
    user = register!(%{"etcher_colors" => ["javascript:alert(1)", 42, ""]})

    assert is_nil(open_viewer(user).etcher_colors)
  end
end
