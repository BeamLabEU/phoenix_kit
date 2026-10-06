defmodule PhoenixKitWeb.Live.StorageProfilesUITest do
  @moduledoc """
  The V205 editors: the Storage profiles tab of Settings → Media (profiles,
  their copy counts and bucket rows), the variant sets page (a tab per set,
  its flags, sizes created in the set, standard sizes kept), and the
  profile and set pickers of the Libraries tab.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Bucket, Libraries, Profiles, VariantSets}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "ui-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_ui_bucket"),
        enabled: true,
        priority: 0
      })

    %{conn: log_in_user(conn, user), bucket: bucket}
  end

  defp settings(conn) do
    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
    render_patch(view, Routes.path("/admin/settings/media?tab=profiles"))
    view
  end

  defp view_html(conn), do: conn |> settings() |> render()

  describe "the Storage profiles tab" do
    test "creates a profile, adds a bucket, changes its row and deletes it", ctx do
      view = settings(ctx.conn)

      view |> element("#media-profiles button", "New profile") |> render_click()

      view
      |> form("#media-profiles-new", %{"profile" => %{"name" => "Cold storage"}})
      |> render_submit()

      profile = Enum.find(Profiles.list_profiles(), &(&1.name == "Cold storage"))
      assert profile
      assert render(view) =~ "Cold storage"

      view
      |> form("#media-profiles-add-#{profile.uuid}", %{"bucket_uuid" => ctx.bucket.uuid})
      |> render_submit()

      assert [%{bucket_uuid: bucket_uuid}] = Profiles.get_profile(profile.uuid).buckets
      assert bucket_uuid == ctx.bucket.uuid

      view
      |> form("#media-profiles-row-#{profile.uuid}-#{ctx.bucket.uuid}", %{
        "row" => %{"role" => "backup", "status" => "read_only"}
      })
      |> render_change()

      # Changing a row saves nothing: its Save button comes alive and says so.
      assert [%{role: "primary", status: "active"}] = Profiles.get_profile(profile.uuid).buckets
      html = render(view)
      assert html =~ "Unsaved changes"

      view
      |> form("#media-profiles-row-#{profile.uuid}-#{ctx.bucket.uuid}", %{
        "row" => %{"role" => "backup", "status" => "read_only"}
      })
      |> render_submit()

      assert [%{role: "backup", status: "read_only"}] = Profiles.get_profile(profile.uuid).buckets
      html = render(view)
      refute html =~ "Unsaved changes"
      assert html =~ "Saved"

      view
      |> form("#media-profiles-form-#{profile.uuid}", %{
        "profile" => %{"copies_local" => "2", "min_copies_on_write" => "2"}
      })
      |> render_submit()

      assert %{copies_local: 2, min_copies_on_write: 2} = Profiles.get_profile(profile.uuid)

      view
      |> element("#media-profiles-#{profile.uuid} button", "Delete")
      |> render_click()

      refute Profiles.get_profile(profile.uuid)
    end

    test "the Default counts the libraries that name no profile, which use it", ctx do
      default = Profiles.default_uuid()
      before = Profiles.libraries_using(default)

      {:ok, library} =
        Libraries.create_system_library(%{
          name: "On default #{System.unique_integer([:positive])}"
        })

      assert is_nil(library.storage_profile_uuid)
      assert Profiles.libraries_using(default) == before + 1
      assert view_html(ctx.conn) =~ "Used by #{before + 1} librar"

      {:ok, profile} =
        Profiles.create_profile(%{name: "Own #{System.unique_integer([:positive])}"})

      assert Profiles.libraries_using(profile.uuid) == 0

      {:ok, _} = Profiles.set_library_profile(library, profile.uuid)
      assert Profiles.libraries_using(default) == before
      assert Profiles.libraries_using(profile.uuid) == 1
    end

    test "says what the copy counts mean with the buckets there are", ctx do
      {:ok, _} =
        Storage.create_bucket(%{
          name: "second-#{System.unique_integer([:positive])}",
          provider: "local",
          endpoint: Path.join(System.tmp_dir!(), "pk_ui_bucket_2"),
          enabled: true,
          priority: 0
        })

      html = view_html(ctx.conn)
      assert html =~ "local buckets take new files and each file is stored on 1 of them"
      assert html =~ "not mirrored"

      # As many local copies as local buckets: every file on every one of them.
      count = length(Profiles.default_profile().buckets)

      {:ok, _} =
        Profiles.update_profile(Profiles.default_profile(), %{"copies_local" => "#{count}"})

      refute view_html(ctx.conn) =~ "not mirrored"

      {:ok, _} = Profiles.update_profile(Profiles.default_profile(), %{"copies_local" => "5"})
      html = view_html(ctx.conn)
      assert html =~ "5 local copies are wanted, but only #{count} local buckets take new files"
    end

    test "the upload order is offered only where there are more buckets than copies", ctx do
      default = Profiles.default_uuid()
      count = length(Profiles.default_profile().buckets)
      assert count >= 2

      order = fn bucket ->
        "#media-profiles-row-#{default}-#{bucket} input[name='row[write_priority]']"
      end

      na = fn bucket -> "#media-profiles-order-na-#{default}-#{bucket}" end

      {:ok, _} = Profiles.update_profile(Profiles.default_profile(), %{"copies_local" => "1"})
      view = settings(ctx.conn)
      assert has_element?(view, order.(ctx.bucket.uuid))
      refute has_element?(view, na.(ctx.bucket.uuid))

      # Every local bucket gets a copy: there is nothing to order.
      {:ok, _} =
        Profiles.update_profile(Profiles.default_profile(), %{"copies_local" => "#{count}"})

      view = settings(ctx.conn)
      refute has_element?(view, order.(ctx.bucket.uuid))
      assert has_element?(view, na.(ctx.bucket.uuid))
    end

    test "a replica holds nothing while the count stays within the primaries", ctx do
      # The test database's Default already has its own primary ("Local
      # Storage"); the bucket this test made becomes the replica.
      default = Profiles.default_profile()
      {:ok, _} = Profiles.put_bucket(default, ctx.bucket.uuid, %{role: "replica"})

      view = settings(ctx.conn)
      assert render(view) =~ "Not used at this copy count: #{ctx.bucket.name}"

      {:ok, _} = Profiles.update_profile(Profiles.default_profile(), %{"copies_local" => "2"})
      refute settings(ctx.conn) |> render() =~ "Not used at this copy count"
    end

    test "the cloud count is for a profile that has a cloud bucket", ctx do
      default = Profiles.default_uuid()
      cloud_input = "#media-profiles-form-#{default} input[name='profile[copies_cloud]']"

      view = settings(ctx.conn)
      assert has_element?(view, cloud_input <> "[disabled]")

      assert has_element?(
               view,
               "#media-profiles-form-#{default} input[name='profile[copies_local]']"
             )

      cloud =
        Repo.insert!(%Bucket{
          name: "ui-cloud-#{System.unique_integer([:positive])}",
          provider: "r2",
          bucket_name: "nowhere",
          endpoint: "127.0.0.1:9",
          access_type: "signed",
          enabled: true,
          priority: 0
        })

      {:ok, _} = Profiles.put_bucket(Profiles.default_profile(), cloud.uuid, %{})

      view = settings(ctx.conn)
      assert has_element?(view, cloud_input)
      refute has_element?(view, cloud_input <> "[disabled]")

      # A cloud bucket with no cloud copies wanted holds nothing: the page says so.
      assert render(view) =~ "The cloud buckets hold nothing at 0 cloud copies"

      view
      |> form("#media-profiles-form-#{default}", %{"profile" => %{"copies_cloud" => "1"}})
      |> render_submit()

      assert %{copies_local: 1, copies_cloud: 1, copies_originals: 2} = Profiles.default_profile()
      refute render(view) =~ "The cloud buckets hold nothing"
    end

    test "cloud copies can be cleared after the last cloud bucket is removed", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Removed cloud", copies_cloud: 1})
      {:ok, _} = Profiles.put_bucket(profile, ctx.bucket.uuid, %{})
      view = settings(ctx.conn)
      selector = "#media-profiles-form-#{profile.uuid}"
      refute has_element?(view, selector <> " input[name='profile[copies_cloud]'][disabled]")
      view |> form(selector, %{"profile" => %{"copies_cloud" => "0"}}) |> render_submit()
      assert Profiles.get_profile(profile.uuid).copies_cloud == 0
    end

    test "the upload minimum can increase together with the copy counts", ctx do
      view = settings(ctx.conn)
      selector = "#media-profiles-form-#{Profiles.default_uuid()}"

      assert has_element?(
               view,
               selector <> " input[name='profile[min_copies_on_write]'][max='5']"
             )

      view
      |> form(selector, %{"profile" => %{"copies_local" => "2", "min_copies_on_write" => "2"}})
      |> render_submit()

      assert Profiles.default_profile().min_copies_on_write == 2
    end

    test "the profile's own form saves on its Save button, with a sign of it", ctx do
      view = settings(ctx.conn)
      default = Profiles.default_uuid()
      form = "#media-profiles-form-#{default}"

      before = Profiles.default_profile().copies_local

      view |> form(form, %{"profile" => %{"copies_local" => "3"}}) |> render_change()
      assert Profiles.default_profile().copies_local == before
      assert render(view) =~ "Unsaved changes"

      view |> form(form, %{"profile" => %{"copies_local" => "3"}}) |> render_submit()
      assert Profiles.default_profile().copies_local == 3
      refute render(view) =~ "Unsaved changes"
    end

    test "a bucket used by another profile says so in the picker, the flash and both rows", ctx do
      view = settings(ctx.conn)
      default = Profiles.default_uuid()
      bucket = ctx.bucket
      default_badge = "#media-profiles-shared-#{default}-#{bucket.uuid}"

      # Alone in the Default, nothing is shared.
      refute has_element?(view, default_badge)

      view |> element("#media-profiles button", "New profile") |> render_click()

      view
      |> form("#media-profiles-new", %{"profile" => %{"name" => "Archive"}})
      |> render_submit()

      profile = Enum.find(Profiles.list_profiles(), &(&1.name == "Archive"))

      # The picker says where the bucket already is, and why that matters.
      html = render(view)
      assert html =~ "#{bucket.name} (also in Default)"
      assert html =~ "is already used by another profile"

      view
      |> form("#media-profiles-add-#{profile.uuid}", %{"bucket_uuid" => bucket.uuid})
      |> render_submit()

      assert render(view) =~ "It is shared with Default"

      # Each side names the other.
      assert view
             |> element("#media-profiles-shared-#{profile.uuid}-#{bucket.uuid}")
             |> render() =~ "Also in Default"

      assert view |> element(default_badge) |> render() =~ "Also in Archive"
    end

    test "a reconnect replays the forms without calling them unsaved", ctx do
      view = settings(ctx.conn)
      default = Profiles.default_uuid()
      form = "#media-profiles-form-#{default}"

      # LiveView recovers a form after a reconnect by sending its values to the
      # event named by phx-auto-recover; that must not read as an edit.
      assert render(view) =~ ~s(phx-auto-recover="recover")
      view |> with_target("#media-profiles") |> render_hook("recover", %{"key" => "x"})
      refute render(view) =~ "Unsaved changes"

      view |> form(form, %{"profile" => %{"copies_local" => "3"}}) |> render_change()
      assert render(view) =~ "Unsaved changes"
    end

    test "the bucket table's headings read like the other tables' and its actions stay in view",
         ctx do
      html = view_html(ctx.conn)

      # Sentence case, as the Libraries and Buckets tables have it: no heading
      # (a tooltip one included) is forced into capitals.
      refute html =~
               ~r/class="[^"]*\buppercase\b[^"]*"[^>]*>\s*(Role|Upload order|Serve order|Bucket)/

      refute html =~ ~s(<span class="uppercase">)

      assert html =~ "sticky right-0"
    end

    test "offers nothing when every bucket is already used", ctx do
      html = view_html(ctx.conn)
      refute html =~ "Not used at this copy count"
      refute html =~ "Keep every original on"
    end

    test "the bucket rows sit on one grid, each control under its heading", ctx do
      html = view_html(ctx.conn)

      assert html =~ "Upload order"
      assert html =~ ~s(placeholder="Random")
      refute html =~ ~s(placeholder="Pool")
      assert html =~ "Draining (moving files out)"
      assert html =~ "Read-only (no new files)"
      assert html =~ "Local copies"
      assert html =~ "Cloud copies"
      refute html =~ "Copies of each size and tile"
      refute html =~ ~s(name="row[stores]")
      refute html =~ "Stores"
    end

    test "the Default profile lists the buckets and cannot be deleted", ctx do
      view = settings(ctx.conn)
      default = Profiles.default_uuid()

      assert has_element?(view, "#media-profiles-#{default}-#{ctx.bucket.uuid}")
      refute has_element?(view, "#media-profiles-#{default} button", "Delete")
    end
  end

  describe "the Renditions tab" do
    test "creates a set, saves its flags, and a new rendition lands in it", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media?tab=renditions"))

      view
      |> form("#media-renditions-new-set", %{"new_set" => %{"name" => "Photography"}})
      |> render_submit()

      set = Enum.find(VariantSets.list_variant_sets(), &(&1.name == "Photography"))
      assert set
      assert_patch(view, Routes.path("/admin/settings/media?tab=renditions&set=#{set.uuid}"))

      # Deep zoom is the library's, not the set's: no tiles checkbox here.
      refute has_element?(view, "input[name='variant_set[generate_tiles]']")

      view
      |> form("#media-renditions-set-form-#{set.uuid}", %{
        "variant_set" => %{"selectable" => "true"}
      })
      |> render_submit()

      assert %{selectable: true} = VariantSets.get_variant_set(set.uuid)

      # The standard renditions it started with cannot be deleted from the page.
      html = render(view)
      assert html =~ "standard"
      refute html =~ ~s(phx-click="delete_dimension")

      {:ok, form_view, _html} =
        live(conn, Routes.path("/admin/settings/media/renditions/new/image?set=#{set.uuid}"))

      form_view
      |> form("#dimension-form", %{
        "dimension" => %{"name" => "grid_2x", "width" => "480", "quality" => "80"}
      })
      |> render_submit()

      assert Storage.get_dimension_by_name("grid_2x", set.uuid)
      refute Storage.get_dimension_by_name("grid_2x")
    end

    test "explains what a rendition is", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media?tab=renditions"))
      assert has_element?(view, "#media-renditions-about", "A rendition is a smaller")
    end
  end
end
