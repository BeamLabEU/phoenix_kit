defmodule PhoenixKitWeb.Live.Users.OwnMediaTest do
  @moduledoc """
  Media shows each viewer only what is theirs (`dev_docs/plans/2026-09-30-media-by-viewer.md`):
  a holder of `media` without `media.view_all` sees the files they uploaded and the
  folders that are theirs or lead to their files; a holder of `media.view_all` and
  an Admin see everything; a user library is one switcher away. Through the real
  page, including events crafted from a console.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.FileController

  setup do
    n = System.unique_integer([:positive])

    {:ok, own} = Roles.create_role(%{name: "Own media #{n}"})
    {:ok, _} = Permissions.grant_permission(own.uuid, "media")

    {:ok, editor_role} = Roles.create_role(%{name: "Editors #{n}"})
    {:ok, _} = Permissions.grant_permission(editor_role.uuid, "media")
    {:ok, _} = Permissions.grant_permission(editor_role.uuid, "media.view_all")

    alice = user!(own, "alice")
    bob = user!(own, "bob")
    editor = user!(editor_role, "editor")
    {admin, _token} = create_admin_user()

    events = folder!("Events-#{n}", nil, admin)
    customers = folder!("Customers-#{n}", nil, admin)
    mine = folder!("Mine-#{n}", nil, alice)

    a1 = file!("ALICE-EVENTS-#{n}", alice, events)
    b1 = file!("BOB-EVENTS-#{n}", bob, events)
    b2 = file!("BOB-CUSTOMERS-#{n}", bob, customers)

    %{
      n: n,
      alice: alice,
      bob: bob,
      editor: editor,
      admin: admin,
      events: events,
      customers: customers,
      mine: mine,
      a1: a1,
      b1: b1,
      b2: b2
    }
  end

  defp user!(role, tag) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "own-media-#{tag}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp folder!(name, parent, creator) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: name,
        parent_uuid: parent && parent.uuid,
        user_uuid: creator.uuid
      })

    folder
  end

  defp file!(name, owner, folder) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: name,
        file_name: "f-#{n}.png",
        file_path: "x/#{n}.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: owner.uuid,
        folder_uuid: folder && folder.uuid
      })

    file
  end

  defp media(conn, user, query \\ "") do
    live(log_in_user(conn, user), Routes.path("/admin/media" <> query))
  end

  defp browser(view), do: with_target(view, "#media-browser")

  # ── the page ──────────────────────────────────────────────────────────────

  describe "the root" do
    test "a holder of media alone sees the folders that are theirs or lead to theirs", %{
      conn: conn,
      alice: alice,
      n: n
    } do
      {:ok, _view, html} = media(conn, alice)

      assert html =~ "Events-#{n}"
      assert html =~ "Mine-#{n}"
      refute html =~ "Customers-#{n}"
    end

    test "with media.view_all, or as an Admin, everything is there", %{
      conn: conn,
      editor: editor,
      admin: admin,
      n: n
    } do
      for user <- [editor, admin] do
        {:ok, _view, html} = media(build_conn(), user)
        assert html =~ "Events-#{n}"
        assert html =~ "Customers-#{n}"
      end

      _ = conn
    end
  end

  describe "inside a folder" do
    test "only the viewer's files are listed", %{
      conn: conn,
      alice: alice,
      events: events,
      a1: a1,
      b1: b1
    } do
      {:ok, _view, html} = media(conn, alice, "?folder=#{events.uuid}")

      assert html =~ a1.uuid
      refute html =~ b1.uuid
    end

    test "an editor sees everyone's", %{
      conn: conn,
      editor: editor,
      events: events,
      a1: a1,
      b1: b1
    } do
      {:ok, _view, html} = media(conn, editor, "?folder=#{events.uuid}")

      assert html =~ a1.uuid
      assert html =~ b1.uuid
    end

    test "a folder the viewer cannot see is not opened by its link", %{
      conn: conn,
      alice: alice,
      customers: customers,
      b2: b2
    } do
      {:ok, _view, html} = media(conn, alice, "?folder=#{customers.uuid}")

      refute html =~ b2.uuid
    end
  end

  describe "a file named by a hand-edited link" do
    test "opens the viewer for the viewer's own, not for someone else's", %{
      conn: conn,
      alice: alice,
      n: n,
      a1: a1,
      b1: b1
    } do
      {:ok, _view, html} = media(conn, alice, "?file=#{a1.uuid}")
      assert html =~ "ALICE-EVENTS-#{n}"

      {:ok, _view, html} = media(build_conn(), alice, "?file=#{b1.uuid}")
      refute html =~ "BOB-EVENTS-#{n}"
    end
  end

  describe "events crafted from a console" do
    setup %{conn: conn, alice: alice} do
      {:ok, view, _html} = media(conn, alice)
      %{view: view}
    end

    test "opening someone else's file", %{view: view, n: n, b1: b1} do
      html = render_click(browser(view), "click_file", %{"file-uuid" => b1.uuid})

      refute html =~ "BOB-EVENTS-#{n}"
    end

    test "trashing someone else's file, or a folder that is not hers", %{
      view: view,
      b1: b1,
      events: events
    } do
      render_click(browser(view), "trash_file", %{"file_uuid" => b1.uuid})
      render_click(browser(view), "trash_folder", %{"folder_uuid" => events.uuid})

      assert %{status: "active"} = Storage.get_file(b1.uuid)
      assert %{trashed_at: nil} = Storage.get_folder(events.uuid)
    end

    test "renaming or deleting a folder that merely holds her file", %{view: view, events: events} do
      name = events.name

      render_click(browser(view), "rename_folder", %{
        "folder_uuid" => events.uuid,
        "name" => "Hacked"
      })

      render_click(browser(view), "delete_folder", %{"folder_uuid" => events.uuid})

      assert %{name: ^name, trashed_at: nil} = Storage.get_folder(events.uuid)
    end

    test "hyphenated folder params cannot change someone else's folder", %{
      view: view,
      events: events
    } do
      render_click(browser(view), "change_folder_color", %{
        "folder-uuid" => events.uuid,
        "color" => "red"
      })

      render_click(browser(view), "set_header_size", %{
        "folder-uuid" => events.uuid,
        "size" => "large"
      })

      folder = Storage.get_folder(events.uuid)
      assert folder.color == events.color
      assert folder.header_size == events.header_size
    end

    test "navigating into a folder she cannot see", %{view: view, customers: customers, n: n} do
      html = render_click(browser(view), "navigate_folder", %{"folder_uuid" => customers.uuid})

      refute html =~ "BOB-CUSTOMERS-#{n}"
    end

    test "her own folder she may rename", %{view: view, mine: mine} do
      render_click(browser(view), "rename_folder", %{
        "folder_uuid" => mine.uuid,
        "name" => "Renamed mine"
      })

      assert %{name: "Renamed mine"} = Storage.get_folder(mine.uuid)
    end

    test "trashing her own file works", %{view: view, a1: a1} do
      render_click(browser(view), "trash_file", %{"file_uuid" => a1.uuid})

      assert %{status: "trashed"} = Storage.get_file(a1.uuid)
    end

    test "a folder holding someone else's file cannot be trashed even if she made it", %{
      view: view,
      mine: mine,
      bob: bob
    } do
      _ = file!("BOB-IN-MINE", bob, mine)

      render_click(browser(view), "trash_folder", %{"folder_uuid" => mine.uuid})

      assert %{trashed_at: nil} = Storage.get_folder(mine.uuid)
    end
  end

  describe "the file's own page" do
    test "is not found for someone else's file; found for her own and for an editor", %{
      conn: conn,
      alice: alice,
      editor: editor,
      n: n,
      a1: a1,
      b1: b1
    } do
      {:ok, _view, html} = live(log_in_user(conn, alice), Routes.path("/admin/media/#{b1.uuid}"))
      assert html =~ "File Not Found"
      refute html =~ "BOB-EVENTS-#{n}"

      {:ok, _view, html} =
        live(log_in_user(build_conn(), alice), Routes.path("/admin/media/#{a1.uuid}"))

      assert html =~ "ALICE-EVENTS-#{n}"

      {:ok, _view, html} =
        live(log_in_user(build_conn(), editor), Routes.path("/admin/media/#{b1.uuid}"))

      assert html =~ "BOB-EVENTS-#{n}"
    end
  end

  describe "editing and the trash" do
    test "changing someone else's file needs media.view_all", %{
      alice: alice,
      editor: editor,
      a1: a1,
      b1: b1
    } do
      alice_scope = Scope.for_user(alice)

      assert Libraries.can?(alice_scope, a1, :edit)
      refute Libraries.can?(alice_scope, b1, :edit)
      assert Libraries.can?(Scope.for_user(editor), b1, :edit)
    end

    test "a trashed file's URL answers its uploader, an editor and an Admin only", %{
      alice: alice,
      bob: bob,
      editor: editor,
      admin: admin,
      b1: b1
    } do
      {:ok, trashed} = Storage.trash_file(b1)

      refute FileController.authorize_trashed_read(alice, trashed)
      assert FileController.authorize_trashed_read(bob, trashed)
      assert FileController.authorize_trashed_read(editor, trashed)
      assert FileController.authorize_trashed_read(admin, trashed)
    end
  end

  # ── user libraries in the same page ──────────────────────────────────────

  describe "user libraries" do
    setup %{alice: alice} do
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
      n = System.unique_integer([:positive])
      {:ok, role} = Roles.create_role(%{name: "Librarians #{n}"})

      for key <- ~w(media storage storage.create_library),
          do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

      {:ok, _} = Roles.assign_role(alice, role.name)
      alice = Repo.get!(Auth.User, alice.uuid)

      {:ok, library} =
        Libraries.create_user_library(Scope.for_user(alice), %{"name" => "Holiday #{n}"})

      %{alice: alice, library: library}
    end

    test "joins the header switcher, hinted Mine, and opens at /admin/media/my", %{
      conn: conn,
      alice: alice,
      library: library
    } do
      {:ok, _view, html} = media(conn, alice)

      assert html =~ ~s(id="pk-title-switcher-list")
      assert html =~ "Mine"
      assert html =~ library.name

      {:ok, _view, html} =
        live(log_in_user(build_conn(), alice), Routes.path("/admin/media/my/#{library.slug}"))

      assert html =~ library.name
    end

    test "another user's library is not opened there, nor one that does not exist", %{
      conn: conn,
      bob: bob,
      alice: alice,
      library: library
    } do
      assert {:error, {kind, %{to: to, flash: flash}}} =
               live(log_in_user(conn, bob), Routes.path("/admin/media/my/#{library.uuid}"))

      assert kind in [:redirect, :live_redirect]
      assert to == Routes.path("/admin/media")
      assert flash["error"] == "Library not found"

      assert {:error, {_kind, %{flash: %{"error" => "Library not found"}}}} =
               live(
                 log_in_user(build_conn(), alice),
                 Routes.path("/admin/media/my/#{Ecto.UUID.generate()}")
               )
    end
  end

  test "a site library is still a Library struct of kind system", %{n: n} do
    assert %Library{kind: "system"} = Libraries.get_library(Libraries.media_uuid())
    assert is_integer(n)
  end

  describe "where libraries are browsed" do
    setup %{alice: alice} do
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
      n = System.unique_integer([:positive])
      {:ok, role} = Roles.create_role(%{name: "Both #{n}"})

      for key <- ~w(media storage storage.create_library),
          do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

      {:ok, _} = Roles.assign_role(alice, role.name)
      alice = Repo.get!(Auth.User, alice.uuid)

      {:ok, library} =
        Libraries.create_user_library(Scope.for_user(alice), %{"name" => "Trips #{n}"})

      {:ok, only_role} = Roles.create_role(%{name: "Storage only #{n}"})

      for key <- ~w(storage storage.create_library),
          do: {:ok, _} = Permissions.grant_permission(only_role.uuid, key)

      {:ok, carol} =
        Auth.register_user(%{
          "email" => "own-media-carol-#{n}@example.com",
          "password" => "ValidPassword123!"
        })

      {:ok, carol} = Auth.admin_confirm_user(carol)
      {:ok, _} = Roles.assign_role(carol, only_role.name)

      %{alice: alice, library: library, carol: Repo.get!(Auth.User, carol.uuid)}
    end

    test "a holder of media is sent from /admin/libraries into Media", %{
      conn: conn,
      alice: alice,
      library: library
    } do
      assert {:error, {_kind, %{to: to}}} =
               live(log_in_user(conn, alice), Routes.path("/admin/libraries"))

      assert to == Routes.path("/admin/media/my/#{library.slug}")

      assert {:error, {_kind, %{to: to}}} =
               live(
                 log_in_user(build_conn(), alice),
                 Routes.path("/admin/libraries/#{library.slug}")
               )

      assert to == Routes.path("/admin/media/my/#{library.slug}")
    end

    test "a holder of storage alone keeps using /admin/libraries", %{conn: conn, carol: carol} do
      assert {:ok, _view, html} = live(log_in_user(conn, carol), Routes.path("/admin/libraries"))
      assert html =~ "Manage libraries"
    end

    test "an Admin keeps /admin/libraries, for other people's libraries", %{
      conn: conn,
      admin: admin
    } do
      assert {:ok, _view, _html} = live(log_in_user(conn, admin), Routes.path("/admin/libraries"))
    end

    test "the sidebar entry is for those who do not have Media", %{
      alice: alice,
      carol: carol,
      admin: admin
    } do
      refute Libraries.show_libraries_entry?(Scope.for_user(alice))
      assert Libraries.show_libraries_entry?(Scope.for_user(carol))
      assert Libraries.show_libraries_entry?(Scope.for_user(admin))
    end

    test "the profile's Media tab opens a library where its holder browses", %{
      conn: conn,
      alice: alice,
      carol: carol,
      library: library
    } do
      {:ok, _view, html} = live(log_in_user(conn, alice), Routes.path("/profile/settings/media"))
      assert html =~ ~s(href="#{Routes.path("/admin/media/my/#{library.slug}")}")

      {:ok, _} = Libraries.create_user_library(Scope.for_user(carol), %{"name" => "Carol's"})

      {:ok, _view, html} =
        live(log_in_user(build_conn(), carol), Routes.path("/profile/settings/media"))

      assert html =~ ~s(href="#{Routes.path("/admin/libraries/carol-s")}")
    end
  end
end
