defmodule PhoenixKitWeb.Components.MediaCanvasViewerMediaMetaTest do
  @moduledoc """
  The viewer sidebar's "Title & description" section: the file's own
  words about itself, collapsible behind a chevron, editable in the
  contexts that can already reach the metadata editor (details_path /
  edit_target hosts). Writes go through `Storage.update_file_details/3`,
  like the admin detail page's editor — one language's text, merged into
  the row as it is now, so rotation/tags survive a title edit.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  # `details_path` stands in for the host opt-in that makes the section an
  # editor at all — without one (or an `edit_target`) the save handler
  # refuses, see the "an unentitled host" test.
  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            media_details_open: false,
            details_path: "/admin/media/x",
            edit_target: nil,
            write_scope: nil,
            media_meta_status_token: 0
          },
          assigns
        )
    }
  end

  # A real row: `user_uuid` and both checksums are required, so a bare
  # name/mime map never inserts.
  defp file!(name, metadata) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "media-meta-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, file} =
      %Storage.File{}
      |> Storage.File.changeset(%{
        original_file_name: "#{name}.png",
        file_name: "#{name}.png",
        file_path: "aa/bb/#{name}",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        size: 10,
        status: "active",
        user_uuid: user.uuid,
        file_checksum: "checksum-#{n}",
        user_file_checksum: "user-checksum-#{n}",
        metadata: metadata
      })
      |> Repo.insert()

    file
  end

  describe "saving (DB)" do
    setup do
      # The keys a title edit must NOT disturb.
      %{row: file!("meta_test", %{"rotation" => 90, "tags" => ["a", "b"]})}
    end

    test "merges title and description into the row's metadata", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "  A title  ", "description" => "Words."},
          socket
        )

      assert socket.assigns.media_meta == %{title: "A title", alt: "", description: "Words."}
      assert socket.assigns.media_meta_own == socket.assigns.media_meta
      assert socket.assigns.media_meta_status == :saved

      row = Storage.get_file(file.uuid)
      assert row.metadata["title"] == "A title"
      assert row.metadata["description"] == "Words."
      assert row.metadata["rotation"] == 90, "a title edit must never eat the rotation"
      assert row.metadata["tags"] == ["a", "b"], "…or the tags"
    end

    test "tags typed in the form replace the row's, and the rotation survives", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "T", "tags" => " sea, , boats ,sky "},
          socket
        )

      assert socket.assigns.media_tags == ["sea", "boats", "sky"]
      row = Storage.get_file(file.uuid)
      assert row.metadata["tags"] == ["sea", "boats", "sky"]
      assert row.metadata["rotation"] == 90

      # A form without a tags field (the title-only callers) leaves them be.
      {:noreply, _socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "U"}, socket)

      assert Storage.get_file(file.uuid).metadata["tags"] == ["sea", "boats", "sky"]
    end

    test "a vanished row reports an error instead of raising", %{row: file} do
      Repo.delete!(file)

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "x"}, socket)

      assert socket.assigns.media_meta_status == :error
    end

    test "the viewer honours the contributor's uploader restriction", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-contributor",
          file: %{file_uuid: file.uuid},
          own_files_only: Ecto.UUID.generate(),
          media_meta_status: nil
        })

      {:noreply, updated} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "Not mine", "tags" => "changed"},
          socket
        )

      assert updated.assigns.media_meta_status == :error
      assert Storage.get_file(file.uuid).metadata == file.metadata
    end

    test "a viewer cannot write a file moved to another library", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-library",
          file: %{file_uuid: file.uuid},
          write_library_uuid: Ecto.UUID.generate(),
          media_meta_status: nil
        })

      {:noreply, updated} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "Other library"},
          socket
        )

      assert updated.assigns.media_meta_status == :error
      assert Storage.get_file(file.uuid).metadata == file.metadata
    end

    # The section renders read-only for hosts that offer no road to the
    # metadata editor — a readonly MediaGallery lightbox, which may be
    # showing an anonymous visitor. The form is absent there, so the only
    # way this event arrives is a hand-rolled push: the server, not the
    # template, has to say no.
    test "an unentitled host cannot write the row", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil,
          details_path: nil,
          edit_target: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "Injected", "description" => "Injected"},
          socket
        )

      assert socket.assigns.media_meta_status == nil, "a refusal is silent, not an error pill"
      assert socket.assigns.media_meta == %{title: "", alt: "", description: ""}

      row = Storage.get_file(file.uuid)
      refute Map.has_key?(row.metadata, "title")
      assert row.metadata["rotation"] == 90
    end

    # The title lives on the FILE row, so it shows in every folder holding the
    # file. A scoped host may write a file HOMED in its scope; one merely
    # linked in from outside — a content duplicate someone else uploaded
    # first — is theirs.
    test "a scoped host cannot retitle a file homed outside its scope", %{row: file} do
      {:ok, scope} = Storage.create_folder(%{name: "scope-#{System.unique_integer([:positive])}"})

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil,
          write_scope: scope.uuid
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "Mine now"}, socket)

      assert socket.assigns.media_meta_status == :error
      refute Map.has_key?(Storage.get_file(file.uuid).metadata, "title")
    end

    test "a scoped host may retitle a file homed inside its scope", %{row: file} do
      {:ok, scope} = Storage.create_folder(%{name: "scope-#{System.unique_integer([:positive])}"})
      {:ok, _} = Storage.update_file(file, %{folder_uuid: scope.uuid})

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil,
          write_scope: scope.uuid
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "Ours"}, socket)

      assert socket.assigns.media_meta_status == :saved
      assert Storage.get_file(file.uuid).metadata["title"] == "Ours"
    end

    test "a forged non-text field is read as empty instead of crashing", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => %{"x" => "y"}, "description" => ["z"]},
          socket
        )

      assert socket.assigns.media_meta_status == :saved
      assert Storage.get_file(file.uuid).metadata["title"] in [nil, ""]
    end

    test "a translation page saves that language only and shows the primary text where it has none",
         %{row: file} do
      {:ok, _} = Storage.update_file_details(file, %{"title" => "Harbour", "alt" => "Boats"})
      primary = PhoenixKit.Utils.Multilang.primary_language()

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta_lang: "et",
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "Sadam"}, socket)

      assert socket.assigns.media_meta == %{title: "Sadam", alt: "Boats", description: ""}
      assert socket.assigns.media_meta_own == %{title: "Sadam", alt: "", description: ""}
      assert socket.assigns.media_meta_placeholders.title == "Harbour"

      row = Storage.get_file(file.uuid)

      assert row.data == %{
               primary => %{"title" => "Harbour", "alt" => "Boats"},
               "et" => %{"title" => "Sadam"}
             }

      assert row.metadata["title"] == "Harbour", "the metadata copy is the primary language's"
      assert row.metadata["rotation"] == 90
    end

    test "a form with a block per language saves each language", %{row: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta_lang: "en",
          media_meta_langs: [%{code: "en", name: "English"}, %{code: "et", name: "Estonian"}],
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{
            "details" => %{
              "en" => %{"title" => "Harbour"},
              "et" => %{"title" => "Sadam"},
              "xx" => %{"title" => "not a language"}
            }
          },
          socket
        )

      assert socket.assigns.media_meta_status == :saved

      row = Storage.get_file(file.uuid)
      assert row.data == %{"en" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam"}}
      assert row.metadata["rotation"] == 90
    end

    test "an edit_target host may write" do
      file = file!("meta_edit_target", %{})

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", alt: "", description: ""},
          media_meta_status: nil,
          details_path: nil,
          edit_target: {MediaCanvasViewer, "host-1"}
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "Ok"}, socket)

      assert socket.assigns.media_meta_status == :saved
      assert Storage.get_file(file.uuid).metadata["title"] == "Ok"
    end
  end
end

defmodule PhoenixKitWeb.Components.MediaCanvasViewerMediaMetaUnitTest do
  @moduledoc "The DB-less half: the chevron toggle and the status clear."

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{__changed__: %{}, media_details_open: false, media_meta_status_token: 0},
          assigns
        )
    }
  end

  test "the chevron toggles the section" do
    {:noreply, socket} =
      MediaCanvasViewer.handle_event("toggle_media_details", %{}, socket_with(%{}))

    assert socket.assigns.media_details_open

    {:noreply, socket} = MediaCanvasViewer.handle_event("toggle_media_details", %{}, socket)
    refute socket.assigns.media_details_open
  end

  test "the transient save status clears" do
    {:ok, socket} =
      MediaCanvasViewer.update(
        %{action: :clear_media_meta_status, token: 3},
        socket_with(%{media_meta_status: :saved, media_meta_status_token: 3})
      )

    assert socket.assigns.media_meta_status == nil
  end

  # A second Save inside the two-second window bumps the token, so the
  # first save's timer must not wipe the status the second one just put up.
  test "a stale auto-hide timer leaves a newer status alone" do
    {:ok, socket} =
      MediaCanvasViewer.update(
        %{action: :clear_media_meta_status, token: 3},
        socket_with(%{media_meta_status: :saved, media_meta_status_token: 4})
      )

    assert socket.assigns.media_meta_status == :saved
  end
end
