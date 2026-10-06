defmodule PhoenixKit.SettingsSubscribeTest do
  @moduledoc """
  `PhoenixKit.Settings.subscribe/0` — live notification of settings changes.

  A host page that changed a setting used to have to invent its own PubSub
  message so other open pages noticed. The kit had an events module with a
  subscribe and a broadcast, and nothing ever called the broadcast.

  What is pinned here is the contract a subscriber relies on:

    * a committed write that changed a value is announced, with the value;
    * a write that changed nothing is announced to nobody;
    * a secret is announced as changed, its value never sent;
    * a delete is announced;
    * when the message arrives, the local cache already holds the new value —
      invalidation used to be a cast, so a subscriber that reacted by reading
      the setting could get the old one back.

  Runs against a REAL settings cache process, since the stale-read race only
  exists when there is a cache to be stale.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Events
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting

  @cache :settings

  setup do
    original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "settings-subscribe-test-secret")

    on_exit(fn ->
      case original_flat do
        nil -> Application.delete_env(:phoenix_kit, :secret_key_base)
        value -> Application.put_env(:phoenix_kit, :secret_key_base, value)
      end
    end)

    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: @cache})

    :ok = Settings.subscribe()
    :ok
  end

  defp key, do: "subscribe_test_#{System.unique_integer([:positive])}"

  describe "single writes" do
    test "a change is announced with the committed value" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "blue")

      assert_receive {:setting_changed, ^key, "blue"}
    end

    test "a write that changes nothing is announced to nobody" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "same")
      assert_receive {:setting_changed, ^key, "same"}

      {:ok, _} = Settings.update_setting(key, "same")
      refute_receive {:setting_changed, ^key, _}, 100
    end

    test "a JSON setting is announced with its document" do
      key = key()
      {:ok, _} = Settings.update_json_setting(key, %{"mode" => "dark"})

      assert_receive {:setting_changed, ^key, %{"mode" => "dark"}}
    end

    test "the cache already holds the new value when the message arrives" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "old")
      assert_receive {:setting_changed, ^key, "old"}

      # Warm the cache with the old value, exactly as a page would have.
      assert Settings.get_setting_cached(key, "default") == "old"

      {:ok, _} = Settings.update_setting(key, "new")
      assert_receive {:setting_changed, ^key, "new"}

      assert Settings.get_setting_cached(key, "default") == "new",
             "a subscriber re-reading on the event must not get the value from before it"
    end

    test "a reader that missed before a write cannot put the old value back" do
      # The reader misses, reads the old row, and is held (by a telemetry
      # handler on its own query) until the write has committed and the cache
      # has dropped the key. Its fill then arrives after the invalidation; an
      # unconditional put would re-cache the value that was just replaced, for
      # a full TTL.
      key = key()
      {:ok, _} = Settings.update_setting(key, "old")
      assert_receive {:setting_changed, ^key, "old"}
      test_pid = self()
      handler = "hold-reader-#{key}"

      :telemetry.attach(
        handler,
        [:phoenix_kit, :test, :repo, :query],
        fn _event, _measurements, %{source: "phoenix_kit_settings", params: params}, _ ->
          if key in params and Process.get(:hold_after_read) do
            Process.delete(:hold_after_read)
            send(test_pid, {:reader_read, self()})

            receive do
              :continue -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      reader =
        Task.async(fn ->
          Process.put(:hold_after_read, true)
          Settings.get_setting_cached(key)
        end)

      assert_receive {:reader_read, reader_pid}, 2_000
      {:ok, _} = Settings.update_setting(key, "new")
      assert_receive {:setting_changed, ^key, "new"}
      send(reader_pid, :continue)

      assert Task.await(reader) == "old", "the reader read before the write"
      cache = GenServer.whereis({:via, Registry, {PhoenixKit.Cache.Registry, @cache}})
      _ = :sys.get_state(cache)

      assert Settings.get_setting_cached(key) == "new"
    end

    test "a failed announcement is logged and the next one still goes out" do
      # The write has committed by now; a notification that raises (here the
      # feed publish, handed something that is not an entry) must neither
      # surface as an error nor swallow the settings broadcast after it.
      key = key()
      setting = %Setting{key: key, value: "committed"}

      log =
        capture_log(fn ->
          assert :ok = Queries.announce_committed([{setting, :not_an_entry}])
        end)

      assert_receive {:setting_changed, ^key, "committed"}
      assert log =~ "Settings change not announced"
    end

    test "nothing is announced until the cache has dropped the old value" do
      # The race above only shows when the cache process is busy — an idle one
      # drains a cast before any test can observe the window. Suspending it
      # makes the ordering observable: while the cache cannot act, the change
      # must not be announced, because a subscriber would read the stale value.
      key = key()
      {:ok, _} = Settings.update_setting(key, "before")
      assert_receive {:setting_changed, ^key, "before"}

      cache = GenServer.whereis({:via, Registry, {PhoenixKit.Cache.Registry, @cache}})
      assert is_pid(cache)
      :ok = :sys.suspend(cache)

      writer = Task.async(fn -> Settings.update_setting(key, "after") end)

      refute_receive {:setting_changed, ^key, _},
                     200,
                     "announced while the cache still held the old value"

      :ok = :sys.resume(cache)
      assert {:ok, _} = Task.await(writer)
      assert_receive {:setting_changed, ^key, "after"}
    end
  end

  # `history: false` (a machine stamp) leaves the settings history out and
  # nothing else: the cache and the change event behave as for any write.
  describe "a write without history" do
    test "drops the cached value and is announced with the committed value" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "old", history: false)
      assert_receive {:setting_changed, ^key, "old"}
      assert Settings.get_setting_cached(key, "default") == "old"

      {:ok, _} = Settings.update_setting(key, "new", history: false)
      assert_receive {:setting_changed, ^key, "new"}
      assert Settings.get_setting_cached(key, "default") == "new"
    end

    test "that changes nothing is announced to nobody" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "same", history: false)
      assert_receive {:setting_changed, ^key, "same"}

      {:ok, _} = Settings.update_setting(key, "same", history: false)
      refute_receive {:setting_changed, ^key, _}, 100
    end

    test "through the batch and JSON writers is announced too" do
      a = key()
      b = key()

      {:ok, _} = Settings.update_settings_batch(%{a => "1"}, history: false)
      {:ok, _} = Settings.update_json_setting(b, %{"n" => 1}, history: false)

      assert_receive {:setting_changed, ^a, "1"}
      assert_receive {:setting_changed, ^b, %{"n" => 1}}
    end
  end

  describe "secrets" do
    test "a restricted key is announced without its value" do
      {:ok, _} = Settings.update_setting("oauth_google_client_secret", "s3cr3t-value")

      assert_receive {:setting_changed, "oauth_google_client_secret", :redacted}
      refute_received {:setting_changed, "oauth_google_client_secret", "s3cr3t-value"}
    end

    test "an integration row is announced without its body, whatever its key" do
      key = Ecto.UUID.generate()

      {:ok, _} =
        Settings.update_json_setting_with_module(
          key,
          %{"access_token" => "tok-live", "status" => "connected"},
          "integrations"
        )

      assert_receive {:setting_changed, ^key, :redacted}
      refute_received {:setting_changed, ^key, %{}}
    end

    test "a module's secret is recognised by its name" do
      assert Events.secret_key?("billing_acme_webhook_secret")
      assert Events.secret_key?("mymodule_api_key")
      assert Events.secret_key?("integration:openai:default")
      assert Events.secret_key?(Ecto.UUID.generate(), "integrations")
      refute Events.secret_key?("project_title")
      refute Events.secret_key?("time_zone")
    end

    test "a broadcast of a secret withholds the value whatever the caller passed" do
      Events.broadcast_setting_changed("mymodule_api_key", "sk-live-123")

      assert_receive {:setting_changed, "mymodule_api_key", :redacted}
    end
  end

  describe "batch and delete" do
    test "a batch announces each changed key, and only those" do
      unchanged = key()
      changed = key()
      {:ok, _} = Settings.update_setting(unchanged, "keep")
      assert_receive {:setting_changed, ^unchanged, "keep"}

      {:ok, _} = Settings.update_settings_batch(%{unchanged => "keep", changed => "fresh"})

      assert_receive {:setting_changed, ^changed, "fresh"}
      refute_receive {:setting_changed, ^unchanged, _}, 100
    end

    test "a delete is announced, and the cache no longer holds the value" do
      key = key()
      {:ok, _} = Settings.update_setting(key, "doomed")
      assert_receive {:setting_changed, ^key, "doomed"}
      assert Settings.get_setting_cached(key, "default") == "doomed"

      {:ok, _} = Settings.delete_setting(key)

      assert_receive {:setting_deleted, ^key}
      assert Settings.get_setting_cached(key, "default") == "default"
    end
  end
end
