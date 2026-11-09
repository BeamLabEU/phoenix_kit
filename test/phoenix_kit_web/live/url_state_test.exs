defmodule PhoenixKitWeb.Live.UrlStateSigilLive do
  @moduledoc """
  Exists only to exercise `use PhoenixKitWeb.Live.UrlState` for real.

  The codec tests hand `normalize!/2` an already-evaluated list, so they cannot
  see whether the macro evaluated its options. A `~w()` sigil is the case that
  matters: as unexpanded AST it is a `{:sigil_w, …}` tuple, and a spec built
  from that raises only when a request arrives.
  """
  use Phoenix.LiveView

  use PhoenixKitWeb.Live.UrlState,
    params: [
      sort_by: [default: "name", in: ~w(name email created)],
      sort_dir: [default: :desc, cast: :atom, in: [:asc, :desc]]
    ]

  def handle_url_state(_state, socket), do: socket
  def render(assigns), do: ~H"<div></div>"
end

defmodule PhoenixKitWeb.Live.UrlStateTest do
  @moduledoc """
  Codec tests for `PhoenixKitWeb.Live.UrlState`.

  Encoding and decoding are pure functions over maps, so they need no database
  — which is what makes the URL-state contract cheap to pin.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitWeb.Live.UrlState

  defp cfg(params \\ nil, opts \\ []) do
    params =
      params ||
        [
          search_query: [default: "", url_key: "q", alias: "search"],
          filter_role: [default: "all", url_key: "role"],
          sort_dir: [default: :desc, cast: :atom, in: [:asc, :desc]],
          archived: [default: false, cast: :boolean],
          page: [default: 1, cast: :integer, min: 1]
        ]

    UrlState.normalize!(params, opts)
  end

  describe "normalize!/2" do
    test "requires a default for every param" do
      assert_raise ArgumentError, ~r/is missing :default/, fn ->
        cfg(q: [url_key: "q"])
      end
    end

    test "refuses cast: :atom without an :in whitelist" do
      assert_raise ArgumentError, ~r/requires\s+:in/, fn ->
        cfg(sort_dir: [default: :desc, cast: :atom])
      end
    end

    test "rejects an unsupported cast" do
      assert_raise ArgumentError, ~r/unsupported cast/, fn ->
        cfg(page: [default: 1, cast: :float])
      end
    end

    test "rejects two params claiming the same URL key" do
      assert_raise ArgumentError, ~r/duplicate URL keys/, fn ->
        cfg(a: [default: "", url_key: "q"], b: [default: "", url_key: "q"])
      end
    end

    test "rejects an empty spec" do
      assert_raise ArgumentError, ~r/non-empty :params/, fn -> cfg([]) end
    end

    test "detects :page as the page param, and honours :page_param false" do
      assert cfg().page_param == :page
      assert cfg(nil, page_param: false).page_param == false
      assert cfg(q: [default: ""]).page_param == false
    end

    test "rejects a :page_param that is not declared" do
      assert_raise ArgumentError, ~r/is not declared/, fn ->
        cfg([q: [default: ""]], page_param: :page)
      end
    end

    test "defaults dead_render to :call and validates it" do
      assert cfg().dead_render == :call
      assert cfg(nil, dead_render: :skip).dead_render == :skip

      assert_raise ArgumentError, ~r/:dead_render must be/, fn ->
        cfg(nil, dead_render: :maybe)
      end
    end
  end

  describe "decode/2" do
    test "returns defaults for an empty query" do
      assert UrlState.decode(%{}, cfg()) == %{
               search_query: "",
               filter_role: "all",
               sort_dir: :desc,
               archived: false,
               page: 1
             }
    end

    test "reads a param through its url_key, not its assign name" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())
      assert state.search_query == "ivan"

      # the assign name is not a valid URL key
      assert UrlState.decode(%{"search_query" => "ivan"}, cfg()).search_query == ""
    end

    test "accepts a legacy alias so already-published links keep resolving" do
      assert UrlState.decode(%{"search" => "ivan"}, cfg()).search_query == "ivan"
    end

    test "prefers the canonical key when both it and the alias are present" do
      assert UrlState.decode(%{"q" => "new", "search" => "old"}, cfg()).search_query == "new"
    end

    test "casts integers and falls back to the default below :min" do
      assert UrlState.decode(%{"page" => "4"}, cfg()).page == 4
      assert UrlState.decode(%{"page" => "0"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "-2"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "abc"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "3junk"}, cfg()).page == 1
    end

    test "casts booleans from both 1/0 and true/false" do
      assert UrlState.decode(%{"archived" => "1"}, cfg()).archived == true
      assert UrlState.decode(%{"archived" => "true"}, cfg()).archived == true
      assert UrlState.decode(%{"archived" => "0"}, cfg()).archived == false
      assert UrlState.decode(%{"archived" => "nope"}, cfg()).archived == false
    end

    test "matches atoms against the whitelist without creating any" do
      forged = "pk_url_state_forged_direction"

      assert UrlState.decode(%{"sort_dir" => "asc"}, cfg()).sort_dir == :asc
      assert UrlState.decode(%{"sort_dir" => forged}, cfg()).sort_dir == :desc

      # the forged value must not have become an atom
      assert_raise ArgumentError, fn -> String.to_existing_atom(forged) end
    end

    test "honours an :in whitelist for strings" do
      spec = cfg(status: [default: "any", in: ~w(any open closed)])
      assert UrlState.decode(%{"status" => "open"}, spec).status == "open"
      assert UrlState.decode(%{"status" => "hacked"}, spec).status == "any"
    end

    test "ignores non-binary values, such as a nested form map" do
      assert UrlState.decode(%{"q" => %{"nested" => "x"}}, cfg()).search_query == ""
    end

    test "survives params that are not a map at all" do
      assert UrlState.decode(:not_mounted_at_router, cfg()).page == 1
    end
  end

  describe "encode/3" do
    test "omits every value equal to its default" do
      state = UrlState.decode(%{}, cfg())
      assert UrlState.encode(state, cfg()) == %{}
    end

    test "writes non-defaults under the canonical url_key" do
      state = UrlState.decode(%{"q" => "ivan", "page" => "3"}, cfg())

      assert UrlState.encode(state, cfg()) == %{"q" => "ivan", "page" => "3"}
    end

    test "never writes the alias, so links converge on the canonical key" do
      state = UrlState.decode(%{"search" => "ivan"}, cfg())
      encoded = UrlState.encode(state, cfg())

      assert encoded == %{"q" => "ivan"}
      refute Map.has_key?(encoded, "search")
    end

    test "stringifies atoms and booleans" do
      state = UrlState.decode(%{"sort_dir" => "asc", "archived" => "1"}, cfg())

      assert UrlState.encode(state, cfg()) == %{"sort_dir" => "asc", "archived" => "true"}
    end

    test "keeps unknown query keys so an unrelated param is not dropped" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())

      assert UrlState.encode(state, cfg(), %{"action" => "add"}) == %{
               "q" => "ivan",
               "action" => "add"
             }
    end

    test "clears a key that returned to its default" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())
      back_to_default = %{state | search_query: ""}

      assert UrlState.encode(back_to_default, cfg(), %{"q" => "ivan"}) == %{}
    end
  end

  describe "build_path/4" do
    test "yields a bare path when nothing differs from the defaults" do
      state = UrlState.decode(%{}, cfg())

      assert UrlState.build_path("/admin/users", state, cfg()) == "/admin/users"
    end

    test "appends an encoded query otherwise" do
      state = UrlState.decode(%{"q" => "ivan petrov", "page" => "2"}, cfg())
      path = UrlState.build_path("/admin/users", state, cfg())

      assert path =~ "/admin/users?"
      assert path =~ "q=ivan+petrov"
      assert path =~ "page=2"
    end

    test "preserves the path it is given, including a locale segment" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())

      assert UrlState.build_path("/uk/admin/users", state, cfg()) == "/uk/admin/users?q=ivan"
    end
  end

  describe "decode/2 integer ceiling" do
    test "caps integers by default, so a crafted page cannot overflow OFFSET" do
      # 10^24 parses fine and would reach PostgreSQL as OFFSET, overflowing bigint
      assert UrlState.decode(%{"page" => "999999999999999999999999"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "1000001"}, cfg()).page == 1
      assert UrlState.decode(%{"page" => "1000000"}, cfg()).page == 1_000_000
    end

    test "an explicit :max overrides the default ceiling" do
      spec = cfg(page: [default: 1, cast: :integer, min: 1, max: 50])

      assert UrlState.decode(%{"page" => "50"}, spec).page == 50
      assert UrlState.decode(%{"page" => "51"}, spec).page == 1
    end
  end

  describe "reload?/3" do
    test "does not reload when the state is unchanged and already loaded" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())

      refute UrlState.reload?(true, state, state)
    end

    test "reloads when a declared param changed" do
      previous = UrlState.decode(%{"q" => "ivan"}, cfg())
      current = UrlState.decode(%{"q" => "petr"}, cfg())

      assert UrlState.reload?(true, current, previous)
    end

    test "reloads the first time even when the state equals the defaults" do
      state = UrlState.decode(%{}, cfg())

      assert UrlState.reload?(false, state, state)
      assert UrlState.reload?(nil, state, nil)
    end
  end

  describe "url_state_path/2" do
    defp assigns_for(state, opts \\ []) do
      %{
        :__phoenix_kit_url_cfg__ => cfg(),
        :__phoenix_kit_url_state__ => state,
        :__phoenix_kit_url_path__ => Keyword.get(opts, :path, "/admin/users"),
        :__phoenix_kit_url_extra__ => Keyword.get(opts, :extra, %{})
      }
    end

    test "resets the page when another parameter changes" do
      state = UrlState.decode(%{"q" => "ivan", "page" => "5"}, cfg())

      path = UrlState.url_state_path(assigns_for(state), search_query: "petr")

      assert path == "/admin/users?q=petr"
    end

    test "keeps the page when the page itself is what changed" do
      state = UrlState.decode(%{"q" => "ivan", "page" => "5"}, cfg())

      assert UrlState.url_state_path(assigns_for(state), page: 3) =~ "page=3"
      assert UrlState.url_state_path(assigns_for(state), page: 3) =~ "q=ivan"
    end

    test "returns the bare path once everything is back to its default" do
      state = UrlState.decode(%{"q" => "ivan"}, cfg())

      assert UrlState.url_state_path(assigns_for(state), search_query: "") == "/admin/users"
    end

    test "preserves query keys the spec does not declare" do
      state = UrlState.decode(%{}, cfg())
      assigns = assigns_for(state, extra: %{"return_to" => "/admin/media"})

      path = UrlState.url_state_path(assigns, search_query: "logo")

      assert path =~ "q=logo"
      assert path =~ "return_to=%2Fadmin%2Fmedia"
    end

    test "patches the path it is on, so a locale segment is not lost" do
      state = UrlState.decode(%{}, cfg())
      assigns = assigns_for(state, path: "/uk/admin/users")

      assert UrlState.url_state_path(assigns, search_query: "ivan") == "/uk/admin/users?q=ivan"
    end

    test "falls back to :url_path, then to root, when no path was captured" do
      state = UrlState.decode(%{}, cfg())

      from_url_path =
        state
        |> assigns_for()
        |> Map.delete(:__phoenix_kit_url_path__)
        |> Map.put(:url_path, "/admin/users")

      assert UrlState.url_state_path(from_url_path, search_query: "ivan") == "/admin/users?q=ivan"

      bare = Map.delete(assigns_for(state), :__phoenix_kit_url_path__)
      assert UrlState.url_state_path(bare, search_query: "ivan") == "/?q=ivan"
    end

    test "picks up a declared param set with a plain assign" do
      # A LiveView that re-picks its sort column with `assign(:filter_role, …)`
      # leaves the bookkeeping map stale. Merging onto that map would put the
      # superseded value back in the URL on the next patch — and a reload would
      # apply it. The freshest assign has to win.
      state = UrlState.decode(%{"role" => "admin"}, cfg())

      assigns =
        assigns_for(state)
        |> Map.put(:filter_role, "owner")

      assert UrlState.url_state_path(assigns, search_query: "ivan") ==
               "/admin/users?q=ivan&role=owner"
    end

    test "never writes a value the decoder would reject" do
      spec =
        cfg(
          status: [default: "any", in: ~w(any open closed)],
          page: [default: 1, cast: :integer, min: 1, max: 99]
        )

      state = UrlState.decode(%{}, spec)

      assigns = %{
        :__phoenix_kit_url_cfg__ => spec,
        :__phoenix_kit_url_state__ => state,
        :__phoenix_kit_url_path__ => "/admin/things",
        :__phoenix_kit_url_extra__ => %{}
      }

      # a caller handing over a value outside the whitelist, or out of bounds,
      # falls back to the default instead of putting a lie in the address bar
      assert UrlState.url_state_path(assigns, status: "deleted") == "/admin/things"
      assert UrlState.url_state_path(assigns, page: 500) == "/admin/things"
      assert UrlState.url_state_path(assigns, status: "open") == "/admin/things?status=open"
    end

    test "rejects a change keyed by URL key instead of assign name" do
      state = UrlState.decode(%{}, cfg())

      assert_raise ArgumentError, ~r/unknown UrlState parameter\(s\): \[:q\]/, fn ->
        UrlState.url_state_path(assigns_for(state), q: "ivan")
      end
    end

    test "explains itself when handed a socket during render" do
      not_in_socket = %Phoenix.LiveView.Socket.AssignsNotInSocket{__assigns__: %{}}
      socket = %Phoenix.LiveView.Socket{assigns: not_in_socket}

      assert_raise ArgumentError, ~r/pass `assigns`, not `@socket`/, fn ->
        UrlState.url_state_path(socket, search_query: "ivan")
      end
    end
  end

  describe "use PhoenixKitWeb.Live.UrlState" do
    alias PhoenixKitWeb.Live.UrlStateSigilLive

    test "evaluates its options, so a ~w sigil in :in becomes a list" do
      cfg = UrlStateSigilLive.__phoenix_kit_url_state__()
      sort_by = Enum.find(cfg.params, &(&1.key == :sort_by))

      assert sort_by.allowed == ["name", "email", "created"]
    end

    test "whitelists against that list at request time" do
      cfg = UrlStateSigilLive.__phoenix_kit_url_state__()

      assert UrlState.decode(%{"sort_by" => "email"}, cfg).sort_by == "email"
      assert UrlState.decode(%{"sort_by" => "'; DROP TABLE users--"}, cfg).sort_by == "name"
    end
  end

  describe "mode" do
    test "defaults to :patch and validates the option" do
      assert cfg().mode == :patch
      assert cfg(nil, mode: :history).mode == :history

      assert_raise ArgumentError, ~r/:mode must be :patch or :history/, fn ->
        cfg(nil, mode: :sideways)
      end
    end

    test "url_state_sync/1 renders the hook only in :history mode" do
      history =
        render_component(&UrlState.url_state_sync/1, mode: :history, id: "sync-a")

      assert history =~ ~s(phx-hook="PhoenixKitUrlState")
      assert history =~ ~s(id="sync-a")

      assert render_component(&UrlState.url_state_sync/1, mode: :patch) == ""
    end
  end

  describe "extras_from_uri/2" do
    test "takes extras from the query string, never from a path segment" do
      extras =
        UrlState.extras_from_uri(
          "/admin/catalogue/0193aaaa-bbbb-7000-8000-000000000001?q=oak&return_to=/admin/media",
          cfg()
        )

      # `q` is a declared url_key; the uuid lives only in the path
      refute Map.has_key?(extras, "q")
      refute Map.has_key?(extras, "uuid")
      assert extras == %{"return_to" => "/admin/media"}
    end

    test "a uuid that really is a query key is still preserved" do
      extras =
        UrlState.extras_from_uri(
          "/admin/users?uuid=0193aaaa-bbbb-7000-8000-000000000001",
          cfg()
        )

      assert extras == %{"uuid" => "0193aaaa-bbbb-7000-8000-000000000001"}
    end

    test "an empty or missing query yields no extras" do
      assert UrlState.extras_from_uri("/admin/users", cfg()) == %{}
      assert UrlState.extras_from_uri("/admin/users?", cfg()) == %{}
    end
  end

  describe "round trip" do
    test "decode(encode(state)) is the identity for every declared param" do
      original = UrlState.decode(%{"q" => "ivan", "role" => "admin", "sort_dir" => "asc"}, cfg())

      round_tripped =
        original
        |> UrlState.encode(cfg())
        |> UrlState.decode(cfg())

      assert round_tripped == original
    end
  end

  describe "put_url_state_default/3" do
    defp socket_with(cfg) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          :__changed__ => %{},
          :__phoenix_kit_url_cfg__ => cfg,
          :__phoenix_kit_url_state__ => UrlState.decode(%{}, cfg),
          :__phoenix_kit_url_path__ => "/admin/users",
          :__phoenix_kit_url_extra__ => %{}
        }
      }
    end

    defp spec_default(socket, key) do
      Enum.find(socket.assigns.__phoenix_kit_url_cfg__.params, &(&1.key == key)).default
    end

    test "a new default is what a URL without the key reads, and is left out of URLs" do
      cfg =
        cfg(
          page: [default: 1, cast: :integer, min: 1],
          per_page: [default: 25, cast: :integer, in: [10, 25, 50]]
        )

      socket = UrlState.put_url_state_default(socket_with(cfg), :per_page, 50)
      new_cfg = socket.assigns.__phoenix_kit_url_cfg__

      assert UrlState.decode(%{}, new_cfg).per_page == 50
      # A URL that names another value still wins.
      assert UrlState.decode(%{"per_page" => "10"}, new_cfg).per_page == 10
      assert UrlState.build_path("/l", %{page: 1, per_page: 50}, new_cfg) == "/l"
      assert UrlState.build_path("/l", %{page: 1, per_page: 25}, new_cfg) == "/l?per_page=25"
    end

    test "a value the parameter would refuse from a URL leaves the default alone" do
      cfg =
        cfg(
          per_page: [default: 25, cast: :integer, in: [10, 25, 50]],
          fit: [default: false, cast: :boolean]
        )

      socket = socket_with(cfg)

      for {key, bad} <- [per_page: 7, per_page: "50", fit: "true"] do
        refute spec_default(UrlState.put_url_state_default(socket, key, bad), key) == bad
      end

      assert spec_default(UrlState.put_url_state_default(socket, :fit, true), :fit) == true
    end

    test "an undeclared parameter raises" do
      assert_raise ArgumentError, ~r/unknown UrlState parameter/, fn ->
        UrlState.put_url_state_default(socket_with(cfg()), :nope, 1)
      end
    end
  end
end
