defmodule PhoenixKitWeb.Live.Components.UserSettingsEtcherResetTest do
  @moduledoc """
  The "Annotation tools" section on /profile/settings: one button that
  puts Etcher back to how it ships.

  A user's annotation settings live in two places — the palette and ink
  the toolbar saves onto the user row, and Etcher's own how-you-work
  answers (dots, anchors, toolbar layout, per-tool colours) in the
  browser's localStorage. Clearing one without the other leaves someone
  half-fixed, so the reset does both: the row here, the browser through
  the pushed event the `EtcherReset` hook listens for.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer
  alias PhoenixKitWeb.Live.Components.UserSettings

  describe "resetting" do
    setup do
      {:ok, user} =
        Auth.register_user(%{
          email: "etcher-reset-#{System.unique_integer([:positive])}@example.com",
          password: "hello world!"
        })

      {:ok, user} =
        Auth.merge_user_custom_fields(user, %{
          "etcher_colors" => ["#123456", "#abcdef"],
          "etcher_line_params" => %{"width" => 9, "dash" => "dotted"},
          # Something of the user's that has nothing to do with drawing.
          "phone" => "555-0100"
        })

      %{user: user}
    end

    defp reset(user) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, user: user, myself: nil},
        private: %{live_temp: %{}}
      }

      UserSettings.handle_event("reset_etcher_settings", %{}, socket)
    end

    test "clears the saved palette and ink", %{user: user} do
      {:noreply, socket} = reset(user)

      fresh = Auth.get_user_by_email(user.email)
      refute Map.has_key?(fresh.custom_fields, "etcher_colors")
      refute Map.has_key?(fresh.custom_fields, "etcher_line_params")
      assert socket.assigns.etcher_reset_message =~ "reset"
    end

    test "leaves everything else on the user alone", %{user: user} do
      {:noreply, _} = reset(user)

      fresh = Auth.get_user_by_email(user.email)

      assert fresh.custom_fields["phone"] == "555-0100",
             "a reset of the drawing tools must not touch the rest of the profile"
    end

    test "tells the browser to clear its half too", %{user: user} do
      {:noreply, socket} = reset(user)

      pushed = get_in(socket.private, [:live_temp, :push_events]) || []

      assert Enum.any?(pushed, fn
               ["phoenix_kit:etcher-reset" | _] -> true
               _ -> false
             end),
             "without the push, the toolbar layout and per-tool colours survive in localStorage"
    end

    test "a user who never saved anything resets cleanly", %{user: user} do
      {:noreply, _} = reset(user)
      fresh = Auth.get_user_by_email(user.email)

      # Second time: the keys are already gone, so each delete is a no-op
      # write. A second reset must still read as done rather than erroring.
      {:noreply, socket} = reset(fresh)
      assert socket.assigns.etcher_reset_message =~ "reset"
    end
  end

  describe "the open-annotating switch" do
    setup do
      {:ok, user} =
        Auth.register_user(%{
          email: "open-annotating-#{System.unique_integer([:positive])}@example.com",
          password: "hello world!"
        })

      %{user: user}
    end

    defp toggle(user, current) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, user: user, myself: nil, viewer_open_annotating: current},
        private: %{live_temp: %{}}
      }

      UserSettings.handle_event("toggle_viewer_open_annotating", %{}, socket)
    end

    test "flips the per-user flag the viewer reads, and back", %{user: user} do
      refute MediaCanvasViewer.open_annotating?(user), "the shipped default is off"

      {:noreply, socket} = toggle(user, false)
      assert socket.assigns.viewer_open_annotating
      assert MediaCanvasViewer.open_annotating?(Auth.get_user_by_email(user.email))

      {:noreply, socket} = toggle(socket.assigns.user, true)
      refute socket.assigns.viewer_open_annotating
      refute MediaCanvasViewer.open_annotating?(Auth.get_user_by_email(user.email))
    end

    test "touches only its own key", %{user: user} do
      {:ok, user} = Auth.merge_user_custom_fields(user, %{"phone" => "555-0100"})

      {:noreply, _} = toggle(user, false)

      fresh = Auth.get_user_by_email(user.email)
      assert fresh.custom_fields["phone"] == "555-0100"
    end

    test "an annotation-tools reset leaves the switch alone", %{user: user} do
      # The switch is a viewing preference — how the viewer greets you —
      # not part of how the drawing tools are set up, so "reset annotation
      # settings" must not quietly flip someone back to the default open.
      {:noreply, _} = toggle(user, false)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, user: Auth.get_user_by_email(user.email), myself: nil},
        private: %{live_temp: %{}}
      }

      {:noreply, _} = UserSettings.handle_event("reset_etcher_settings", %{}, socket)

      assert MediaCanvasViewer.open_annotating?(Auth.get_user_by_email(user.email))
    end
  end

  describe "the invert-two-finger-pan switch" do
    setup do
      {:ok, user} =
        Auth.register_user(%{
          email: "invert-pan-#{System.unique_integer([:positive])}@example.com",
          password: "hello world!"
        })

      %{user: user}
    end

    defp toggle_pan(user, current) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          user: user,
          myself: nil,
          viewer_invert_two_finger_pan: current
        },
        private: %{live_temp: %{}}
      }

      UserSettings.handle_event("toggle_viewer_invert_two_finger_pan", %{}, socket)
    end

    test "flips the per-user flag the viewer reads, and back", %{user: user} do
      refute MediaCanvasViewer.invert_two_finger_pan?(user), "the shipped default is off"

      {:noreply, socket} = toggle_pan(user, false)
      assert socket.assigns.viewer_invert_two_finger_pan
      assert MediaCanvasViewer.invert_two_finger_pan?(Auth.get_user_by_email(user.email))

      {:noreply, socket} = toggle_pan(socket.assigns.user, true)
      refute socket.assigns.viewer_invert_two_finger_pan
      refute MediaCanvasViewer.invert_two_finger_pan?(Auth.get_user_by_email(user.email))
    end

    test "touches only its own key", %{user: user} do
      {:ok, user} =
        Auth.merge_user_custom_fields(user, %{MediaCanvasViewer.open_annotating_key() => true})

      {:noreply, _} = toggle_pan(user, false)

      assert MediaCanvasViewer.open_annotating?(Auth.get_user_by_email(user.email))
    end

    test "an annotation-tools reset leaves the switch alone", %{user: user} do
      {:noreply, _} = toggle_pan(user, false)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, user: Auth.get_user_by_email(user.email), myself: nil},
        private: %{live_temp: %{}}
      }

      {:noreply, _} = UserSettings.handle_event("reset_etcher_settings", %{}, socket)

      assert MediaCanvasViewer.invert_two_finger_pan?(Auth.get_user_by_email(user.email))
    end
  end
end

defmodule PhoenixKitWeb.Live.Components.UserSettingsEtcherSectionTest do
  @moduledoc "The DB-less half: the section is offered by default."

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Live.Components.UserSettings

  test "the annotation-tools section is in the default list" do
    assert :etcher in UserSettings.default_sections(),
           "/profile/settings renders the default list — a section missing from it is a " <>
             "section nobody can reach"
  end
end

defmodule PhoenixKitWeb.Components.ProfileSettingsTabsSectionsTest do
  @moduledoc "Every default section is on exactly one profile settings tab."

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.ProfileSettingsTabs
  alias PhoenixKitWeb.Live.Components.UserSettings

  test "no default section is left off the tabs, and none is on two" do
    on_tabs = ProfileSettingsTabs.all_sections()

    assert Enum.sort(on_tabs) == Enum.sort(UserSettings.default_sections()),
           "a section on no tab is one nobody can reach"

    assert on_tabs == Enum.uniq(on_tabs)
  end
end
