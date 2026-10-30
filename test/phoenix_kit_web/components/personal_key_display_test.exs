defmodule PhoenixKitWeb.Components.PersonalKeyDisplayTest do
  @moduledoc """
  The statuses of personal keys on Settings -> API: the owners' rights are read once and may
  be kept, each key's status always comes from the key list given, and a key with no status
  still renders.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Keys.Key
  alias PhoenixKitWeb.Components.PersonalKeyDisplay

  defp key(owner, extra \\ []) do
    struct!(
      Key,
      [uuid: "k-#{System.unique_integer([:positive])}", user_uuid: owner, personal: true] ++
        extra
    )
  end

  test "owners already known are not read again" do
    # `Keys.active_owner/1` would hit the database for this owner; the known state answers.
    keys = [key("owner-a"), key("owner-a")]

    assert PersonalKeyDisplay.owner_states(keys, %{"owner-a" => :personal_keys_not_allowed}) ==
             %{"owner-a" => :personal_keys_not_allowed}
  end

  test "owners without a live personal key are left out" do
    ended = key("owner-b", revoked_at: DateTime.add(DateTime.utc_now(), -60))
    plain = key("owner-c", personal: false)

    assert PersonalKeyDisplay.owner_states([ended, plain], %{"owner-b" => :ok}) == %{}
  end

  test "each key's status comes from the list, with the owners' states given" do
    live = key("owner-a")
    revoked = key("owner-a", revoked_at: DateTime.add(DateTime.utc_now(), -60))
    suspended = key("owner-d")

    statuses =
      PersonalKeyDisplay.statuses(
        [live, revoked, suspended],
        %{"owner-a" => :ok, "owner-d" => :personal_keys_not_allowed}
      )

    assert statuses[live.uuid] == :active
    assert statuses[revoked.uuid] == :revoked
    assert statuses[suspended.uuid] == :no_permission
  end

  test "a missing status renders as a pending badge instead of raising" do
    assert PersonalKeyDisplay.badge_name(nil) == "pending"
    assert PersonalKeyDisplay.label(nil) == nil
  end
end
