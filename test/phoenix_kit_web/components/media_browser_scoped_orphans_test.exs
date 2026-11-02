defmodule PhoenixKitWeb.Components.MediaBrowserScopedOrphansTest do
  @moduledoc """
  The orphan list is the library's (files no module references, in any folder),
  never a scope's. A scoped browser hides the orphan view and "Delete all
  orphaned", and its handlers read no scope, so a forged event listed — or
  queued for the trash — every orphan of the library. Both are refused there.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitWeb.Components.MediaBrowser

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, id: "mb"}, assigns)}

  test "a scoped browser refuses the orphan view and Delete all orphaned, untouched" do
    scope = Ecto.UUID.generate()

    for {event, assigns} <- [
          {"toggle_orphan_filter", %{scope_folder_id: scope, filter_orphaned: false}},
          {"delete_all_orphaned", %{scope_folder_id: scope}}
        ] do
      socket = socket(assigns)

      log =
        capture_log(fn ->
          assert {:noreply, ^socket} = MediaBrowser.handle_event(event, %{}, socket)
        end)

      assert log =~ "#{event} refused — orphans are not a scope's"
    end
  end

  test "a picker refuses Delete all orphaned like the other file writes" do
    assert "delete_all_orphaned" in MediaBrowser.picker_file_write_events()
  end
end
