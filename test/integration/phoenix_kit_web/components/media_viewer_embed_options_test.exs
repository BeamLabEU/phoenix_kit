defmodule PhoenixKitWeb.Components.MediaViewerEmbedOptionsIntegrationTest do
  @moduledoc """
  What the lightbox does with the files a host hands it: it shows an ordinary
  file, and a file in the trash or a system-managed one (a tile chunk, an
  edited image's hidden original) is shown as unavailable even when the host
  passed its uuid — the file route would refuse both. Stepping goes over such
  a file to the next one that can be shown, and stays where it is when there
  is none.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaViewer

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "viewer-embed-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user, attrs \\ %{}) do
    {:ok, file} =
      Storage.create_file(
        Map.merge(
          %{
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
          },
          attrs
        )
      )

    file
  end

  defp socket(files, current) do
    {:ok, socket} =
      MediaViewer.update(
        %{id: "v1", files: Enum.map(files, & &1.uuid), current: current.uuid},
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      )

    socket
  end

  defp step(socket, dir) do
    {:noreply, socket} = MediaViewer.handle_event("step_viewer", %{"dir" => dir}, socket)
    socket
  end

  setup do
    user = user!()
    {:ok, user: user}
  end

  test "an ordinary file is shown", %{user: user} do
    file = file!(user)
    assert %{file_uuid: uuid} = socket([file], file).assigns.current_file
    assert uuid == file.uuid
  end

  test "a trashed file is not shown even when its uuid is in `files`", %{user: user} do
    file = file!(user, %{status: "trashed"})
    assert socket([file], file).assigns.current_file == nil
  end

  test "a system-managed file is not shown even when its uuid is in `files`", %{user: user} do
    parent = file!(user)

    child =
      file!(user, %{system_managed: true, user_uuid: nil, parent_file_uuid: parent.uuid})

    assert socket([child], child).assigns.current_file == nil
  end

  test "stepping goes over a trashed and a system-managed file", %{user: user} do
    first = file!(user)
    trashed = file!(user, %{status: "trashed"})
    parent = file!(user)
    chunk = file!(user, %{system_managed: true, user_uuid: nil, parent_file_uuid: parent.uuid})
    last = file!(user)
    files = [first, trashed, chunk, last]

    forward = step(socket(files, first), "next")
    assert forward.assigns.current_uuid == last.uuid
    assert forward.assigns.current_file.file_uuid == last.uuid

    back = step(forward, "prev")
    assert back.assigns.current_uuid == first.uuid
  end

  test "stepping stays put when nothing after the file can be shown", %{user: user} do
    first = file!(user)
    trashed = file!(user, %{status: "trashed"})

    stayed = step(socket([first, trashed], first), "next")

    assert stayed.assigns.current_uuid == first.uuid
    assert stayed.assigns.current_file.file_uuid == first.uuid
  end
end
