defmodule PhoenixKit.Modules.Storage.ShapeTest do
  @moduledoc """
  The wide/tall thresholds, DB-free: how a ratio, a size pair or a file reads.
  The filter against a real column is covered in
  `test/integration/storage/shape_filter_test.exs`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Shape

  test "2:1 and wider is wide; 1:2 and taller is tall; the rest is normal" do
    assert Shape.classify(2.0) == :wide
    assert Shape.classify(8947 / 3317) == :wide
    assert Shape.classify(16 / 9) == :normal
    assert Shape.classify(1.0) == :normal
    assert Shape.classify(3 / 4) == :normal
    assert Shape.classify(0.5) == :tall
    assert Shape.classify(0.25) == :tall
  end

  test "a phone screenshot is tall" do
    assert Shape.classify({1170, 2532}) == :tall
  end

  test "a size pair or a file reads like its ratio" do
    assert Shape.classify({4200, 2000}) == :wide
    assert Shape.classify(%{width: 3000, height: 2000}) == :normal
    assert Shape.classify(%{aspect_ratio: 4.0, width: 1, height: 1}) == :wide
  end

  test "no usable size is no shape" do
    assert Shape.classify(nil) == nil
    assert Shape.classify({nil, nil}) == nil
    assert Shape.classify({0, 500}) == nil
    assert Shape.classify(%{width: nil, height: nil}) == nil
  end

  test "the thresholds are the documented ones" do
    assert Shape.wide_min() == 2.0
    assert Shape.tall_max() == 0.5
  end
end
