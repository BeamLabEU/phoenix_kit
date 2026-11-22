defmodule PhoenixKitWeb.Components.MediaViewerEmbedOptionsIntegrationTest do
  @moduledoc """
  What the lightbox does with the files a host hands it: it shows an ordinary
  file, and a file in the trash or a system-managed one (a tile chunk, an
  edited image's hidden original) is shown as unavailable even when the host
  passed its uuid — the file route would refuse both. Stepping goes over such
  a file, and over a uuid that has no file row at all, to the next one that can
  be shown, and stays where it is when there is none; the prev / next arrows
  are live only where a step would land. A file of a private library is signed
  with a time-window token.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Modules.Storage.URLSigner
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

  # A file row, or a bare uuid that has no row.
  defp uuid_of(%{uuid: uuid}), do: uuid
  defp uuid_of(uuid) when is_binary(uuid), do: uuid

  defp socket(files, current) do
    {:ok, socket} =
      MediaViewer.update(
        %{id: "v1", files: Enum.map(files, &uuid_of/1), current: uuid_of(current)},
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      )

    socket
  end

  defp step(socket, dir) do
    {:noreply, socket} = MediaViewer.handle_event("step_viewer", %{"dir" => dir}, socket)
    socket
  end

  defp key(socket, key) do
    {:noreply, socket} = MediaViewer.handle_event("viewer_keydown", %{"key" => key}, socket)
    socket
  end

  defp token_of(url), do: url |> String.split("?") |> hd() |> String.split("/") |> List.last()

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

  describe "stepping between ordinary files" do
    test "next advances to the next file and prev goes back", %{user: user} do
      [a, b, c] = files = for _ <- 1..3, do: file!(user)

      forward = step(socket(files, a), "next")
      assert forward.assigns.current_uuid == b.uuid
      assert forward.assigns.current_file.file_uuid == b.uuid

      assert step(socket(files, c), "prev").assigns.current_uuid == b.uuid
    end

    test "ArrowRight steps forward, ArrowLeft steps back", %{user: user} do
      [a, b, _c] = files = for _ <- 1..3, do: file!(user)

      assert key(socket(files, a), "ArrowRight").assigns.current_uuid == b.uuid
      assert key(socket(files, b), "ArrowLeft").assigns.current_uuid == a.uuid
    end
  end

  describe "a uuid with no file row" do
    test "is shown as unavailable, and stepping goes over it", %{user: user} do
      first = file!(user)
      ghost = Ecto.UUID.generate()
      last = file!(user)
      files = [first, ghost, last]

      assert socket(files, ghost).assigns.current_file == nil

      forward = step(socket(files, first), "next")
      assert forward.assigns.current_uuid == last.uuid

      assert step(forward, "prev").assigns.current_uuid == first.uuid
    end
  end

  describe "the prev / next arrows" do
    test "are live only where a step would land", %{user: user} do
      first = file!(user)
      trashed = file!(user, %{status: "trashed"})
      ghost = Ecto.UUID.generate()
      last = file!(user)

      only_dead_after = socket([first, trashed, ghost], first).assigns
      assert {only_dead_after.has_prev, only_dead_after.has_next} == {false, false}

      files = [first, trashed, ghost, last]
      at_first = socket(files, first).assigns
      assert {at_first.has_prev, at_first.has_next} == {false, true}

      at_last = step(socket(files, first), "next").assigns
      assert at_last.current_uuid == last.uuid
      assert {at_last.has_prev, at_last.has_next} == {true, false}
    end
  end

  describe "signing" do
    defp private_file!(user) do
      n = System.unique_integer([:positive])

      {:ok, library} =
        %Library{}
        |> Library.create_user_changeset(%{
          name: "Private #{n}",
          owner_uuid: user.uuid,
          key_prefix: "viewer#{n}",
          slug: "viewer-#{n}",
          is_default: true
        })
        |> Repo.insert()

      file = file!(user, %{library_uuid: library.uuid})
      original!(file)
      file
    end

    defp original!(file) do
      {:ok, _instance} =
        Storage.create_file_instance(%{
          variant_name: "original",
          file_name: file.file_path,
          mime_type: "image/png",
          ext: "png",
          checksum: String.duplicate("a", 64),
          size: 1,
          processing_status: "completed",
          file_uuid: file.uuid
        })
    end

    test "a file of a private library gets a time-window token, not the permanent one",
         %{user: user} do
      file = private_file!(user)
      url = socket([file], file).assigns.current_file.urls["original"]

      assert URLSigner.private_token?(token_of(url))
    end

    test "a file of the Media library keeps the permanent token", %{user: user} do
      file = file!(user)
      original!(file)
      url = socket([file], file).assigns.current_file.urls["original"]

      refute URLSigner.private_token?(token_of(url))
    end

    test "stepping to a private file signs it the same way", %{user: user} do
      first = file!(user)
      private = private_file!(user)

      url = step(socket([first, private], first), "next").assigns.current_file.urls["original"]

      assert URLSigner.private_token?(token_of(url))
    end
  end
end
