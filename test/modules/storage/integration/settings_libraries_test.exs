defmodule PhoenixKitWeb.Live.Modules.Storage.SettingsLibrariesTest do
  @moduledoc """
  The Libraries tab of Settings → Media (`LibrariesComponent`): what each
  system library holds and where, linking to its page, and creating one. Renaming
  and deleting are on the library's page (`library_page_test.exs`).
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/media")

  defp admin_view(conn) do
    {user, _token} = create_admin_user()
    {:ok, view, html} = live(log_in_user(conn, user), @path)
    {view, html}
  end

  defp name, do: "Lib #{System.unique_integer([:positive])}"

  test "the tab lists Media as the default, linking to its page, with what it holds", %{
    conn: conn
  } do
    {:ok, _} = Storage.create_folder(%{name: "counted-#{System.unique_integer([:positive])}"})
    {view, html} = admin_view(conn)

    assert html =~ "media-tab-libraries"
    row = view |> element("#media-libraries-#{Libraries.media_uuid()}") |> render()

    assert row =~ "Media"
    assert row =~ "Default"

    assert row =~
             ~s(href="#{Routes.path("/admin/settings/media/libraries/#{Libraries.media_uuid()}")}")

    # Nothing to rename, delete or re-point from the list.
    refute row =~ "Delete"
    refute row =~ "Rename"
    refute row =~ "<select"
  end

  test "a library's storage is shown as text, not a dropdown", %{conn: conn} do
    {:ok, profile} =
      Storage.Profiles.create_profile(%{name: "Cold #{System.unique_integer([:positive])}"})

    {:ok, library} =
      Libraries.create_system_library(%{name: name(), storage_profile_uuid: profile.uuid})

    {view, _html} = admin_view(conn)
    row = view |> element("#media-libraries-#{library.uuid}") |> render()

    assert row =~ profile.name
    refute row =~ "<select"
  end

  test "creating a library adds it, with its own address", %{conn: conn} do
    {view, _html} = admin_view(conn)
    library_name = name()

    view |> element("#media-libraries button", "New library") |> render_click()
    view |> form("#media-libraries-new", %{name: library_name}) |> render_submit()
    # The flash is put by the page, on the message the tab sends it.
    html = render(view)

    library = Enum.find(Libraries.list_system_libraries(), &(&1.name == library_name))
    assert library
    assert html =~ Routes.path("/admin/settings/media/libraries/#{library.uuid}")
    assert html =~ "created"
  end

  test "a taken name is refused with the reason", %{conn: conn} do
    {:ok, existing} = Libraries.create_system_library(%{name: name()})
    {view, _html} = admin_view(conn)

    view |> element("#media-libraries button", "New library") |> render_click()
    view |> form("#media-libraries-new", %{name: existing.name}) |> render_submit()
    html = render(view)

    assert html =~ "already the name of another library"
  end

  describe "choosing storage when creating" do
    test "with only the Default of each there is nothing to choose", %{conn: conn} do
      {view, _html} = admin_view(conn)
      view |> element("#media-libraries button", "New library") |> render_click()

      refute has_element?(view, "#media-libraries-new select")
    end

    test "profiles and sets created in another tab can be chosen without reloading", %{conn: conn} do
      {view, _html} = admin_view(conn)
      render_patch(view, @path <> "?tab=profiles")
      view |> element("#media-profiles button", "New profile") |> render_click()

      profile_name = "Fresh profile #{System.unique_integer([:positive])}"
      view |> form("#media-profiles-new", %{profile: %{name: profile_name}}) |> render_submit()
      profile = Enum.find(Storage.Profiles.list_profiles(), &(&1.name == profile_name))

      render_patch(view, @path <> "?tab=renditions")
      set_name = "Fresh set #{System.unique_integer([:positive])}"
      view |> form("#media-renditions-new-set", %{new_set: %{name: set_name}}) |> render_submit()
      set = Enum.find(Storage.VariantSets.list_variant_sets(), &(&1.name == set_name))

      render_patch(view, @path <> "?tab=libraries")
      view |> element("#media-libraries button", "New library") |> render_click()
      library_name = name()

      view
      |> form("#media-libraries-new", %{name: library_name, profile: profile.uuid, set: set.uuid})
      |> render_submit()

      library = Enum.find(Libraries.list_system_libraries(), &(&1.name == library_name))
      assert library.storage_profile_uuid == profile.uuid
      assert library.variant_set_uuid == set.uuid
    end

    test "new choices are refreshed even while the Libraries tab stays open", %{conn: conn} do
      {view, _html} = admin_view(conn)
      render_patch(view, @path <> "?tab=libraries")
      {:ok, profile} = Storage.Profiles.create_profile(%{name: name()})
      {:ok, set} = Storage.VariantSets.create_variant_set(%{name: name()})

      view |> element("#media-libraries button", "New library") |> render_click()

      assert has_element?(
               view,
               "#media-libraries-new select[name=profile] option[value='#{profile.uuid}']"
             )

      assert has_element?(
               view,
               "#media-libraries-new select[name=set] option[value='#{set.uuid}']"
             )
    end

    test "with more to choose from, the profile and variant set are chosen once", %{conn: conn} do
      {:ok, profile} =
        Storage.Profiles.create_profile(%{name: "Chosen #{System.unique_integer([:positive])}"})

      {:ok, set} =
        Storage.VariantSets.create_variant_set(%{
          name: "Set #{System.unique_integer([:positive])}"
        })

      {view, _html} = admin_view(conn)
      view |> element("#media-libraries button", "New library") |> render_click()
      assert has_element?(view, "#media-libraries-new select[name=profile]")
      assert has_element?(view, "#media-libraries-new select[name=set]")

      library_name = name()

      view
      |> form("#media-libraries-new", %{name: library_name, profile: profile.uuid, set: set.uuid})
      |> render_submit()

      library = Enum.find(Libraries.list_system_libraries(), &(&1.name == library_name))
      assert library.storage_profile_uuid == profile.uuid
      assert library.variant_set_uuid == set.uuid
    end
  end
end
