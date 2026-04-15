defmodule PhoenixKit.Modules.Maintenance.PubSubTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Maintenance

  describe "pubsub_topic/0" do
    test "returns the expected topic string" do
      assert Maintenance.pubsub_topic() == "phoenix_kit:maintenance"
    end
  end

  describe "subscribe/0 and broadcast_status_change/0" do
    test "subscriber receives maintenance_status_changed events" do
      :ok = Maintenance.subscribe()
      :ok = Maintenance.broadcast_status_change()
      assert_receive {:maintenance_status_changed, %{active: _}}
    end
  end
end
