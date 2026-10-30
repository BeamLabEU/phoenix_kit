defmodule PhoenixKit.API.PersonalKeysConfigTest do
  @moduledoc """
  `PhoenixKit.API.PersonalKeysConfig`: the two settings of personal API keys, read with
  defaults and clamps, and validated and written as one form.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.Settings

  setup do
    KeyTestSupport.start_cache_registry!()
  end

  defp put(key, value), do: KeyTestSupport.put_setting(key, value)

  test "the defaults" do
    assert PersonalKeysConfig.max_days() == 90
    assert PersonalKeysConfig.max_count() == 5
  end

  test "stored values are read" do
    put("api_personal_key_max_days", "30")
    put("api_personal_key_max_count", "2")

    assert PersonalKeysConfig.max_days() == 30
    assert PersonalKeysConfig.max_count() == 2
  end

  test "a value above the maximum reads as the maximum, an unusable one as the default" do
    put("api_personal_key_max_days", "1000")
    put("api_personal_key_max_count", "abc")
    assert PersonalKeysConfig.max_days() == 365
    assert PersonalKeysConfig.max_count() == 5

    put("api_personal_key_max_count", "51")
    put("api_personal_key_max_days", "0")
    assert PersonalKeysConfig.max_count() == 50
    assert PersonalKeysConfig.max_days() == 90
  end

  test "the latest expiry is the end of the UTC day max_days from today" do
    put("api_personal_key_max_days", "10")

    assert PersonalKeysConfig.latest_expiry() ==
             DateTime.new!(Date.add(Date.utc_today(), 10), ~T[23:59:59], "Etc/UTC")
  end

  test "the form has two fields and shows the current values" do
    assert Enum.map(PersonalKeysConfig.fields(), & &1.field) == ["max_days", "max_count"]
    assert PersonalKeysConfig.current() == %{"max_days" => "90", "max_count" => "5"}
  end

  describe "validate/1" do
    test "accepts whole numbers inside their ranges, at both ends" do
      assert {:ok, pairs} = PersonalKeysConfig.validate(%{"max_days" => "1", "max_count" => "50"})

      assert Enum.sort(pairs) == [
               {"api_personal_key_max_count", 50},
               {"api_personal_key_max_days", 1}
             ]

      assert {:ok, _} = PersonalKeysConfig.validate(%{"max_days" => "365", "max_count" => "1"})
    end

    test "names every field outside its range, missing or not a number" do
      assert {:error, ["max_days", "max_count"]} =
               PersonalKeysConfig.validate(%{"max_days" => "366", "max_count" => "0"})

      assert {:error, ["max_count"]} = PersonalKeysConfig.validate(%{"max_days" => "5"})

      assert {:error, ["max_days"]} =
               PersonalKeysConfig.validate(%{"max_days" => "1.5", "max_count" => "3"})

      assert {:error, ["max_days", "max_count"]} = PersonalKeysConfig.validate(:nope)
    end
  end

  describe "save/2" do
    test "writes only what changed, and nothing when one field is bad" do
      assert {:error, ["max_count"]} =
               PersonalKeysConfig.save(%{"max_days" => "30", "max_count" => "99"}, [])

      assert PersonalKeysConfig.max_days() == 90

      KeyTestSupport.write_setting(fn ->
        assert {:ok, ["api_personal_key_max_days"]} =
                 PersonalKeysConfig.save(%{"max_days" => "30", "max_count" => "5"}, [])

        {:ok, :done}
      end)

      assert PersonalKeysConfig.max_days() == 30
      assert Settings.get_setting("api_personal_key_max_count") in [nil, ""]
    end
  end
end
