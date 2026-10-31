defmodule PhoenixKit.Users.AvatarCropTest do
  @moduledoc """
  The geometry behind non-destructive avatar cropping.

  `layout/1` is mirrored by `avatarCropLayout` in
  `priv/static/assets/phoenix_kit_admin.js` (tested in
  `test/js/avatar_crop.test.cjs`) — several cases here pin the same numbers
  as the JS suite on purpose: the editor's preview must render exactly what
  the avatar component later renders, so the two implementations are held
  to the same answers.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.AvatarCrop

  defp near(actual, expected) do
    assert_in_delta actual, expected, 0.0001
  end

  describe "layout/1 — mirrored by the JS suite" do
    test "zoom 1 centered is exactly the cover fit" do
      l = AvatarCrop.layout(%{"x" => 0.5, "y" => 0.5, "zoom" => 1.0, "ar" => 1.5})
      near(l.width, 150.0)
      near(l.height, 100.0)
      near(l.left, -25.0)
      near(l.top, 0.0)
    end

    test "portrait mirrors landscape" do
      l = AvatarCrop.layout(%{"x" => 0.5, "y" => 0.5, "zoom" => 1.0, "ar" => 0.5})
      near(l.width, 100.0)
      near(l.height, 200.0)
      near(l.left, 0.0)
      near(l.top, -50.0)
    end

    test "zoom magnifies around the focal point" do
      l = AvatarCrop.layout(%{"x" => 0.5, "y" => 0.5, "zoom" => 2.0, "ar" => 1.0})
      near(l.width, 200.0)
      near(l.left, -50.0)
    end

    test "the frame never sees past an edge" do
      l = AvatarCrop.layout(%{"x" => 0.0, "y" => 0.0, "zoom" => 2.0, "ar" => 1.0})
      near(l.left, 0.0)
      near(l.top, 0.0)

      r = AvatarCrop.layout(%{"x" => 1.0, "y" => 1.0, "zoom" => 2.0, "ar" => 1.0})
      near(r.left, -100.0)
      near(r.top, -100.0)
    end
  end

  describe "normalize/1" do
    test "clamps rather than refuses — an overshoot is intent to reach the edge" do
      crop = AvatarCrop.normalize(%{"x" => 1.7, "y" => -2, "zoom" => 99, "ar" => 0})

      assert crop["x"] == 1.0
      assert crop["y"] == 0.0
      assert crop["zoom"] == 8.0
      assert_in_delta crop["ar"], 0.05, 0.0001
    end

    test "accepts the JS hook's numeric strings" do
      assert %{"x" => 0.25, "zoom" => 2.5} =
               AvatarCrop.normalize(%{
                 "x" => "0.25",
                 "y" => "0.5",
                 "zoom" => "2.5",
                 "ar" => "1.5"
               })
    end

    test "a zoom below cover fit is raised to it" do
      assert %{"zoom" => 1.0} =
               AvatarCrop.normalize(%{"x" => 0.5, "y" => 0.5, "zoom" => 0.2, "ar" => 1.0})
    end

    test "half a crop is no crop" do
      assert AvatarCrop.normalize(%{"x" => 0.5, "zoom" => 2}) == nil
      assert AvatarCrop.normalize(%{"x" => "wat", "y" => 0.5, "zoom" => 2, "ar" => 1}) == nil
      assert AvatarCrop.normalize("not a map") == nil
      assert AvatarCrop.normalize(nil) == nil
    end
  end

  describe "from_user/1" do
    test "reads the stored crop" do
      user = %{
        custom_fields: %{
          "avatar_crop" => %{"x" => 0.4, "y" => 0.3, "zoom" => 2, "ar" => 1.5}
        }
      }

      assert %{"x" => 0.4, "zoom" => 2.0} = AvatarCrop.from_user(user)
    end

    test "no key, a nil value, or junk all read as uncropped" do
      assert AvatarCrop.from_user(%{custom_fields: %{}}) == nil
      assert AvatarCrop.from_user(%{custom_fields: %{"avatar_crop" => nil}}) == nil
      assert AvatarCrop.from_user(%{custom_fields: %{"avatar_crop" => "junk"}}) == nil
      assert AvatarCrop.from_user(%{custom_fields: nil}) == nil
      assert AvatarCrop.from_user(nil) == nil
    end
  end

  describe "variant_for/3" do
    test "uncropped sizes match the ladder" do
      # 32px box at 2x needs 64px: small. 160px box needs 320px: medium.
      assert AvatarCrop.variant_for(32) == "small"
      assert AvatarCrop.variant_for(160) == "medium"
    end

    test "zoom buys resolution from the next variant up" do
      # A 3x zoom shows a third of the source, so the 160px settings preview
      # needs 960px of source — past medium (800), into large.
      assert AvatarCrop.variant_for(160, 3.0) == "large"
    end

    test "a landscape image needs its width to cover for its short side" do
      # Variants scale by width, but the frame is covered by the short
      # side. A 2:1 landscape at the settings size needs 320·2 = 640px of
      # WIDTH before its 320px-tall short side suffices — and at zoom 2
      # that doubles again, past medium.
      assert AvatarCrop.variant_for(160, 1.0, 2.0) == "medium"
      assert AvatarCrop.variant_for(160, 2.0, 2.0) == "large"
      # Portrait width IS the short side; no penalty.
      assert AvatarCrop.variant_for(160, 1.0, 0.5) == "medium"
    end

    test "capped at large — never the unbounded original" do
      assert AvatarCrop.variant_for(160, 8.0) == "large"
      assert AvatarCrop.variant_for(160, 8.0, 4.0) == "large"
    end
  end

  describe "drop_identity/1" do
    test "centered at cover fit is no crop at all" do
      assert AvatarCrop.drop_identity(%{"x" => 0.5, "y" => 0.5, "zoom" => 1.0, "ar" => 1.5}) ==
               nil

      # Float noise from a drag still counts as untouched.
      assert AvatarCrop.drop_identity(%{
               "x" => 0.5004,
               "y" => 0.4997,
               "zoom" => 1.0009,
               "ar" => 1.5
             }) == nil
    end

    test "any real adjustment survives" do
      crop = %{"x" => 0.5, "y" => 0.5, "zoom" => 2.0, "ar" => 1.5}
      assert AvatarCrop.drop_identity(crop) == crop

      panned = %{"x" => 0.3, "y" => 0.5, "zoom" => 1.0, "ar" => 2.0}
      assert AvatarCrop.drop_identity(panned) == panned
    end

    test "nil passes through" do
      assert AvatarCrop.drop_identity(nil) == nil
    end
  end

  describe "img_style/1" do
    test "emits the geometry and undoes Tailwind's img max-width" do
      style = AvatarCrop.img_style(%{"x" => 0.5, "y" => 0.5, "zoom" => 2.0, "ar" => 1.0})

      assert style =~ "position:absolute"
      assert style =~ "max-width:none"
      assert style =~ "width:200.00%"
      assert style =~ "left:-50.00%"
    end
  end
end
