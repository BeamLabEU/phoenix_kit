defmodule PhoenixKitWeb.Live.RepairLogUITest do
  @moduledoc """
  The trail of damaged copies and repairs as people read it: the History tab's
  "Damage and repairs" view with library, bucket and kind filters, the log on a
  file's storage page, and the list on a bucket's page. Every row links to its
  file, library and bucket.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.RepairLog
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    n = System.unique_integer([:positive])

    {:ok, library} =
      Libraries.create_system_library(%{name: "Holiday #{n}", slug: "holiday-#{n}"})

    {:ok, other} = Libraries.create_system_library(%{name: "Work #{n}", slug: "work-#{n}"})

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "disk-#{n}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_repair_ui_#{n}"),
        enabled: true,
        priority: 0
      })

    file =
      Repo.insert!(%StorageFile{
        original_file_name: "IMG_#{n}.jpeg",
        file_name: "IMG_#{n}.jpeg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpeg",
        file_checksum: "sha256:log-#{n}",
        user_file_checksum: "user-sha256:log-#{n}",
        size: 1,
        status: "active",
        user_uuid: user.uuid,
        library_uuid: library.uuid
      })

    audit = [actor_uuid: user.uuid, found_by: "verify"]

    Audit.log_damage(
      file,
      [%{name: "medium", bucket: bucket, path: "k/medium.jpg", result: :not_found}],
      audit
    )

    Audit.log_repair(
      file,
      [
        %{name: "medium", kind: :regenerated, bucket: nil, from: nil},
        %{
          name: "large",
          kind: :restored,
          bucket: bucket.name,
          bucket_uuid: bucket.uuid,
          from: "b2",
          from_uuid: nil
        }
      ],
      0,
      actor_uuid: user.uuid
    )

    %{
      conn: log_in_user(conn, user),
      library: library,
      other: other,
      bucket: bucket,
      photo: file,
      user: user
    }
  end

  describe "RepairLog.list/1" do
    test "names the file, the library and the bucket of each entry", ctx do
      %{rows: rows, total: 2} = RepairLog.list()

      damaged = Enum.find(rows, &(&1.kind == :damaged))

      assert damaged.file == %{
               uuid: ctx.photo.uuid,
               name: ctx.photo.original_file_name,
               exists?: true
             }

      assert damaged.library.name == ctx.library.name
      assert damaged.bucket.name == ctx.bucket.name
      assert damaged.rendition == "medium"
      assert damaged.problem == "missing"
      assert damaged.found_by == "verify"

      repaired = Enum.find(rows, &(&1.kind == :repaired))
      assert Enum.map(repaired.actions, & &1.rendition) |> Enum.sort() == ["large", "medium"]
      assert repaired.problems_left == 0
    end

    test "filters by file, bucket, library and kind", ctx do
      assert RepairLog.list(file_uuid: ctx.photo.uuid).total == 2
      assert RepairLog.list(file_uuid: Ecto.UUID.generate()).total == 0

      assert RepairLog.list(bucket_uuid: ctx.bucket.uuid).total == 2
      assert RepairLog.list(bucket_uuid: Ecto.UUID.generate()).total == 0

      assert RepairLog.list(library_uuid: ctx.library.uuid).total == 2
      assert RepairLog.list(library_uuid: ctx.other.uuid).total == 0

      assert [%{kind: :damaged}] = RepairLog.list(kind: :damaged).rows
      assert [%{kind: :repaired}] = RepairLog.list(kind: :repaired).rows
    end

    test "a file that is gone is a name without a link", ctx do
      Repo.delete!(ctx.photo)
      %{rows: rows} = RepairLog.list()

      assert Enum.all?(
               rows,
               &(&1.file.exists? == false and &1.file.name == ctx.photo.original_file_name)
             )
    end
  end

  describe "the History tab" do
    defp history(conn) do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
      render_patch(view, Routes.path("/admin/settings/media?tab=history"))
      view
    end

    defp repairs(view, extra \\ %{}) do
      view
      |> element("#media-history-filter")
      |> render_change(Map.merge(%{"filter" => "repairs"}, extra))
    end

    test "lists damage and repairs with links to the file, the library and the bucket", ctx do
      html = ctx.conn |> history() |> repairs()

      assert html =~ ctx.photo.original_file_name
      assert html =~ ~s(href="#{Routes.path("/admin/media/#{ctx.photo.uuid}/storage")}")

      assert html =~
               ~s(href="#{Routes.path("/admin/settings/media/libraries/#{ctx.library.uuid}")}")

      assert html =~ ~s(href="#{Routes.path("/admin/settings/media/buckets/#{ctx.bucket.uuid}")}")
      assert html =~ "Missing from the bucket"
      assert html =~ "Copied back into"
    end

    test "filters by library, bucket and kind", ctx do
      view = history(ctx.conn)

      html = repairs(view, %{"library" => ctx.other.uuid})
      assert html =~ "Nothing has gone wrong"
      refute html =~ ctx.photo.original_file_name

      html = repairs(view, %{"library" => ctx.library.uuid, "kind" => "damaged"})
      assert html =~ "Missing from the bucket"
      refute html =~ "Copied back into"

      html = repairs(view, %{"bucket" => ctx.bucket.uuid, "kind" => "repaired"})
      assert html =~ "Copied back into"
      refute html =~ "Missing from the bucket"
    end
  end

  test "a file's storage page has its own log, linked to the bucket", ctx do
    {:ok, view, html} = live(ctx.conn, Routes.path("/admin/media/#{ctx.photo.uuid}/storage"))

    assert has_element?(view, "#storage-log")
    assert html =~ "Missing from the bucket"
    assert html =~ ~s(href="#{Routes.path("/admin/settings/media/buckets/#{ctx.bucket.uuid}")}")
  end

  test "a bucket's page lists its damaged copies, linked to the files", ctx do
    {:ok, view, html} =
      live(ctx.conn, Routes.path("/admin/settings/media/buckets/#{ctx.bucket.uuid}"))

    assert has_element?(view, "#bucket-repairs")
    assert html =~ ~s(href="#{Routes.path("/admin/media/#{ctx.photo.uuid}/storage")}")
  end
end
