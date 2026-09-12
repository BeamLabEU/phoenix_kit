defmodule PhoenixKitWeb.VendoredCdnPinsTest do
  @moduledoc """
  Every sibling-library JS bundle pinned in `phoenix_kit.js` names the
  release hex resolved.

  The bundles (leaf, fresco, tessera, etcher) are fetched from jsDelivr by
  GitHub tag while their Elixir halves come from hex — and nothing makes the
  two agree except the strings in `phoenix_kit.js`. They drift, and the
  drift is silent by construction: almost everything these libraries add is
  a server<->client contract, so a stale bundle renders identically and
  just stops implementing what the server now expects.

  It has happened twice. Leaf's pin sat two minors behind (v0.3.2 serving
  while hex resolved 0.5.1 — no `{:leaf_flushed, ...}` reply, no dirty
  re-baseline), which is when the leaf-only version of this test was
  written. Then etcher's pin was found THREE minors behind (v0.9.0 serving
  while hex resolved 0.12.0 — none of the selection, snapping, keyboard or
  clipboard work reaching any host), because the test covered only leaf.
  Generalized to every `gh/` pin in the file, with the version resolved
  from the lock, so the next sibling added here is covered the moment its
  pin appears.

  Superseded file name: `leaf_bundle_pin_test.exs`.
  """
  use ExUnit.Case, async: true

  @bundle Path.join(__DIR__, "../../priv/static/assets/phoenix_kit.js")

  # app → the path fragment its pin carries. Kept explicit rather than
  # derived so a typo'd pin (wrong repo, wrong path) fails here instead of
  # 404ing in production.
  # Pattern SOURCES, not compiled regexes: a compiled Regex holds a
  # reference and cannot be injected from a module attribute into a
  # function body.
  @pinned %{
    leaf: "cdn\\.jsdelivr\\.net\/gh\/alexdont\/leaf@([^\/]+)\/priv\/static\/assets\/leaf\\.js",
    fresco: "cdn\\.jsdelivr\\.net\/gh\/alexdont\/fresco@([^\/]+)\/priv\/static\/fresco\\.js",
    tessera: "cdn\\.jsdelivr\\.net\/gh\/alexdont\/tessera@([^\/]+)\/priv\/static\/tessera\\.js",
    etcher: "cdn\\.jsdelivr\\.net\/gh\/alexdont\/etcher@([^\/]+)\/priv\/static\/etcher\\.js"
  }

  defp source, do: File.read!(@bundle)

  defp pins_for(app) do
    @pinned
    |> Map.fetch!(app)
    |> Regex.compile!()
    |> Regex.scan(source())
    |> Enum.map(fn [_, tag] -> tag end)
  end

  for {app, _} <- @pinned do
    test "the #{app} CDN tag names the release hex resolved" do
      app = unquote(app)
      resolved = to_string(Application.spec(app, :vsn))

      assert [tag] = pins_for(app),
             "expected exactly one #{app} CDN pin, found #{inspect(pins_for(app))}"

      assert tag == "v#{resolved}",
             """
             The #{app} bundle is pinned to #{tag}, but this project resolves \
             #{app} #{resolved}.

             Update the pin in priv/static/assets/phoenix_kit.js to \
             v#{resolved} (and make sure that tag is pushed — jsDelivr \
             resolves gh/<user>/<repo>@<tag>). A mismatch is silent: the \
             bundle renders normally and quietly stops honouring the parts \
             of the API the server has moved on to.
             """
    end
  end

  for {app, _} <- @pinned do
    test "the #{app} requirement's ceiling stops at the pinned minor" do
      # The other half of the pin discipline, sibling to leaf_bundle_pin's
      # ceiling test: `~> 0.N` without a patch segment reads as "the 0.N
      # line" but means `< 1.0.0`, so one patch-less alternative silently
      # admits every later 0.x — and a host is then free to resolve the
      # Elixir half past the tag this file's other tests hold the bundle
      # to. Neither the tag test above nor the lock can see that: both only
      # look at versions THIS project resolved.
      app = unquote(app)

      requirement =
        File.read!(Path.join(__DIR__, "../../mix.exs"))
        |> then(&Regex.run(~r/\{:#{app}, "([^"]+)"/, &1))
        |> then(fn [_, req] -> req end)

      resolved = to_string(Application.spec(app, :vsn))

      assert Version.match?(resolved, requirement),
             "#{app} #{resolved} no longer satisfies its own requirement #{inspect(requirement)}"

      %Version{major: major, minor: minor} = Version.parse!(resolved)
      next_minor = "#{major}.#{minor + 1}.0"

      refute Version.match?(next_minor, requirement),
             """
             The #{app} requirement #{inspect(requirement)} admits \
             #{next_minor}, one minor past the bundle tag this file pins. \
             Give every alternative a patch segment (`~> #{major}.#{minor}.0`, \
             not `~> #{major}.#{minor}`) so the ceiling stops at the pinned \
             minor, and move the requirement, the lock and the CDN pin \
             together.
             """
    end
  end

  test "every gh/ pin in the bundle is covered by this test" do
    # A fifth sibling added with a pin this file doesn't know about would
    # re-open the exact hole this test exists to close.
    all_gh_pins =
      ~r|cdn\.jsdelivr\.net/gh/([^@/]+/[^@/]+)@|
      |> Regex.scan(source())
      |> Enum.map(fn [_, repo] -> repo end)
      |> Enum.sort()

    covered =
      @pinned
      |> Map.keys()
      |> Enum.map(&"alexdont/#{&1}")
      |> Enum.sort()

    assert all_gh_pins == covered,
           "gh/ pins in phoenix_kit.js and the pins this test covers have " <>
             "drifted apart: #{inspect(all_gh_pins -- covered)} uncovered, " <>
             "#{inspect(covered -- all_gh_pins)} no longer present"
  end

  test "the lazy loaders still probe their globals" do
    # Each loader short-circuits when the host pre-imported the bundle;
    # these probes are what make the pins load-bearing at all.
    js = source()

    assert js =~ "window.LeafHooks && window.LeafHooks.Leaf"
    assert js =~ "window.Fresco"
    assert js =~ "window.Tessera"
    assert js =~ "window.Etcher"
  end
end
