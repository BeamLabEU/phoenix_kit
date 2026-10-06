defmodule PhoenixKitWeb.Live.LibraryPageTest do
  @moduledoc """
  The page of one system library (Settings → Media → Libraries → its name): the
  overview, what it holds and where, its storage (shown, never changed), its sync,
  the annotated-thumbnail choice, the history, and renaming or deleting it. A
  user's library never opens here.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Profiles, VariantSets}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()

    {:ok, library} =
      Libraries.create_system_library(%{name: "Page lib #{System.unique_integer([:positive])}"},
        actor_uuid: user.uuid
      )

    %{conn: log_in_user(conn, user), user: user, library: library}
  end

  defp page_path(library), do: Routes.path("/admin/settings/media/libraries/#{library.uuid}")

  defp open(conn, library) do
    {:ok, view, _html} = live(conn, page_path(library))
    view
  end

  describe "opening the page" do
    test "shows the library, its address, and that it is empty", ctx do
      view = open(ctx.conn, ctx.library)
      render_async(view)
      html = render(view)

      assert html =~ ctx.library.name
      assert has_element?(view, "#library-files-count", "0")
      assert has_element?(view, "#library-folders-count", "0")
      assert html =~ Routes.path("/admin/media/library/#{ctx.library.slug}")
      assert has_element?(view, "#library-buckets-empty")
    end

    test "counts its folders", ctx do
      {:ok, _} = Storage.create_folder(%{name: "f1", library_uuid: ctx.library.uuid})
      {:ok, _} = Storage.create_folder(%{name: "f2", library_uuid: ctx.library.uuid})

      view = open(ctx.conn, ctx.library)
      assert has_element?(view, "#library-folders-count", "2")
    end

    test "an unknown id goes back to the Libraries tab", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/settings/media/libraries/#{Ecto.UUID.generate()}"))

      assert to == Routes.path("/admin/settings/media?tab=libraries")
    end

    test "a user's library does not open", %{conn: conn, user: user} do
      slug = "mine#{System.unique_integer([:positive])}"

      library =
        Repo.insert!(%Storage.Library{
          name: "Private diary",
          kind: "user",
          owner_uuid: user.uuid,
          visibility: "private",
          key_prefix: slug,
          slug: slug
        })

      assert {:error, {:live_redirect, _}} = live(conn, page_path(library))
    end

    test "the Libraries tab links to it", %{conn: conn, library: library} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media?tab=libraries"))

      assert view |> element("#media-libraries-#{library.uuid} a", library.name) |> render() =~
               page_path(library)
    end
  end

  describe "storage" do
    test "names the profile and the variant set, with no way to change them", ctx do
      {:ok, profile} =
        Profiles.create_profile(%{name: "Kept #{System.unique_integer([:positive])}"})

      {:ok, set} =
        VariantSets.create_variant_set(%{name: "Sizes #{System.unique_integer([:positive])}"})

      {:ok, library} =
        Libraries.create_system_library(
          %{
            name: "Stored #{System.unique_integer([:positive])}",
            storage_profile_uuid: profile.uuid,
            variant_set_uuid: set.uuid
          },
          []
        )

      view = open(ctx.conn, library)

      assert has_element?(view, "#library-profile", profile.name)
      assert has_element?(view, "#library-variant-set", set.name)
      refute has_element?(view, "#library-storage select")
      refute has_element?(view, "#library-storage form")
    end

    test "each bucket of the profile says what it is and where its files go", ctx do
      view = open(ctx.conn, ctx.library)

      assert has_element?(view, "#library-profile-buckets", "Local")

      # The path of a local bucket, as the Buckets list shows it.
      assert Enum.any?(Profiles.default_profile().buckets, fn row ->
               (row.bucket.provider == "local" and row.bucket.endpoint) &&
                 has_element?(view, "#library-profile-buckets", row.bucket.endpoint)
             end)
    end

    test "a library on the Default says so", ctx do
      view = open(ctx.conn, ctx.library)

      assert has_element?(
               view,
               "#library-profile",
               Profiles.profile_name(Profiles.default_uuid())
             )
    end
  end

  describe "renaming" do
    test "keeps the address and is written to the history", ctx do
      view = open(ctx.conn, ctx.library)
      new_name = "Renamed #{System.unique_integer([:positive])}"

      view |> element("#library-rename-button") |> render_click()
      view |> form("#library-rename-form", %{name: new_name}) |> render_submit()

      renamed = Libraries.get_library(ctx.library.uuid)
      assert renamed.name == new_name
      assert renamed.slug == ctx.library.slug
      assert render(view) =~ new_name
      assert has_element?(view, "#library-history-list")
    end

    test "a taken name is refused", ctx do
      {:ok, other} =
        Libraries.create_system_library(%{name: "Other #{System.unique_integer([:positive])}"})

      view = open(ctx.conn, ctx.library)

      view |> element("#library-rename-button") |> render_click()
      html = view |> form("#library-rename-form", %{name: other.name}) |> render_submit()

      assert html =~ "already the name of another library"
      assert Libraries.get_library(ctx.library.uuid).name == ctx.library.name
    end
  end

  describe "deleting" do
    test "an empty library is deleted and the page goes back to the list", ctx do
      view = open(ctx.conn, ctx.library)

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#library-delete") |> render_click()

      assert to == Routes.path("/admin/settings/media?tab=libraries")
      refute Libraries.get_library(ctx.library.uuid)
    end

    test "a library with a folder cannot be deleted, even by a forged click", ctx do
      {:ok, _} = Storage.create_folder(%{name: "busy", library_uuid: ctx.library.uuid})
      view = open(ctx.conn, ctx.library)

      assert has_element?(view, "#library-delete[disabled]")
      render_click(view, "delete", %{})
      assert Libraries.get_library(ctx.library.uuid)
    end

    test "the default library has no delete button", ctx do
      {:ok, view, _html} =
        live(ctx.conn, Routes.path("/admin/settings/media/libraries/#{Libraries.media_uuid()}"))

      refute has_element?(view, "#library-delete")
    end
  end

  describe "annotated thumbnails" do
    test "the library chooses on, off, or the site setting", ctx do
      view = open(ctx.conn, ctx.library)

      for {choice, expected} <- [{"on", true}, {"off", false}, {"default", nil}] do
        view |> form("#library-annotated", %{"annotated" => choice}) |> render_submit()
        assert Libraries.setting(ctx.library.uuid, :annotated_thumbnails) == expected
      end

      assert render(view) =~ "Library setting saved"
    end

    test "deep zoom is the library's own switch, off until it is turned on", ctx do
      view = open(ctx.conn, ctx.library)
      refute VariantSets.deep_zoom_for_library?(ctx.library.uuid)

      view |> form("#library-deep-zoom", %{"deep_zoom" => "on"}) |> render_submit()

      assert Libraries.setting(ctx.library.uuid, :deep_zoom) == true
      assert VariantSets.deep_zoom_for_library?(ctx.library.uuid)

      view |> form("#library-deep-zoom", %{"deep_zoom" => "off"}) |> render_submit()
      assert Libraries.setting(ctx.library.uuid, :deep_zoom) == false
    end

    test "the rendition set links to its tab", ctx do
      view = open(ctx.conn, ctx.library)

      assert view |> element("#library-variant-set a") |> render() =~
               Routes.path("/admin/settings/media?tab=renditions")
    end

    test "says that existing thumbnails are not regenerated", ctx do
      view = open(ctx.conn, ctx.library)
      assert has_element?(view, "#library-thumbnails", "not regenerated")
    end
  end

  describe "sync and history" do
    test "shows the sync state", ctx do
      view = open(ctx.conn, ctx.library)
      assert has_element?(view, "#library-sync [data-sync-state]")
    end

    test "lists who created the library", ctx do
      view = open(ctx.conn, ctx.library)
      assert has_element?(view, "#library-history-list")

      assert Repo.exists?(
               from(e in PhoenixKit.Activity.Entry,
                 where:
                   e.resource_uuid == ^to_string(ctx.library.uuid) and
                     e.action == "storage.library.created"
               )
             )
    end
  end
end
