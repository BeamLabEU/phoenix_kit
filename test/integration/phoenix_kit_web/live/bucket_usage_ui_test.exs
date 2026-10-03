defmodule PhoenixKitWeb.Live.BucketUsageUITest do
  @moduledoc """
  A bucket a storage profile lists is neither disabled nor deleted, and the
  admin is told which profiles hold it: the Buckets tab's "Used by" column, the
  refusals of Disable and Delete, the notice and refusal on the bucket's edit
  form, the profile delete that names the libraries standing in the way, and the
  new-bucket form's choice of profile (none by default).
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Profiles}
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()

    # The bucket form asks before it creates a missing storage path.
    root = Path.join(System.tmp_dir!(), "pk_usage_ui_bucket")
    File.mkdir_p!(root)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "usage-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    %{conn: log_in_user(conn, user), bucket: bucket}
  end

  defp free!(bucket) do
    for profile <- Profiles.list_profiles(),
        do: :ok = Profiles.remove_bucket(profile, bucket.uuid)
  end

  defp settings(conn) do
    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
    view
  end

  describe "the Buckets tab" do
    test "says which profiles use a bucket, and that a free one is not used", ctx do
      {:ok, free} =
        Storage.create_bucket(%{
          name: "free-#{System.unique_integer([:positive])}",
          provider: "local",
          endpoint: Path.join(System.tmp_dir!(), "pk_usage_ui_free"),
          enabled: true,
          priority: 0
        })

      free!(free)

      html = ctx.conn |> settings() |> render()

      assert html =~ "Used by"
      assert html =~ "Default"
      assert html =~ "primary"
      assert html =~ "Not used"
    end

    test "Disable is refused while a profile lists the bucket, naming the profile", ctx do
      view = settings(ctx.conn)

      html = render_click(view, "toggle_bucket", %{"id" => ctx.bucket.uuid})

      assert html =~ "cannot be disabled"
      assert html =~ "the &quot;Default&quot; profile (primary)"
      assert Storage.get_bucket(ctx.bucket.uuid).enabled
    end

    test "Delete is refused while a profile lists the bucket, and works once it is free",
         ctx do
      view = settings(ctx.conn)

      html = render_click(view, "delete_bucket", %{"id" => ctx.bucket.uuid})

      assert html =~ "cannot be deleted"
      assert html =~ "the &quot;Default&quot; profile (primary)"
      assert Storage.get_bucket(ctx.bucket.uuid)
      assert Enum.any?(Profiles.default_profile().buckets, &(&1.bucket_uuid == ctx.bucket.uuid))

      free!(ctx.bucket)

      html = render_click(view, "delete_bucket", %{"id" => ctx.bucket.uuid})

      assert html =~ "Bucket deleted successfully"
      refute Storage.get_bucket(ctx.bucket.uuid)
    end

    test "a free bucket is disabled and enabled as before", ctx do
      free!(ctx.bucket)
      view = settings(ctx.conn)

      assert render_click(view, "toggle_bucket", %{"id" => ctx.bucket.uuid}) =~
               "Bucket disabled successfully"

      refute Storage.get_bucket(ctx.bucket.uuid).enabled

      assert render_click(view, "toggle_bucket", %{"id" => ctx.bucket.uuid}) =~
               "Bucket enabled successfully"
    end

    test "the Used by column follows a change made on the Storage profiles tab", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Added later"})
      view = settings(ctx.conn)
      refute view |> element("#buckets-table") |> render() =~ "Added later"

      {:ok, _} = Profiles.put_bucket(profile, ctx.bucket.uuid, %{role: "backup"})

      # Opening the tab reads the usage again.
      render_patch(view, Routes.path("/admin/settings/media?tab=profiles"))
      render_patch(view, Routes.path("/admin/settings/media"))

      assert view |> element("#buckets-table") |> render() =~ "Added later"
    end
  end

  describe "the bucket's edit form" do
    test "tells that the bucket is in use, and refuses to disable it", ctx do
      {:ok, view, html} =
        live(ctx.conn, Routes.path("/admin/settings/media/buckets/#{ctx.bucket.uuid}/edit"))

      assert html =~ "This bucket is in use"
      assert html =~ "the &quot;Default&quot; profile (primary)"

      html =
        view
        |> form("#bucket-form", %{"bucket" => %{"enabled" => "false"}})
        |> render_submit()

      assert html =~ "cannot be disabled"
      assert Storage.get_bucket(ctx.bucket.uuid).enabled
    end

    test "a bucket no profile lists shows no notice and can be disabled", ctx do
      free!(ctx.bucket)

      {:ok, view, html} =
        live(ctx.conn, Routes.path("/admin/settings/media/buckets/#{ctx.bucket.uuid}/edit"))

      refute html =~ "This bucket is in use"

      view
      |> form("#bucket-form", %{"bucket" => %{"enabled" => "false"}})
      |> render_submit()

      refute Storage.get_bucket(ctx.bucket.uuid).enabled
    end
  end

  describe "adding a bucket" do
    defp new_path, do: Routes.path("/admin/settings/media/buckets/new")

    defp add_local_bucket(conn, profile_uuid) do
      root = Path.join(System.tmp_dir!(), "pk_usage_ui_new_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      name = "added-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, new_path())
      render_change(view, "validate", %{"bucket" => %{"storage_type" => "local"}})

      view
      |> form("#bucket-form", %{
        "bucket" => %{
          "name" => name,
          "storage_type" => "local",
          "endpoint" => root,
          "profile_uuid" => profile_uuid
        }
      })
      |> render_submit()

      Storage.get_bucket_by_name(name)
    end

    defp in_profiles(bucket) do
      for profile <- Profiles.list_profiles(),
          Enum.any?(profile.buckets, &(&1.bucket_uuid == bucket.uuid)),
          do: profile.name
    end

    test "the form asks which profile, and offers none first", ctx do
      {:ok, _profile} = Profiles.create_profile(%{name: "Offered"})
      {:ok, _view, html} = live(ctx.conn, new_path())

      assert html =~ "Storage profile"
      assert html =~ "None: just add the bucket"
      assert html =~ "Default (Default)"
      assert html =~ "Offered"
      assert html =~ "only added to the system"

      # None is what is selected, whatever the list holds.
      assert html =~ ~r/<option[^>]*value=""[^>]*selected|<option[^>]*selected[^>]*value=""/
    end

    test "choosing a profile says what joining it means", ctx do
      {:ok, view, _html} = live(ctx.conn, new_path())

      html =
        render_change(view, "validate", %{
          "bucket" => %{"profile_uuid" => Profiles.default_uuid()}
        })

      assert html =~ "joins this profile as a primary"
      refute html =~ "only added to the system"
    end

    test "with none chosen the bucket is in no profile", ctx do
      before = Profiles.default_profile().revision

      bucket = add_local_bucket(ctx.conn, "")

      assert bucket
      assert in_profiles(bucket) == []
      assert Profiles.default_profile().revision == before
    end

    test "with a profile chosen the bucket is in that one only", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Picked"})

      bucket = add_local_bucket(ctx.conn, profile.uuid)

      assert in_profiles(bucket) == ["Picked"]
    end

    test "the edit form has no profile choice", ctx do
      {:ok, _view, html} =
        live(ctx.conn, Routes.path("/admin/settings/media/buckets/#{ctx.bucket.uuid}/edit"))

      refute html =~ ~s(name="bucket[profile_uuid]")
    end
  end

  describe "deleting a storage profile" do
    test "is refused while libraries use it, naming the site ones", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Busy profile"})

      {:ok, library} =
        Libraries.create_system_library(%{
          name: "Brand assets #{System.unique_integer([:positive])}"
        })

      {:ok, _} = Profiles.set_library_profile(library, profile.uuid)

      view = settings(ctx.conn)
      render_patch(view, Routes.path("/admin/settings/media?tab=profiles"))

      view
      |> with_target("#media-profiles")
      |> render_click("delete_profile", %{"uuid" => profile.uuid})

      # The component tells the page, which shows the flash.
      html = render(view)

      assert html =~ "cannot be deleted"
      assert html =~ library.name
      assert Profiles.get_profile(profile.uuid)
    end
  end
end
