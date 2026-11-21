defmodule PhoenixKitWeb.Components.MediaViewerEmbedOptionsTest do
  @moduledoc """
  The lightbox's embedding options (`can_annotate`, `own_files_only`,
  `write_scope`, `comments`) and what it will show at all. No database: what
  needs one is in
  `test/integration/phoenix_kit_web/components/media_viewer_embed_options_test.exs`.

  A unit test cannot open a file: with no repo started a lookup raises. So a
  test that returns for a uuid the lightbox was never given shows it was not
  even looked up.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Component
  alias Phoenix.LiveView.Rendered
  alias PhoenixKit.Modules.Storage
  alias PhoenixKitWeb.Components.MediaCanvasViewer
  alias PhoenixKitWeb.Components.MediaViewer

  @u1 "01900000-0000-7000-8000-000000000001"
  @u2 "01900000-0000-7000-8000-000000000002"
  @u3 "01900000-0000-7000-8000-000000000003"
  @outside "01900000-0000-7000-8000-0000000000ff"

  defp fresh_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  # A lightbox whose current file resolved, built without the database.
  defp assigns_with_file(update_assigns) do
    {:ok, socket} =
      MediaViewer.update(
        Map.merge(%{id: "v1", files: [@u1, @u2, @u3], current: nil}, update_assigns),
        fresh_socket()
      )

    socket.assigns
    |> Map.put(:current_uuid, @u1)
    |> Map.put(:current_file, %{
      file_uuid: @u1,
      filename: "a.jpg",
      file_type: "image",
      mime_type: "image/jpeg",
      size: 1,
      inserted_at: ~U[2026-05-19 12:00:00Z],
      width: 800,
      height: 600,
      urls: %{"original" => "/f/original.jpg"}
    })
    |> Map.put(:myself, %Phoenix.LiveComponent.CID{cid: 1})
  end

  # The assigns the lightbox hands the canvas viewer: the one `Component`
  # struct in the rendered tree.
  defp child_assigns(assigns) do
    assigns
    |> MediaViewer.render()
    |> find_component()
    |> case do
      %Component{component: MediaCanvasViewer, assigns: child} -> child
    end
  end

  defp find_component(%Component{} = component), do: component
  defp find_component(%Rendered{dynamic: dynamic}), do: find_component(dynamic.(false))
  defp find_component(list) when is_list(list), do: Enum.find_value(list, &find_component/1)
  defp find_component(_other), do: nil

  describe "defaults: every existing host renders as before" do
    test "the canvas viewer receives the values it assumes when told nothing" do
      child = child_assigns(assigns_with_file(%{}))

      assert child.can_annotate == true
      assert child.comments == true
      assert child.own_files_only == nil
      assert child.write_scope == nil
    end

    test "the options are not added when the host passes none to the lightbox" do
      {:ok, socket} = MediaViewer.update(%{id: "v1", files: [@u1], current: nil}, fresh_socket())

      assert socket.assigns.can_annotate == true
      assert socket.assigns.comments == true
      assert socket.assigns.own_files_only == nil
      assert socket.assigns.write_scope == nil
    end
  end

  describe "each option reaches the canvas viewer" do
    test "can_annotate" do
      assert child_assigns(assigns_with_file(%{can_annotate: false})).can_annotate == false
    end

    test "own_files_only" do
      child = child_assigns(assigns_with_file(%{own_files_only: @u2}))
      assert child.own_files_only == @u2
    end

    test "write_scope" do
      child = child_assigns(assigns_with_file(%{write_scope: @u3}))
      assert child.write_scope == @u3
    end

    test "comments" do
      assert child_assigns(assigns_with_file(%{comments: false})).comments == false
    end

    test "the embedding for an outside person, all together" do
      child =
        child_assigns(
          assigns_with_file(%{own_files_only: @u2, write_scope: @u3, comments: false})
        )

      assert {child.own_files_only, child.write_scope, child.comments, child.can_annotate} ==
               {@u2, @u3, false, true}
    end

    test "the lightbox does not hand the canvas viewer a way to write the file" do
      child = child_assigns(assigns_with_file(%{own_files_only: @u2}))

      # The file's title, details, rotation and trash/edit buttons stay off:
      # no details_path / edit_target / persist_rotation / can_trash is passed.
      for key <- [:details_path, :edit_target, :persist_rotation, :can_trash, :featured, :pick] do
        refute Map.get(child, key), "#{key} must not reach the canvas viewer"
      end
    end
  end

  describe "a uuid the lightbox was not given is never opened" do
    # Any lookup of a file raises here (no repo is started), so a test that
    # returns shows the uuid was never looked up.
    test "a seed outside `files` is not looked up" do
      {:ok, socket} =
        MediaViewer.update(%{id: "v1", files: [@u1, @u2], current: @outside}, fresh_socket())

      assert socket.assigns.current_uuid == @outside
      assert socket.assigns.current_file == nil
    end

    test "a navigated-to uuid that a later `files` no longer holds is dropped" do
      socket = %{fresh_socket() | assigns: Map.merge(fresh_socket().assigns, base(@u2))}

      {:ok, socket} = MediaViewer.update(%{id: "v1", files: [@u1], current: @u1}, socket)

      assert socket.assigns.current_uuid == @u2
      assert socket.assigns.current_file == nil
    end

    test "step_viewer from a uuid outside `files` goes nowhere" do
      socket = %{fresh_socket() | assigns: Map.merge(fresh_socket().assigns, base(@outside))}

      for dir <- ["prev", "next"] do
        {:noreply, after_step} = MediaViewer.handle_event("step_viewer", %{"dir" => dir}, socket)
        assert after_step.assigns.current_uuid == @outside
      end
    end

    test "step_viewer before the first and past the last file stays where it is" do
      first = %{fresh_socket() | assigns: Map.merge(fresh_socket().assigns, base(@u1))}
      last = %{fresh_socket() | assigns: Map.merge(fresh_socket().assigns, base(@u3))}

      {:noreply, s1} = MediaViewer.handle_event("step_viewer", %{"dir" => "prev"}, first)
      {:noreply, s2} = MediaViewer.handle_event("step_viewer", %{"dir" => "next"}, last)

      assert s1.assigns.current_uuid == @u1
      assert s2.assigns.current_uuid == @u3
    end

    test "a uuid carried by a stepping event is ignored" do
      socket = %{fresh_socket() | assigns: Map.merge(fresh_socket().assigns, base(@u3))}

      {:noreply, after_step} =
        MediaViewer.handle_event(
          "step_viewer",
          %{"dir" => "next", "uuid" => @outside, "file_uuid" => @outside},
          socket
        )

      assert after_step.assigns.current_uuid == @u3
    end
  end

  describe "events the lightbox does not own" do
    # What the canvas viewer posts to its parent when the host asked for the
    # matching button (a picker, featured, trash) — none of which the lightbox
    # does — and whatever else a client cares to push at the component.
    @foreign [
      {"trash_file", %{"file_uuid" => @outside}},
      {"restore_file", %{"file-uuid" => @outside}},
      {"delete_file", %{"file-uuid" => @outside}},
      {"set_featured", %{"file-uuid" => @outside}},
      {"unset_featured", %{"file-uuid" => @outside}},
      {"viewer_pick", %{"file-uuid" => @outside}},
      {"gallery_go", %{"uuid" => @outside}},
      {"step_viewer", %{"dir" => "sideways"}},
      {"step_viewer", %{}},
      {"viewer_keydown", %{}},
      {"no_such_event", %{}}
    ]

    for {event, params} <- @foreign do
      test "#{event} #{inspect(params)} is ignored, not a crash" do
        socket = %{fresh_socket() | assigns: Map.merge(fresh_socket().assigns, base(@u2))}

        assert {:noreply, after_event} =
                 MediaViewer.handle_event(unquote(event), unquote(Macro.escape(params)), socket)

        assert after_event.assigns.current_uuid == @u2
        refute_received {MediaViewer, _, _}
      end
    end
  end

  describe "servable?/1" do
    defp row(attrs), do: struct(Storage.File, attrs)

    test "an ordinary file is shown" do
      assert MediaViewer.servable?(row(%{status: "active", system_managed: false}))
    end

    test "a system-managed file is never shown, whatever its status" do
      refute MediaViewer.servable?(row(%{status: "active", system_managed: true}))
    end

    test "a trashed file is not shown" do
      refute MediaViewer.servable?(row(%{status: "trashed", system_managed: false}))
    end
  end

  defp base(current) do
    %{
      id: "v1",
      files: [@u1, @u2, @u3],
      current_uuid: current,
      current_file: nil,
      current_user: nil,
      notify: nil,
      can_annotate: true,
      comments: true,
      own_files_only: nil,
      write_scope: nil
    }
  end
end
