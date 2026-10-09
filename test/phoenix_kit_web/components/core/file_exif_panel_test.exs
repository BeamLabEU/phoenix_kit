defmodule PhoenixKitWeb.Components.Core.FileExifPanelTest do
  @moduledoc """
  The EXIF panel: what a photo's recorded summary reads as (camera, exposure,
  dates, location), the three states (never read, read and empty, read), the
  buttons only where the host offers them, and the whole dump when it is open.

  DB-free: plain assigns.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitWeb.Components.Core.FileExifPanel

  @exif %{
    "camera" => %{
      "make" => "Apple",
      "model" => "iPhone 17 Pro",
      "lens_model" => "iPhone 17 Pro back triple camera 16.891mm f/2.8",
      "software" => "27.0"
    },
    "exposure" => %{
      "focal_length" => 16.9,
      "focal_length_35mm" => 200,
      "f_number" => 2.8,
      "exposure_time" => "1/176",
      "iso" => 50,
      "flash" => false
    },
    "dates" => %{
      "original" => "2026-10-05T18:42:46.907",
      "digitized" => "2026-10-05T18:42:46",
      "offset" => "+02:00"
    },
    "gps" => %{
      "latitude" => 45.469997,
      "longitude" => 10.720981,
      "altitude" => 105.0,
      "speed_kmh" => 0.9,
      "direction" => 352.8,
      "direction_ref" => "true",
      "timestamp" => "2026-10-05T16:42:46Z"
    }
  }

  defp render(assigns) do
    render_component(&FileExifPanel.file_exif_panel/1, Map.merge(%{id: "ex"}, assigns))
  end

  describe "a photo with EXIF" do
    setup do
      %{html: render(%{exif: @exif, latitude: 45.469997, longitude: 10.720981, can_read: true})}
    end

    test "the camera, exposure and dates read as a photographer reads them", %{html: html} do
      assert html =~ "Apple iPhone 17 Pro"
      assert html =~ "iPhone 17 Pro back triple camera 16.891mm f/2.8"
      assert html =~ "16.9 mm (200 mm equivalent)"
      assert html =~ "ƒ/2.8"
      assert html =~ "1/176 s"
      assert html =~ "Did not fire"
      assert html =~ "2026-10-05 18:42:46 (+02:00)"
    end

    test "the location, with a link to a map", %{html: html} do
      assert html =~ "45.469997°"
      assert html =~ "105 m"
      assert html =~ "352.8° true north"
      assert html =~ "0.9 km/h"
      assert html =~ "https://www.openstreetmap.org/?mlat=45.469997&amp;mlon=10.720981"
      assert html =~ ~s(rel="noopener noreferrer")
    end

    test "all of it, and reading again, are offered", %{html: html} do
      assert html =~ "All EXIF"
      assert html =~ "Read again"
      refute html =~ "Read EXIF"
    end
  end

  test "never read: says so, and offers to read" do
    html = render(%{exif: nil, can_read: true})

    assert html =~ "EXIF has not been read yet."
    assert html =~ ~s(phx-click="read_exif")
  end

  test "read and empty: says so, and has nothing to show" do
    html = render(%{exif: %{}, can_read: true})

    assert html =~ "This photo carries no EXIF."
    refute html =~ "All EXIF"
  end

  test "a host that does not let the reader write gets no button that records" do
    html = render(%{exif: nil, can_read: false})
    refute html =~ ~s(phx-click="read_exif")

    html = render(%{exif: @exif, can_read: false})
    refute html =~ ~s(phx-click="read_exif")
    assert html =~ ~s(phx-click="show_exif")
  end

  test "no position, no map link" do
    html = render(%{exif: Map.delete(@exif, "gps"), latitude: nil, longitude: nil})
    refute html =~ "openstreetmap"
    refute html =~ "Latitude"
  end

  test "the whole dump, grouped, while it is open" do
    html =
      render(%{
        exif: @exif,
        tags: %{
          "Make" => "Apple",
          "FNumber" => "1433/512",
          "GPSLatitude" => "45/1,28/1,1199/100",
          "GPSLatitudeRef" => "N",
          "ColorSpace" => "65535"
        }
      })

    assert html =~ "Hide all EXIF"
    assert html =~ "2.7988"
    assert html =~ "45.469997°"
    assert html =~ "Color Space"
    assert html =~ ~s(phx-click="hide_exif")
  end

  test "a failed read is said, not hidden" do
    assert render(%{exif: nil, status: :error}) =~ "Could not read the EXIF"
  end

  test "summary_groups/1 leaves out what the photo does not have" do
    assert FileExifPanel.summary_groups(nil) == []
    assert FileExifPanel.summary_groups(%{}) == []

    assert [{"Camera", [{"Camera", "Apple"}]}] =
             FileExifPanel.summary_groups(%{"camera" => %{"make" => "Apple"}})
  end
end
