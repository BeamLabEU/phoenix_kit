defmodule PhoenixKitWeb.Components.MediaBrowserScopedRootTest do
  @moduledoc """
  A browser scoped to one folder acts on what that folder SHOWS.

  A host embeds the browser scoped to a folder of its own — a sub-order's
  "Files" tab, say — and it opens at that folder's root, where
  `current_folder` is `nil` while the heading names the sub-order. A file
  attached to the sub-order is usually a LINK: it lives in the order's own
  folder and the sub-order's folder merely points at it.

  Removing one from that view used to do nothing at all. With no current
  folder the code asked whether the file LIVED in the scope instead of
  whether the scope showed it — false for a link home elsewhere — and the
  handler returned without a flash, an error, or a change. From the outside:
  press Delete, nothing happens.

  The root of a scoped browser IS the scope folder — the move handler has
  always said so — and there a link is removed by taking the link away,
  leaving the file where it lives for every other folder holding it.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FolderLink}
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "scoped-root-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "s.png",
        file_name: "s.png",
        file_path: "x/s.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    file
  end

  defp folder!(user, name) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        user_uuid: user.uuid
      })

    folder
  end

  # The browser as a host embeds it: scoped to the sub-order's folder, opened
  # at its root, so `current_folder` is nil.
  defp scoped_root_socket(scope_folder) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "mb",
        flash: %{},
        readonly: false,
        library_uuid: nil,
        own_files_only: nil,
        scope_folder_id: scope_folder.uuid,
        current_folder: nil,
        expanded_stacks: [],
        filter_trash: false,
        filter_orphaned: false,
        file_view: "folders",
        current_page: 1,
        per_page: 50,
        search_query: "",
        sort_by: "newest",
        only_file_type: nil,
        uploaded_files: [],
        folders: [],
        stacks: [],
        expanded_stack: nil,
        total_count: 0,
        selected_files: MapSet.new(),
        selected_folders: MapSet.new()
      }
    }
  end

  defp linked?(file, folder),
    do:
      Repo.one(
        from(l in FolderLink,
          where: l.file_uuid == ^file.uuid and l.folder_uuid == ^folder.uuid,
          select: count()
        )
      ) == 1

  defp fresh(file), do: Repo.get(File, file.uuid)

  setup do
    user = user!()
    order = folder!(user, "order-8")
    sub = folder!(user, "sub-1")
    media = file!(user)

    # The file lives in the order's folder and is only pointed at from the
    # sub-order's — what `ResourceFolders.attach/2` does for a file that
    # already has a home.
    {:ok, _} = Storage.move_file_to_folder(media.uuid, order.uuid, nil)
    {:ok, _} = Storage.attach_file_to_folder(fresh(media), sub.uuid)

    %{user: user, order: order, sub: sub, media: media}
  end

  describe "removing a linked file from a scoped browser's root" do
    test "takes the link away and says so", ctx do
      assert linked?(ctx.media, ctx.sub), "the sub-order points at it"

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "delete_file",
          %{"file-uuid" => ctx.media.uuid},
          scoped_root_socket(ctx.sub)
        )

      refute linked?(ctx.media, ctx.sub), "the sub-order no longer shows it"

      assert to_string(fresh(ctx.media).folder_uuid) == to_string(ctx.order.uuid),
             "and the file still lives in the order it belongs to"

      assert fresh(ctx.media).status == "active", "removing a link never trashes the file"

      # The browser's flash goes to the host LiveView (a component's own
      # flash never reaches the page): it arrives as a message.
      assert_received {MediaBrowser, "mb", {:flash, :info, _}},
                      "the press has to say something — silence is the bug being fixed"
    end

    test "a file that the scope does not show at all is refused, out loud", ctx do
      # A stale or forged uuid: nothing in this browser points at it. Nothing
      # happens to it, and the person pressing the button is told.
      stranger = file!(ctx.user)
      elsewhere = folder!(ctx.user, "elsewhere")
      {:ok, _} = Storage.move_file_to_folder(stranger.uuid, elsewhere.uuid, nil)

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "delete_file",
          %{"file-uuid" => stranger.uuid},
          scoped_root_socket(ctx.sub)
        )

      assert fresh(stranger).status == "active"
      assert to_string(fresh(stranger).folder_uuid) == to_string(elsewhere.uuid)

      assert_received {MediaBrowser, "mb", {:flash, :error, _}},
                      "a refusal is not a silent no-op either"
    end

    test "dragging it to the trash removes it from here, not from its home", ctx do
      # `trash_file` shares the gate, and refused with "Cannot move file
      # outside the allowed scope" — an error about scope for a file the
      # folder was displaying.
      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "trash_file",
          %{"file_uuid" => ctx.media.uuid},
          scoped_root_socket(ctx.sub)
        )

      refute linked?(ctx.media, ctx.sub)
      assert fresh(ctx.media).status == "active", "the order keeps its file"
      assert_received {MediaBrowser, "mb", {:flash, :info, _}}
      refute_received {MediaBrowser, "mb", {:flash, :error, _}}
    end

    test "a selection holding it is removed too", ctx do
      # `delete_selected` filters the selection through the same gate, so a
      # linked file was quietly dropped from the batch.
      socket = scoped_root_socket(ctx.sub)
      socket = put_in(socket.assigns.selected_files, MapSet.new([ctx.media.uuid]))

      {:noreply, _socket} = MediaBrowser.handle_event("delete_selected", %{}, socket)

      refute linked?(ctx.media, ctx.sub)
      assert fresh(ctx.media).status == "active"
    end

    test "a file that lives in the scope is trashed, as before", ctx do
      # Unchanged: the scope folder is this file's home, so removing it from
      # there is a trash rather than an unlink.
      own = file!(ctx.user)
      {:ok, _} = Storage.move_file_to_folder(own.uuid, ctx.sub.uuid, nil)

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "delete_file",
          %{"file-uuid" => own.uuid},
          scoped_root_socket(ctx.sub)
        )

      assert fresh(own).status == "trashed"
      assert_received {MediaBrowser, "mb", {:flash, :info, _}}
    end
  end
end
