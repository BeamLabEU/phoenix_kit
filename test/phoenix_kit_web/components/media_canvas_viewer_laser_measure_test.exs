defmodule PhoenixKitWeb.Components.MediaCanvasViewerLaserMeasureTest do
  @moduledoc """
  Etcher's laser measure (`:measure`) is offered only when the host sets
  `config :phoenix_kit, laser_measure: true`, and only to annotators.

  `async: false`: the switch is application env, global to the VM. Flipped
  in an async module it would reach every viewer rendered concurrently in
  other files.
  """
  use ExUnit.Case, async: false

  import PhoenixKitWeb.MediaCanvasViewerFixtures

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  describe "the laser measure" do
    # A host turns it on; it reads a Bosch meter over Web Bluetooth, which
    # means nothing to a site whose people do not own one.
    setup do
      previous = Application.fetch_env(:phoenix_kit, :laser_measure)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, :laser_measure, value)
          :error -> Application.delete_env(:phoenix_kit, :laser_measure)
        end
      end)
    end

    test "off unless the host turns it on" do
      Application.delete_env(:phoenix_kit, :laser_measure)
      html = render_html(%{burn_canvas: nil, burn_version: nil})
      refute html =~ ~s(&quot;measure&quot;)
    end

    test "turned on, an annotator is offered it: a meter's readings become labels" do
      Application.put_env(:phoenix_kit, :laser_measure, true)
      html = render_html(%{burn_canvas: nil, burn_version: nil})
      assert html =~ ~s(&quot;measure&quot;)
    end

    test "turned on, a read-only viewer still is not — nothing for a reading to label" do
      Application.put_env(:phoenix_kit, :laser_measure, true)
      html = render_html(%{burn_canvas: nil, burn_version: nil, can_annotate: false})
      refute html =~ ~s(&quot;measure&quot;)
    end
  end

  describe "laser_measure_tools/0" do
    setup do
      previous = Application.fetch_env(:phoenix_kit, :laser_measure)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, :laser_measure, value)
          :error -> Application.delete_env(:phoenix_kit, :laser_measure)
        end
      end)
    end

    test "only a literal true turns it on" do
      for value <- [false, nil, "true", 1, :yes] do
        Application.put_env(:phoenix_kit, :laser_measure, value)
        assert MediaCanvasViewer.laser_measure_tools() == [], inspect(value)
      end

      Application.put_env(:phoenix_kit, :laser_measure, true)
      assert MediaCanvasViewer.laser_measure_tools() == [:measure]
    end
  end
end
