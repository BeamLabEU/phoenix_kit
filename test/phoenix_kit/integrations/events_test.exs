defmodule PhoenixKit.Integrations.EventsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations.Events

  describe "subscribe/0 and broadcasts" do
    test "subscribe and receive setup_saved event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_setup_saved("google", %{"status" => "configured"})
      assert_receive {:integration_setup_saved, "google", %{"status" => "configured"}}
    end

    test "subscribe and receive connected event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_connected("google", %{"status" => "connected"})
      assert_receive {:integration_connected, "google", %{"status" => "connected"}}
    end

    test "subscribe and receive disconnected event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_disconnected("google")
      assert_receive {:integration_disconnected, "google"}
    end

    test "subscribe and receive validated event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_validated("google", :ok)
      assert_receive {:integration_validated, "google", :ok}
    end

    test "subscribe and receive validated error event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_validated("google", {:error, "timeout"})
      assert_receive {:integration_validated, "google", {:error, "timeout"}}
    end

    test "subscribe and receive connection_added event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_connection_added("google", "personal")
      assert_receive {:integration_connection_added, "google", "personal"}
    end

    test "subscribe and receive connection_removed event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_connection_removed("google", "personal")
      assert_receive {:integration_connection_removed, "google", "personal"}
    end

    test "subscribe and receive connection_renamed event" do
      :ok = Events.subscribe()
      :ok = Events.broadcast_connection_renamed("google", "personal", "work")
      assert_receive {:integration_connection_renamed, "google", "personal", "work"}
    end
  end
end
