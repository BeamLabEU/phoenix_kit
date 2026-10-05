defmodule PhoenixKitWeb.Live.BucketPageTest do
  @moduledoc """
  The page of one site bucket (Settings → Media → Buckets → its name): the
  overview, which profiles use it, what it holds, the connection probe (a
  button, never on open), the history, and the guarded actions. A user's own
  bucket never opens here, and a user's profile or library is counted, never
  named.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{FileLocation, ProfileBucket, Profiles, StorageProfile}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()

    root = Path.join(System.tmp_dir!(), "pk_bucket_page_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, bucket} =
      Storage.create_bucket(
        %{
          name: "page-#{System.unique_integer([:positive])}",
          provider: "local",
          endpoint: root,
          enabled: true,
          priority: 0
        },
        profile: nil
      )

    %{conn: log_in_user(conn, user), user: user, bucket: bucket, root: root}
  end

  defp page_path(bucket), do: Routes.path("/admin/settings/media/buckets/#{bucket.uuid}")

  defp open(conn, bucket) do
    {:ok, view, _html} = live(conn, page_path(bucket))
    view
  end

  defp put_in_profile!(bucket, profile) do
    Repo.insert!(%ProfileBucket{profile_uuid: profile.uuid, bucket_uuid: bucket.uuid})
  end

  defp location!(bucket, variant, size) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "bucket-page-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "a#{n}.txt",
        file_name: "a#{n}.txt",
        file_path: "bp/#{n}",
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: size,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, instance} =
      Storage.create_file_instance(%{
        variant_name: variant,
        file_name: "bp/#{n}/#{variant}.txt",
        mime_type: "text/plain",
        ext: "txt",
        checksum: "c",
        size: size,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    Repo.insert!(%FileLocation{
      path: "bp/#{n}/#{variant}.txt",
      status: "active",
      file_instance_uuid: instance.uuid,
      bucket_uuid: bucket.uuid
    })
  end

  defp move_to_library!(location, library_uuid) do
    Repo.update_all(
      from(f in Storage.File,
        join: fi in Storage.FileInstance,
        on: fi.file_uuid == f.uuid,
        where: fi.uuid == ^location.file_instance_uuid
      ),
      set: [library_uuid: library_uuid]
    )
  end

  describe "opening the page" do
    test "shows the bucket, its location and that nothing uses it", ctx do
      view = open(ctx.conn, ctx.bucket)
      html = render(view)

      assert html =~ ctx.bucket.name
      assert html =~ ctx.root
      assert has_element?(view, "#bucket-usage", "No storage profile uses this bucket")
    end

    test "buckets/new is still the new-bucket form, not a bucket page", %{conn: conn} do
      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/media/buckets/new"))
      assert html =~ "bucket-form"
    end

    test "an unknown id goes back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/settings/media/buckets/#{Ecto.UUID.generate()}"))

      assert to == Routes.path("/admin/settings/media")
    end

    test "a user's own bucket does not open", %{conn: conn, user: user} do
      {:ok, bucket} =
        Repo.insert(%Storage.Bucket{
          name: "Personal #{System.unique_integer([:positive])}",
          provider: "s3",
          bucket_name: "mine",
          integration_uuid: Ecto.UUID.generate(),
          access_type: "signed",
          owner_uuid: user.uuid
        })

      assert {:error, {:live_redirect, _}} = live(conn, page_path(bucket))
    end

    test "keeps legacy credentials out of assigns and preserves them on toggle", ctx do
      bucket =
        Repo.insert!(%Storage.Bucket{
          name: "Legacy cloud bucket",
          provider: "s3",
          bucket_name: "legacy",
          region: "us-east-1",
          access_key_id: "legacy-id",
          secret_access_key: "legacy-secret",
          enabled: true
        })

      view = open(ctx.conn, bucket)
      socket = :sys.get_state(view.pid).socket
      assert socket.assigns.bucket.access_key_id == nil
      assert socket.assigns.bucket.secret_access_key == nil
      assert socket.assigns.legacy_keys?
      assert render(view) =~ "Keys on bucket"

      view |> element("#bucket-toggle") |> render_click()
      updated = Storage.get_bucket(bucket.uuid)
      refute updated.enabled
      assert updated.access_key_id == "legacy-id"

      assert Encryption.decrypt_value(updated.secret_access_key) ==
               {:ok, "legacy-secret"}
    end

    test "the Buckets list links to it", %{conn: conn, bucket: bucket} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))

      assert has_element?(view, ~s(#buckets-table a[href="#{page_path(bucket)}"]))
    end
  end

  describe "used by" do
    test "names the site's profiles and their libraries, counts a personal profile", ctx do
      {:ok, profile} =
        Profiles.create_profile(%{name: "Cloud #{System.unique_integer([:positive])}"})

      put_in_profile!(ctx.bucket, profile)

      personal =
        Repo.insert!(%StorageProfile{name: "Secret profile", owner_uuid: ctx.user.uuid})

      put_in_profile!(ctx.bucket, personal)

      html = ctx.conn |> open(ctx.bucket) |> render()

      assert html =~ profile.name
      assert html =~ "A personal storage profile"
      refute html =~ "Secret profile"
    end

    test "adds the bucket to a profile", ctx do
      {:ok, profile} =
        Profiles.create_profile(%{name: "Adds #{System.unique_integer([:positive])}"})

      view = open(ctx.conn, ctx.bucket)

      view
      |> form("#bucket-add-to-profile", %{"profile_uuid" => profile.uuid})
      |> render_submit()

      assert has_element?(view, "#bucket-usage-#{profile.uuid}")
      assert Map.has_key?(Profiles.bucket_usage([ctx.bucket.uuid]), to_string(ctx.bucket.uuid))
    end
  end

  describe "contents and health" do
    test "counts files, objects and bytes, originals apart from derived", ctx do
      location!(ctx.bucket, "original", 1000)
      location!(ctx.bucket, "thumbnail", 200)

      view = open(ctx.conn, ctx.bucket)
      render_async(view)

      assert has_element?(view, "#bucket-files-count", "2")
      assert has_element?(view, "#bucket-objects-count", "2")
      assert has_element?(view, "#bucket-originals", "1 originals")
      assert has_element?(view, "#bucket-originals", "1 derived")
      assert has_element?(view, "#bucket-location-health", "Copies stored here")
    end

    test "names a site library, counts a user's library without naming it", ctx do
      site = location!(ctx.bucket, "original", 300)
      personal = location!(ctx.bucket, "original", 700)

      slug = "secret#{System.unique_integer([:positive])}"

      user_library =
        Repo.insert!(%Storage.Library{
          name: "Private diary",
          kind: "user",
          owner_uuid: ctx.user.uuid,
          visibility: "private",
          key_prefix: slug,
          slug: slug
        })

      move_to_library!(personal, user_library.uuid)

      contents = Storage.bucket_contents(ctx.bucket.uuid)
      assert contents.personal == %{libraries: 1, files: 1, objects: 1, bytes: 700}
      assert [%{files: 1, bytes: 300}] = contents.libraries
      assert site

      view = open(ctx.conn, ctx.bucket)
      render_async(view)

      html = view |> element("#bucket-libraries") |> render()
      assert html =~ "1 personal library"
      refute html =~ "Private diary"
    end

    test "shared keys count every logical file and each library", ctx do
      first = location!(ctx.bucket, "original", 300)
      second = location!(ctx.bucket, "original", 300)

      Repo.update_all(from(l in FileLocation, where: l.uuid == ^second.uuid),
        set: [path: first.path]
      )

      contents = Storage.bucket_contents(ctx.bucket.uuid)
      assert %{files: 2, objects: 1, bytes: 300} = contents
      assert [%{files: 2, objects: 1, bytes: 300}] = contents.libraries

      slug = "shared#{System.unique_integer([:positive])}"

      personal =
        Repo.insert!(%Storage.Library{
          name: "Private shared library",
          kind: "user",
          owner_uuid: ctx.user.uuid,
          visibility: "private",
          key_prefix: slug,
          slug: slug
        })

      move_to_library!(second, personal.uuid)

      contents = Storage.bucket_contents(ctx.bucket.uuid)
      assert %{files: 2, objects: 1, bytes: 300} = contents
      assert [%{files: 1, objects: 1, bytes: 300}] = contents.libraries
      assert %{libraries: 1, files: 1, objects: 1, bytes: 300} = contents.personal
    end

    test "bucket_totals agrees with bucket_contents for a list of buckets", ctx do
      first = location!(ctx.bucket, "original", 300)
      second = location!(ctx.bucket, "original", 300)
      location!(ctx.bucket, "thumbnail", 50)

      Repo.update_all(from(l in FileLocation, where: l.uuid == ^second.uuid),
        set: [path: first.path]
      )

      {:ok, empty} =
        Storage.create_bucket(
          %{
            name: "Empty #{System.unique_integer([:positive])}",
            provider: "local",
            endpoint: Path.join(ctx.root, "empty"),
            enabled: true
          },
          profile: nil
        )

      totals = Storage.bucket_totals([ctx.bucket.uuid, empty.uuid])
      contents = Storage.bucket_contents(ctx.bucket.uuid)

      assert totals[to_string(ctx.bucket.uuid)] ==
               Map.take(contents, [:files, :objects, :bytes])

      assert %{files: 3, objects: 2, bytes: 350} = totals[to_string(ctx.bucket.uuid)]
      refute Map.has_key?(totals, to_string(empty.uuid))
      assert Storage.bucket_totals([]) == %{}
    end

    test "a draining bucket says how many files are still on it", ctx do
      {:ok, profile} =
        Profiles.create_profile(%{name: "Drain #{System.unique_integer([:positive])}"})

      put_in_profile!(ctx.bucket, profile)

      Repo.update_all(
        from(r in ProfileBucket, where: r.bucket_uuid == ^ctx.bucket.uuid),
        set: [status: "draining"]
      )

      location!(ctx.bucket, "original", 10)

      view = open(ctx.conn, ctx.bucket)
      render_async(view)

      assert has_element?(view, "#bucket-draining", "still stored here")
    end
  end

  describe "the connection probe" do
    test "does not run when the page opens", ctx do
      view = open(ctx.conn, ctx.bucket)
      render_async(view)

      refute has_element?(view, "#bucket-probe-result")
    end

    test "runs on the button and shows its result with the time", ctx do
      view = open(ctx.conn, ctx.bucket)

      view |> element("#bucket-probe") |> render_click()
      render_async(view)

      assert has_element?(view, "#bucket-probe-result", "Connection works")
      assert has_element?(view, "#bucket-probe-result", "Tested")
    end

    test "reports a failing bucket", ctx do
      File.rm_rf!(ctx.root)
      File.write!(ctx.root, "a file, not a directory")

      view = open(ctx.conn, ctx.bucket)
      view |> element("#bucket-probe") |> render_click()
      render_async(view)

      assert has_element?(view, "#bucket-probe-result", "Connection failed")
    end
  end

  describe "actions" do
    test "disables and enables a free bucket", ctx do
      view = open(ctx.conn, ctx.bucket)

      view |> element("#bucket-toggle") |> render_click()
      refute Storage.get_bucket(ctx.bucket.uuid).enabled

      view |> element("#bucket-toggle") |> render_click()
      assert Storage.get_bucket(ctx.bucket.uuid).enabled
    end

    test "refuses to disable or delete a bucket a profile uses", ctx do
      {:ok, profile} =
        Profiles.create_profile(%{name: "Uses #{System.unique_integer([:positive])}"})

      put_in_profile!(ctx.bucket, profile)
      view = open(ctx.conn, ctx.bucket)

      assert view |> element("#bucket-toggle") |> render_click() =~ "cannot be disabled"
      assert Storage.get_bucket(ctx.bucket.uuid).enabled

      assert view |> element("#bucket-delete") |> render_click() =~ "cannot be deleted"
      assert Storage.get_bucket(ctx.bucket.uuid)
    end

    test "deletes a free bucket and returns to the list", ctx do
      view = open(ctx.conn, ctx.bucket)

      view |> element("#bucket-delete") |> render_click()
      assert_redirect(view, Routes.path("/admin/settings/media"))
      refute Storage.get_bucket(ctx.bucket.uuid)
    end
  end

  describe "the log" do
    alias PhoenixKit.Modules.Storage.BucketLog

    test "is empty until something is logged", ctx do
      view = open(ctx.conn, ctx.bucket)

      assert has_element?(view, "#bucket-log-table", "Nothing logged yet.")
      assert has_element?(view, "#bucket-log-failures", "0")
    end

    test "shows failures, repeats once with their count, and the day's total", ctx do
      for _ <- 1..3, do: BucketLog.record(ctx.bucket, "write", false, message: "Disk full")
      BucketLog.record(ctx.bucket, "read", false, message: "Timed out")

      view = open(ctx.conn, ctx.bucket)

      assert has_element?(view, "#bucket-log-failures", "4")
      assert has_element?(view, "#bucket-log-table", "Disk full")
      assert has_element?(view, "#bucket-log-table", "× 3")
      assert has_element?(view, "#bucket-log-last-failure")
    end

    test "a probe lands in the log, and the last result outlives a reload", ctx do
      view = open(ctx.conn, ctx.bucket)
      view |> element("#bucket-probe") |> render_click()
      render_async(view)

      assert has_element?(view, "#bucket-log-table", "Probe")
      assert has_element?(view, "#bucket-log-latency")

      # A new visit has not probed, yet the page knows what the last probe said.
      reopened = open(ctx.conn, ctx.bucket)
      assert has_element?(reopened, "#bucket-probe-result", "Connection works")
    end

    test "patching to another bucket resets the previous probe", ctx do
      Storage.probe_bucket(ctx.bucket)

      {:ok, other} =
        Storage.create_bucket(
          %{name: "Other bucket", provider: "local", endpoint: ctx.root, enabled: true},
          profile: nil
        )

      view = open(ctx.conn, ctx.bucket)
      assert has_element?(view, "#bucket-probe-result", "Connection works")
      render_patch(view, page_path(other))
      render_async(view)
      refute has_element?(view, "#bucket-probe-result")
      assert has_element?(view, "#bucket-log-table", "Nothing logged yet.")
    end

    test "can be narrowed to failures", ctx do
      Storage.probe_bucket(ctx.bucket)
      BucketLog.record(ctx.bucket, "delete", false, message: "Access denied")

      view = open(ctx.conn, ctx.bucket)
      assert has_element?(view, "#bucket-log-table", "Probe")

      view |> form("#bucket-log-filter", %{"filter" => "failures"}) |> render_change()

      refute has_element?(view, "#bucket-log-table", "Probe")
      assert has_element?(view, "#bucket-log-table", "Access denied")
    end

    test "says so, instead of failing, where the table does not exist", ctx do
      # A host that has not run V208 yet: the page still opens.
      Repo.query!("DROP TABLE public.phoenix_kit_bucket_log")

      view = open(ctx.conn, ctx.bucket)
      assert has_element?(view, "#bucket-log-unavailable")
      assert has_element?(view, "#bucket-overview")
    end
  end

  describe "history" do
    test "lists the changes to the bucket and to its place in a profile", ctx do
      {:ok, profile} =
        Profiles.create_profile(%{name: "Hist #{System.unique_integer([:positive])}"})

      :ok = Profiles.add_bucket(profile.uuid, ctx.bucket, actor_uuid: ctx.user.uuid)

      {:ok, _} = Storage.update_bucket(ctx.bucket, %{priority: 4}, actor_uuid: ctx.user.uuid)

      view = open(ctx.conn, ctx.bucket)
      html = view |> element("#bucket-history-list") |> render()

      assert html =~ ctx.user.email
      assert html =~ "storage.bucket.updated"
      assert html =~ "storage.profile.bucket_added"
      refute html =~ "Nothing recorded yet."
    end
  end
end
