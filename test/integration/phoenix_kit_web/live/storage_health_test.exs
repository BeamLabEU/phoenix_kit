defmodule PhoenixKitWeb.Live.StorageHealthTest do
  @moduledoc """
  The Health tab of Settings → Media (V205): it counts the files that are where, and
  what, their library's storage wants, lists the ones waiting for the
  reconciler with what they wait for, and offers to queue a pass.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Profiles}
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/media?tab=health")

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp stale_file!(user) do
    n = System.unique_integer([:positive])
    {:ok, library} = Libraries.create_system_library(%{name: "Health #{n}"})
    {:ok, profile} = Profiles.create_profile(%{name: "Health #{n}"})

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "waiting-#{n}.txt",
        file_name: "w.txt",
        file_path: "w",
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid,
        library_uuid: library.uuid
      })

    # Its library moves to another profile: its copies are out of date.
    {:ok, _} = Profiles.set_library_profile(library, profile.uuid)
    {file, library}
  end

  test "lists a file waiting for the reconciler, with its library", %{conn: conn, user: user} do
    {file, library} = stale_file!(user)

    {:ok, view, html} = live(conn, @path)

    assert html =~ file.original_file_name
    assert html =~ library.name
    assert has_element?(view, "#media-health-reconcile")

    view |> element("#media-health-reconcile") |> render_click()
    assert render(view) =~ "reconciler"
  end
end
