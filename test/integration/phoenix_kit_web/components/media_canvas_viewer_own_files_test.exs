defmodule PhoenixKitWeb.Components.MediaCanvasViewerOwnFilesTest do
  @moduledoc """
  `own_files_only` covers the drawings: a person embedded with it changes only
  the files they uploaded, and drawing, changing, deleting, replying to and
  re-titling a shape are writes to the file's annotations. On a file someone
  else uploaded each of them is refused on the server — the template's flag is
  UX, the event handlers are the boundary — and the stored annotations stay as
  they were. Looking at them stays open. Without `own_files_only` nothing
  changes.
  """
  use PhoenixKit.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "own-shapes-#{System.unique_integer([:positive])}@example.com",
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

  defp shape!(file, title \\ "Original") do
    {:ok, shape} =
      Annotations.create(%{
        file_uuid: file.uuid,
        kind: "rectangle",
        geometry: %{"x" => 1, "y" => 2, "w" => 3, "h" => 4},
        title: title
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

  # The assigns an embedded viewer holds, as the browser hands them over —
  # `can_annotate: true` on purpose: the template flag must not be what
  # refuses.
  defp socket(file, viewer, own_files_only) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "viewer-#{file.uuid}",
        dom_scope: nil,
        file: file_map(file),
        board: nil,
        can_annotate: true,
        comments: true,
        current_user: viewer,
        details_path: nil,
        edit_target: nil,
        write_scope: nil,
        own_files_only: own_files_only,
        write_library_uuid: nil,
        viewer_uuid: nil,
        viewer_annotations: MediaCanvasViewer.load_annotations_for(file.uuid),
        replying_annotation_uuid: nil,
        reply_parent_uuid: nil
      }
    }
  end

  defp wire(shape) do
    %{
      "uuid" => to_string(shape.uuid),
      "kind" => "rectangle",
      "geometry" => shape.geometry,
      "style" => shape.style || %{},
      "metadata" => %{}
    }
  end

  defp new_wire,
    do: %{
      "uuid" => Ecto.UUID.generate(),
      "kind" => "rectangle",
      "geometry" => %{"x" => 9, "y" => 9, "w" => 9, "h" => 9},
      "style" => %{},
      "metadata" => %{}
    }

  defp titles(file), do: file.uuid |> Annotations.list_for_file() |> Enum.map(& &1.title)

  describe "someone else's file, own_files_only set" do
    setup do
      me = user!()
      others = file!(user!())
      shape = shape!(others)
      {:ok, me: me, others: others, shape: shape}
    end

    test "a forged empty list does not wipe the drawings", ctx do
      assert {:noreply, _} =
               MediaCanvasViewer.handle_event(
                 "etcher:annotations-changed",
                 %{"annotations" => []},
                 socket(ctx.others, ctx.me, ctx.me.uuid)
               )

      assert titles(ctx.others) == ["Original"]
    end

    test "a new shape is not stored, and a changed one is not rewritten", ctx do
      changed =
        ctx.shape |> wire() |> Map.put("geometry", %{"x" => 7, "y" => 7, "w" => 7, "h" => 7})

      assert {:noreply, _} =
               MediaCanvasViewer.handle_event(
                 "etcher:annotations-changed",
                 %{"annotations" => [changed, new_wire()]},
                 socket(ctx.others, ctx.me, ctx.me.uuid)
               )

      assert [stored] = Annotations.list_for_file(ctx.others.uuid)
      assert stored.geometry == ctx.shape.geometry
    end

    test "Reply opens nothing", ctx do
      assert {:noreply, socket} =
               MediaCanvasViewer.handle_event(
                 "annotation_reply",
                 %{"uuid" => to_string(ctx.shape.uuid)},
                 socket(ctx.others, ctx.me, ctx.me.uuid)
               )

      assert socket.assigns.replying_annotation_uuid == nil
      assert socket.assigns.reply_parent_uuid == nil
    end

    test "a title edited from the thread is not written", ctx do
      assert {:ok, _} =
               MediaCanvasViewer.update(
                 %{
                   action: :annotation_title_updated,
                   metadata_value: to_string(ctx.shape.uuid),
                   label: "Hijacked"
                 },
                 socket(ctx.others, ctx.me, ctx.me.uuid)
               )

      assert titles(ctx.others) == ["Original"]
    end

    test "the viewer renders read-only: shapes locked, no tools", ctx do
      html =
        render_component(MediaCanvasViewer, %{
          id: "viewer-render-#{ctx.others.uuid}",
          file: file_map(ctx.others),
          current_user: ctx.me,
          parent_id: "host",
          own_files_only: ctx.me.uuid
        })

      assert html =~ ~s(data-toolbar="false")
      assert html =~ ~s(data-tools="[]")
      # The drawings are still there to look at.
      assert html =~ to_string(ctx.shape.uuid)
    end
  end

  describe "the person's own file, own_files_only set" do
    test "stays writable: the shape is stored, the title is changed, the tools are on" do
      me = user!()
      mine = file!(me)
      shape = shape!(mine)

      new = new_wire()

      assert {:noreply, _} =
               MediaCanvasViewer.handle_event(
                 "etcher:annotations-changed",
                 %{"annotations" => [wire(shape), new]},
                 socket(mine, me, me.uuid)
               )

      assert length(Annotations.list_for_file(mine.uuid)) == 2

      assert {:ok, _} =
               MediaCanvasViewer.update(
                 %{
                   action: :annotation_title_updated,
                   metadata_value: to_string(shape.uuid),
                   label: "Renamed"
                 },
                 socket(mine, me, me.uuid)
               )

      assert "Renamed" in titles(mine)

      html =
        render_component(MediaCanvasViewer, %{
          id: "viewer-render-#{mine.uuid}",
          file: file_map(mine),
          current_user: me,
          parent_id: "host",
          own_files_only: me.uuid
        })

      refute html =~ ~s(data-toolbar="false")
    end
  end

  describe "without own_files_only" do
    test "someone else's file is written as before" do
      me = user!()
      others = file!(user!())
      shape = shape!(others)

      assert {:noreply, _} =
               MediaCanvasViewer.handle_event(
                 "etcher:annotations-changed",
                 %{"annotations" => [wire(shape), new_wire()]},
                 socket(others, me, nil)
               )

      assert length(Annotations.list_for_file(others.uuid)) == 2

      html =
        render_component(MediaCanvasViewer, %{
          id: "viewer-render-#{others.uuid}",
          file: file_map(others),
          current_user: me,
          parent_id: "host"
        })

      refute html =~ ~s(data-toolbar="false")
    end
  end
end
