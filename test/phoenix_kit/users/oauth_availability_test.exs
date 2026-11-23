defmodule PhoenixKit.Users.OAuthAvailabilityTest do
  @moduledoc """
  `configured_providers_cached/0`, the display variant of
  `configured_providers/0`: primed and invalidated against a real `:settings`
  cache, no database. With no database `test_helper.exs` turns `:update_mode`
  on, so the uncached `configured_providers/0` computes `[]` — which is what
  the recompute-after-invalidation assertions rely on.

  `async: false` and a cache torn down per test: the cache is a globally named
  process, and a primed derived key visible to a concurrently running test
  would change that test's answer.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias PhoenixKit.Users.OAuthAvailability

  @derived_key "__derived__oauth_configured_providers"

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :settings})
    :ok
  end

  test "a primed cache answers without computing" do
    {_value, generation} = PhoenixKit.Cache.get_with_generation(:settings, @derived_key, nil)
    PhoenixKit.Cache.put(:settings, @derived_key, {generation, [:google]})

    assert OAuthAvailability.configured_providers_cached() == [:google]
  end

  test "a miss computes once and fills the cache" do
    assert OAuthAvailability.configured_providers_cached() == []
    # The fill is in the cache now: a second call reads it, not the database.
    {filled, _generation} = PhoenixKit.Cache.get_with_generation(:settings, @derived_key, :gone)
    assert {_, []} = filled
    assert OAuthAvailability.configured_providers_cached() == []
  end

  test "any settings write makes the derived entry stale (the generation rides it)" do
    PhoenixKit.Cache.put(:settings, @derived_key, {0, [:google, :github]})
    # Generation 0 is the fresh one here, so the entry reads as valid...
    assert OAuthAvailability.configured_providers_cached() == [:google, :github]

    # ...until ANY settings write bumps the cache generation: the stored
    # generation no longer matches, so the next read recomputes (here: []).
    PhoenixKit.Cache.invalidate(:settings, "oauth_google_client_id")

    assert OAuthAvailability.configured_providers_cached() == []
    {filled, generation} = PhoenixKit.Cache.get_with_generation(:settings, @derived_key, :gone)
    assert {^generation, []} = filled
  end

  test "with no cache process at all it still answers" do
    # The cache from setup is running; stop it to prove the fallback.
    stop_supervised(PhoenixKit.Cache.Registry)

    assert OAuthAvailability.configured_providers_cached() == []
  end
end
