defmodule PhoenixKitWeb.Live.Modules.Storage.WatermarkUiTest do
  @moduledoc """
  The Watermark card of a rendition profile (Settings → Media → Rendition
  profiles): it shows the strip's or the corner's fields as chosen, saves a valid
  watermark (bumping the profile's revision), and shows the error of an invalid one
  without saving.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    {:ok, set} = VariantSets.create_variant_set(%{name: "Shop #{System.unique_integer()}"})

    {:ok, _} =
      Storage.create_dimension(
        %{name: "wm_ui", width: 300, quality: 85, applies_to: "image"},
        set.uuid
      )

    path = Routes.path("/admin/settings/media?tab=renditions&set=#{set.uuid}")
    %{conn: log_in_user(conn, user), set: set, path: path}
  end

  defp form_id(set), do: "#media-renditions-watermark-form-#{set.uuid}"

  test "the card follows the chosen style and saves the watermark", ctx do
    {:ok, view, html} = live(ctx.conn, ctx.path)
    assert html =~ "Watermark"
    assert html =~ "wm_ui"
    assert has_element?(view, "#{form_id(ctx.set)} [name='watermark[strip_position]']")

    html =
      view
      |> form(form_id(ctx.set), watermark: %{mode: "corner"})
      |> render_change()

    assert html =~ "watermark[corner]"
    refute html =~ "watermark[strip_position]"

    revision = VariantSets.get_variant_set(ctx.set.uuid).revision

    view
    |> form(form_id(ctx.set),
      watermark: %{
        enabled: "true",
        mode: "corner",
        text: "{site_url}",
        corner: "top_left",
        dimensions: ["wm_ui"]
      }
    )
    |> render_submit()

    set = VariantSets.get_variant_set(ctx.set.uuid)
    assert set.watermark.enabled
    assert set.watermark.mode == "corner"
    assert set.watermark.corner == "top_left"
    assert set.watermark.dimensions == ["wm_ui"]
    assert set.revision > revision
  end

  test "an invalid watermark shows its error and is not saved", ctx do
    {:ok, view, _html} = live(ctx.conn, ctx.path)

    html =
      view
      |> form(form_id(ctx.set),
        watermark: %{enabled: "true", text: "", logo_file_uuid: "", dimensions: ["wm_ui"]}
      )
      |> render_submit()

    assert html =~ "give a text or a logo"
    assert VariantSets.get_variant_set(ctx.set.uuid).watermark == nil
  end
end
