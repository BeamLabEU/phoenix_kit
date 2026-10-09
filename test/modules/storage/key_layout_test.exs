defmodule PhoenixKit.Modules.Storage.KeyLayoutTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.KeyLayout

  doctest PhoenixKit.Modules.Storage.KeyLayout

  @md5 "22e8b90781bab72967f9d5410b4299f9"

  test "a file's folder gains one two-character hash folder per level" do
    assert KeyLayout.path("01", @md5, 0) == "01/#{@md5}"
    assert KeyLayout.path("01", @md5, 1) == "01/22/#{@md5}"
    assert KeyLayout.path("01", @md5, 2) == "01/22/e8/#{@md5}"
    assert KeyLayout.path("lib-1a2b3c", @md5, 3) == "lib-1a2b3c/22/e8/b9/#{@md5}"
  end

  test "a layout that is not one falls back to the one in use" do
    assert KeyLayout.path("01", @md5, 9) == KeyLayout.path("01", @md5, KeyLayout.default())
  end

  test "each level divides the busiest folder by 256" do
    assert KeyLayout.per_folder(10_000_000, 0) == 10_000_000
    assert KeyLayout.per_folder(10_000_000, 1) == 39_063
    assert KeyLayout.per_folder(10_000_000, 2) == 153
    assert KeyLayout.per_folder(0, 1) == 0
  end

  test "ratings follow the thresholds" do
    assert KeyLayout.rating(5_000) == :comfortable
    assert KeyLayout.rating(5_001) == :slow
    assert KeyLayout.rating(50_000) == :slow
    assert KeyLayout.rating(50_001) == :too_many
  end

  test "the table covers every library size, and the default layout suits a million files" do
    assert Enum.map(KeyLayout.table(1), &elem(&1, 0)) == KeyLayout.sizes()
    assert {1_000_000, 3_907, :comfortable} in KeyLayout.table(1)
    assert {100_000_000, 390_625, :too_many} in KeyLayout.table(1)
    assert {100_000_000, 1_526, :comfortable} in KeyLayout.table(2)
  end

  test "comfortable_up_to grows 256-fold per level" do
    assert KeyLayout.comfortable_up_to(0) == 5_000
    assert KeyLayout.comfortable_up_to(1) == 1_280_000
  end
end
