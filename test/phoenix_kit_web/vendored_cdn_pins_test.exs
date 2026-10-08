defmodule PhoenixKitWeb.VendoredCdnPinsTest do
  @moduledoc """
  The viewer/editor libraries carry no hand-kept version pin any more.

  The bundles (Leaf, Fresco, Tessera, Etcher, SortableJS) used to be fetched
  from jsDelivr by a tag written into `phoenix_kit.js`, while their Elixir
  halves came from Hex — and nothing made the two agree but those strings.
  They drifted twice, silently (Leaf two minors behind, Etcher three). This
  test held each tag to the lock.

  Since the self-hosted libraries plan (Part B1) the host serves its own copy
  of the INSTALLED dependency, named from the consumer's loaded version
  (`PhoenixKit.Install.ViewerLibraries`), so that drift cannot occur. What is
  left to guard is that it cannot come back: no tag in the bundle, and the
  vendored names carry the version this project loaded.

  Superseded file names: `leaf_bundle_pin_test.exs` (removed with its pin).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.ViewerLibraries

  @bundle Path.join(__DIR__, "../../priv/static/assets/phoenix_kit.js")

  test "phoenix_kit.js names no CDN at all — every library it loads is vendored" do
    js = File.read!(@bundle)

    refute js =~ ~r|cdn\.jsdelivr\.net|,
           "a CDN URL in phoenix_kit.js is a hand-kept pin again (or a library that " <>
             "escaped the manifest) — PhoenixKit.Install.ViewerLibraries is the only source"
  end

  test "each Hex library's vendored name carries the version this project loaded" do
    root = Path.join(System.tmp_dir!(), "pk_pins_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    facts = ViewerLibraries.vendor!(root)

    for %{name: name, source: {app, _}, version: :app_vsn} <- ViewerLibraries.libraries() do
      vsn = to_string(Application.spec(app, :vsn))
      assert facts[name].file =~ ~r/\A#{name}-#{Regex.escape(vsn)}-[0-9a-f]{8}\.js\z/
    end
  end

  test "the lazy loaders still probe their globals, so a pre-import wins" do
    js = File.read!(@bundle)

    assert js =~ "window.LeafHooks && window.LeafHooks.Leaf"
    assert js =~ "window.Fresco && window.FrescoHooks && window.FrescoHooks.FrescoViewer"
    assert js =~ "window.TesseraHooks && window.TesseraHooks.TesseraLayer"
    assert js =~ "window.EtcherHooks && window.EtcherHooks.EtcherLayer"
  end
end
