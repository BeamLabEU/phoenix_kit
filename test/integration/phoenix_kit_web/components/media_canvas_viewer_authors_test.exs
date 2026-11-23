defmodule PhoenixKitWeb.Components.MediaCanvasViewerAuthorsTest do
  @moduledoc """
  `authors: false` against a real row: a marker drawn by someone carries that
  person's name in its stored metadata (`comment_author`, the byline Etcher's
  tooltip shows). Opening the file with `authors: false` sends the shape with
  no name, and the row keeps it — the viewer is told less, the data is not
  rewritten, and a later drag of the marker by the person looking does not
  erase who drew it.
  """
  use PhoenixKit.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @author "AuthorUniq Jane"

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "authors-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "a.png",
        file_name: "a.png",
        file_path: "x/a.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        width: 800,
        height: 600,
        user_uuid: user.uuid
      })

    file
  end

  defp marker!(file) do
    {:ok, shape} =
      Annotations.create(%{
        file_uuid: file.uuid,
        kind: "marker",
        geometry: %{"x" => 1, "y" => 2},
        metadata: %{"comment_author" => @author}
      })

    shape
  end

  defp file_map(file) do
    %{
      file_uuid: file.uuid,
      filename: "a.png",
      file_type: "image",
      mime_type: "image/png",
      size: 1,
      inserted_at: ~U[2026-05-19 12:00:00Z],
      width: 800,
      height: 600,
      urls: %{"small" => "/f/small.png", "original" => "/f/original.png"}
    }
  end

  defp open(file, viewer, extra) do
    render_component(
      MediaCanvasViewer,
      Map.merge(
        %{
          id: "viewer-#{file.uuid}",
          file: file_map(file),
          current_user: viewer,
          parent_id: "host",
          comments: false
        },
        extra
      )
    )
  end

  setup do
    viewer = user!()
    file = file!(user!())
    {:ok, viewer: viewer, file: file, shape: marker!(file)}
  end

  test "default: the opened viewer carries the byline (the control)", ctx do
    assert open(ctx.file, ctx.viewer, %{}) =~ "AuthorUniq"
  end

  test "authors: false: the shape is sent without it, and is still there", ctx do
    html = open(ctx.file, ctx.viewer, %{authors: false})

    refute html =~ "AuthorUniq"
    assert html =~ to_string(ctx.shape.uuid)
  end

  test "authors: false: the row keeps the byline, also after the marker is dragged", ctx do
    {:ok, socket} =
      MediaCanvasViewer.mount(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    {:ok, socket} =
      MediaCanvasViewer.update(
        %{
          id: "viewer-#{ctx.file.uuid}",
          file: file_map(ctx.file),
          current_user: ctx.viewer,
          parent_id: "host",
          comments: false,
          authors: false
        },
        socket
      )

    # The server side still holds the whole row: a write rebuilds from it.
    assert [%{metadata: %{"comment_author" => @author}}] = socket.assigns.viewer_annotations

    moved = %{
      "uuid" => to_string(ctx.shape.uuid),
      "kind" => "marker",
      "geometry" => %{"x" => 50, "y" => 60},
      "style" => %{},
      "metadata" => %{}
    }

    assert {:noreply, _} =
             MediaCanvasViewer.handle_event(
               "etcher:annotations-changed",
               %{"annotations" => [moved]},
               socket
             )

    assert [stored] = Annotations.list_for_file(ctx.file.uuid)
    assert stored.geometry == %{"x" => 50, "y" => 60}
    assert stored.metadata["comment_author"] == @author
  end
end
