defmodule PhoenixKit.Utils.Routes do
  @moduledoc """
  Utility functions for working with PhoenixKit routes and URLs.

  This module provides helpers for constructing URLs with the correct
  PhoenixKit prefix configured in the application.
  """

  require Logger

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth.Scope

  @default_locale Config.default_locale()

  # List of path prefixes that should NEVER have a locale added.
  # This should be kept in sync with @reserved_segments in LocaleExtractor plug.
  @reserved_prefixes ~w(/api /webhooks /assets /static /files /images /fonts /js /css /sitemap)

  @doc """
  Returns the configured PhoenixKit URL prefix.

  ## Examples

      iex> PhoenixKit.Utils.Routes.url_prefix()
      "/phoenix_kit"

  """
  @spec url_prefix() :: String.t()
  def url_prefix, do: Config.get_url_prefix()

  @doc """
  Returns `true` when `path` is safe to use as a local redirect / `return_to`
  target: a binary that begins with a single `/` but not `//` or `/\\` — both of
  which browsers resolve as protocol-relative, host-switching URLs. Use this to
  guard user-supplied redirect params against open-redirect attacks.

  ASCII control characters are rejected too. Browsers strip tab/CR/LF while
  parsing a URL, so `"/\\t/evil.example"` (from `?return_to=%2F%09%2Fevil.example`)
  becomes `//evil.example` — a cross-origin navigation — once it reaches
  `window.location`. `Phoenix.Controller.redirect/2` blocks those itself, but
  LiveView's `validate_local_url!` only rejects `\\\\` and a leading `//`, so a
  LiveView `redirect(socket, to: ...)` would otherwise pass it through.

  ## Examples

      iex> PhoenixKit.Utils.Routes.local_path?("/admin/dashboard")
      true
      iex> PhoenixKit.Utils.Routes.local_path?("//evil.com")
      false
      iex> PhoenixKit.Utils.Routes.local_path?("https://evil.com")
      false
      iex> PhoenixKit.Utils.Routes.local_path?("/\\t/evil.com")
      false

  """
  @spec local_path?(term()) :: boolean()
  def local_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.starts_with?(path, "/\\") and
      not contains_control_char?(path)
  end

  def local_path?(_), do: false

  # ASCII control chars (C0 + DEL). Checked bytewise: a control char is
  # single-byte in UTF-8 and can never appear inside a multi-byte sequence.
  defp contains_control_char?(path) do
    path
    |> :binary.bin_to_list()
    |> Enum.any?(fn byte -> byte <= 0x1F or byte == 0x7F end)
  end

  @doc """
  Resolves where to send a user once they are signed in and confirmed.

  Takes candidate destinations in priority order (e.g. a `?return_to=` param,
  then the session's `user_return_to`) and returns the first that passes
  `local_path?/1`. Falls back to the `after_login_path` setting, then to
  core's own guaranteed landing, `/admin`.

  The setting is validated as a local path when saved, but is re-guarded here
  so a hand-edited DB row can't turn a post-auth redirect into an open
  redirect. Single source of truth for the post-auth landing page — used by
  the login flow (`signed_in_path/1`) and by both confirmation LiveViews.

  ## Options

    * `:context` — the `conn`/`socket` the redirect is being built for. **Pass
      it wherever one is at hand.** `"/"` is the host's home page and core
      declares no route for it; with a context the tail of the chain is probed
      with `routable?/2` and, when the host really has no `/`, handed to
      `safe_destination/2`, which can then pick the *best* destination for this
      subject instead of merely a safe one. Without a context the tail is
      `path("/admin")` — still safe, just less specific.
    * `:scope` — the subject, forwarded to `safe_destination/2` for that last
      step. Only consulted when a `:context` is present.

  The context-less tail is `path("/admin")` and deliberately **not**
  `safe_destination(nil, opts)`: with no scope to go on that call runs the
  ANONYMOUS chain and terminates on `/users/log-in`, whose `on_mount` bounces
  an authenticated visitor straight back through here — the "core-owned
  destination" guarantee would survive exactly one hop. `/admin` is scope-blind
  on purpose: core declares it unconditionally and admits every authenticated
  visitor, so it cannot bounce anyone.

  ## Examples

      iex> PhoenixKit.Utils.Routes.post_auth_path(["/checkout"])
      "/checkout"

  With nothing usable to go on the chain lands on core's guaranteed landing.
  Its exact shape depends on the host's mount prefix and the language settings,
  so these read as comparisons rather than literals — they asserted `"/"` back
  when the tail was the host's unowned home page:

      iex> alias PhoenixKit.Utils.Routes
      iex> Routes.post_auth_path(["https://evil.com", nil]) == Routes.path("/admin")
      true

      iex> alias PhoenixKit.Utils.Routes
      iex> Routes.post_auth_path(["/users/log-out"]) == Routes.path("/admin")
      true

  """
  @spec post_auth_path([term()], keyword()) :: String.t()
  def post_auth_path(candidates \\ [], opts \\ [])
      when is_list(candidates) and is_list(opts) do
    Enum.find(candidates, &usable_candidate?/1) || home_after_auth(opts)
  end

  defp home_after_auth(opts) do
    # An administrator's explicit `after_login_path` is honoured as given — the
    # same rule as before, deliberately NOT routability-probed. It names a page
    # in the host's application, and silently ignoring it because this router
    # cannot see that page would break the setting rather than protect it.
    #
    # The home page is the opposite case: nobody chose it, core named it, and it
    # is the one destination core has no way to declare. So it is only used
    # where the host proves it exists — both shapes, see `home_candidates/0` —
    # and a core-owned landing takes over where it does not.
    after_login_setting() || home_or_core_landing(Keyword.get(opts, :context), opts)
  end

  # No context, so nothing can be probed: hand back the landing core declares
  # unconditionally instead of synthesizing the host's `"/"`, which 404s on
  # every install that never declared a root route.
  #
  # Scope-blind ON PURPOSE. Delegating to `safe_destination(nil, opts)` looks
  # tidier and is wrong: with no scope that call runs the ANONYMOUS chain and
  # terminates on `/users/log-in`, an auth page, which bounces an authenticated
  # visitor straight back through `post_auth_path/2` — the one-hop loop
  # described in that function's `@doc`. `/admin` admits every authenticated
  # visitor and simply renders for them, so it is safe to return without
  # knowing who is asking.
  defp home_or_core_landing(nil, _opts), do: path("/admin")

  defp home_or_core_landing(context, opts) do
    found =
      home_candidates()
      |> Stream.map(& &1.())
      |> Enum.find(&admissible_candidate?(context, &1, false))

    found || safe_destination(context, scope: Keyword.get(opts, :scope))
  end

  # A candidate carries the same two requirements as the setting: local, and
  # not a page that bounces an authenticated visitor. The candidates are the
  # LESS trusted of the two — `?return_to=` is whatever a link contained — so
  # `?return_to=/users/log-out` on any auth link would otherwise sign the user
  # back out the instant they signed in.
  defp usable_candidate?(path), do: local_path?(path) and not auth_page?(path)

  @typedoc """
  The request a redirect is being built for. The application's router is read
  from it, which is how `routable?/2` works. `nil` is accepted — it simply
  makes every candidate fail closed, so the chain lands on a core-owned page.
  """
  @type request_context :: Plug.Conn.t() | Phoenix.LiveView.Socket.t() | nil

  @doc """
  Resolves where to send a visitor that core is *allowed* to send them.

  Replaces every hardcoded `"/"` / `Routes.path("/")` destination in core.
  `Routes.path("/")` emits a locale-prefixed root (`/en`); the route that would
  serve it belongs to the host application, which core cannot declare, so on a
  host that never declared one every such redirect 404s.

  ## The chain

  Authenticated (`opts[:scope]` passes `Scope.authenticated?/1`):

    1. `:return_to` — the untrusted explicit destination
    2. `/admin`, when `Scope.can_access_admin_area?/1` and `:skip_admin` is not set
    3. `/dashboard`
    4. the `after_login_path` setting
    5. the host's home page — `path("/")`, then `"/"`

  Anonymous:

    1. the `main_page_path` setting, when set and still resolvable
    2. the host's home page — `path("/")`, then `"/"`

  Every candidate must be a local path (`local_path?/1`), not an auth page
  (`auth_page?/1`), **and actually routable** (`routable?/2`). Under
  `:skip_admin` it must additionally not be an admin-area path
  (`admin_area_path?/1`) — see the option below.

  The home page is a candidate like any other, and only like any other. It is
  the one destination in this whole mechanism that core cannot declare, so it
  is used exactly where the host proves it declared it, and skipped silently
  everywhere else. Dropping it entirely would have been a silent regression for
  every already-working install, where logging out has always landed on the
  site home.

  Both shapes are offered, locale-prefixed first, because a multilingual host
  may declare either or both — see `home_candidates/0`. The prefixed form is
  what the eleven original call sites emitted; the defect was that they emitted
  it *unprobed*, not that they named it.

  When nothing survives, the terminal is core's own: `/admin` for any
  authenticated visitor, `/users/log-in` for an anonymous one. The terminal
  follows authentication rather than being a single page, because
  `/users/log-in` bounces a signed-in visitor straight back out again —
  terminating an authenticated chain there would hand the decision to
  `post_auth_path/2`, one hop later.

  ## Options

    * `:scope` — `%PhoenixKit.Users.Auth.Scope{}` or `nil`. **Pass it
      explicitly.** Several call sites run on pipelines that never assign a
      scope, and full logout still carries the just-logged-out user in
      `conn.assigns` after the session has been cleared, so inferring it here
      would answer "authenticated" about someone who no longer is.
    * `:return_to` — a candidate path, or a list of them in priority order.
      Honoured on the authenticated chain only: an anonymous pending
      destination belongs in the `user_return_to` session key, not in a
      redirect.
    * `:skip_admin` — the caller is *rejecting* this visitor from the admin
      area. It suppresses step 2 **and drops every remaining candidate that
      resolves into the admin area** (`admin_area_path?/1`), whichever step
      produced it — a `:return_to`, or an `after_login_path` an operator
      pointed at `/admin/users`. Suppressing only step 2 was not enough: on a
      host with `user_dashboard_enabled: false` the setting was the first
      candidate left standing, it is routable, and handing it back re-entered
      the same gate that had just refused the visitor — a candidate always won,
      the terminal was never reached, and the browser gave up with
      `ERR_TOO_MANY_REDIRECTS`.

      The terminal is deliberately NOT filtered: it is the `/admin` index,
      which the gate admits every authenticated visitor to, so arriving there
      is a render rather than a second bounce. That asymmetry is the whole
      point — the chain has somewhere to end.

  ## The invariant

  Every value returned is either a path the caller supplied, an administrator
  configured, or one of the two shapes of the host's own home page — **each
  proven to resolve in the router** — or one of the two landings core declares
  itself. There is no third branch, and nothing is ever returned unprobed
  except those two landings, which core declares and permits unconditionally.

  `path("/")`, the locale-prefixed root that started all this, is therefore
  still a candidate — it simply may no longer be *synthesized*. That distinction
  is the fix: the eleven original call sites returned it without asking whether
  it resolved, which is why it 404'd.

  The invariant used to be "every candidate was probed, terminals included",
  because core could promise nothing about its own pages: `/dashboard` is
  compiled out by `user_dashboard_enabled: false`, and `/admin` used to reject
  an authenticated visitor who held no admin rights. Neither is true of the
  terminals any more:

    * `/admin` is declared unconditionally by the admin index route and, since
      `:phoenix_kit_ensure_admin` exempts that one view from its permission
      checks (`PhoenixKitWeb.Users.Auth.landing_view?/1`), admits every
      authenticated visitor — one who holds no rights is greeted and shown
      nothing else. So it can neither 404 nor bounce.
    * `/users/log-in` is declared unconditionally too, by the public auth
      surface. That is a **separate** fact from the `/admin` decision: it rests
      on `generate_public_live_routes/1` in `PhoenixKitWeb.Integration`, not on
      anything the admin area does, and it holds independently of it.

  So the invariant is now: **the chain ends at a path core declares
  unconditionally and permits unconditionally.** The terminal is still handed
  to `routable?/2`, but only as a diagnostic — the arm is returned either way,
  and the probe exists to name a misconfigured install in the log instead of
  letting it surface as a mystery 404. See `terminal/2`.

  That invariant is about the TERMINAL, and stating it was not enough to make
  the chain terminate. A candidate that wins is returned instead of the
  terminal, so under `:skip_admin` — the rejection path — the candidates are
  held to the weaker fact the caller actually needs: **no candidate may be an
  admin-area path.** Otherwise the resolver can answer with the very kind of
  page the visitor was just refused, the gate refuses it again, and the
  identical computation runs forever without ever reaching the terminal it was
  promised. With the filter in place a `skip_admin` resolution is either a
  non-admin path proven routable in this router, or the `/admin` index — and
  the index admits everyone, so the next hop renders.

  The authenticated terminal is not an auth page: `/users/log-in` redirects an
  authenticated visitor through `post_auth_path/2`, which re-enters this
  function, so using it there is an infinite redirect rather than a fallback.
  """
  @spec safe_destination(request_context(), keyword()) :: String.t()
  def safe_destination(context, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    authenticated? = Scope.authenticated?(scope)
    skip_admin? = Keyword.get(opts, :skip_admin, false)
    admin? = not skip_admin? and Scope.can_access_admin_area?(scope)

    candidates =
      if authenticated? do
        authenticated_candidates(opts, admin?)
      else
        anonymous_candidates()
      end

    found =
      candidates
      # Lazily: candidates are thunks so the settings read at the tail of the
      # chain never happens for a visitor the earlier steps already placed.
      |> Stream.map(& &1.())
      |> Enum.find(&admissible_candidate?(context, &1, skip_admin?))

    found || terminal(context, authenticated?)
  end

  defp authenticated_candidates(opts, admin?) do
    explicit = Enum.map(List.wrap(Keyword.get(opts, :return_to)), fn c -> fn -> c end end)

    explicit ++
      [
        fn -> if admin?, do: path("/admin") end,
        # A CANDIDATE, not the terminal. `/dashboard` is still conditionally
        # compiled by the host router (`user_dashboard_enabled`, whose
        # deprecation stands), so it is probed with `routable?/2` like any
        # other candidate rather than assumed. Where the host compiled it out
        # the chain simply moves on — nothing below depends on it any more.
        fn -> path("/dashboard") end,
        fn -> setting_candidate("after_login_path") end
      ] ++ home_candidates()
  end

  defp anonymous_candidates do
    [fn -> main_page_path() end] ++ home_candidates()
  end

  # The host's home page, in the two shapes core can name it by, most specific
  # first. NEITHER is synthesized blind — both go through
  # `admissible_candidate?/3` like every other candidate, and that probe is the
  # whole difference from the defect this module was written for: the eleven
  # call sites emitted `path("/")` UNPROBED, so it 404'd on every host that
  # never declared a locale-prefixed root.
  #
  # Probed, `path("/")` is simply the BETTER of the two wherever the host did
  # declare one — which is the setup core's own release notes have been asking
  # hosts for. Dropping it left a real regression on those hosts: a logout, a
  # maintenance eject or a password-reset failure used to land on `/et` and now
  # landed on `/`, silently switching the visitor's language — or, where the
  # host declared ONLY the locale-prefixed root, fell past the home page
  # entirely and terminated on `/users/log-in`.
  #
  # It collapses to `"/"` whenever no locale prefix applies (a single-language
  # install, or the default language configured prefixless); the second element
  # is dropped then rather than probing the same path twice. Under a mount
  # prefix it yields `/phoenix_kit/en`, which is core's own mount point and not
  # the host's home at all — the probe simply refuses it, which is the point of
  # asking the router instead of trusting the shape.
  defp home_candidates do
    case path("/") do
      "/" -> [fn -> "/" end]
      localized_root -> [fn -> localized_root end, fn -> "/" end]
    end
  end

  @doc """
  The host's own home page, localized — for a plain navigation link (the
  admin header's project-title link), not a redirect chain.

  Deliberately NOT `path("/", locale: locale)`. That function's `"/"` is core's
  OWN mount point — under `url_prefix: "/phoenix_kit"` it is
  `/phoenix_kit/ru`, which is where CORE lives, not where the host's home page
  is. `home_candidates/0` above treats it as a candidate for exactly that
  reason — a multilingual host is free to also declare a route matching core's
  mount+locale shape — but a plain "go home" link means the host's own root,
  independent of wherever core happens to be mounted, so the candidate here is
  built directly from `locale` rather than through `path/2`:

    1. `"/" <> locale` — the host's home page in the visitor's language, e.g.
       `/ru`. Tried first: a visitor reading the admin area in a non-default
       language is kept in it.
    2. `"/"` — the host's unlocalized home. The unconditional fallback, same
       as the hardcoded `href="/"` every admin page carried before #843 — so a
       host that never declared a `/:locale` scope sees no regression.

  Neither is emitted unprobed: `routable?/2` gates the first, same rule #685
  put on every other core-owned link. The second is not re-probed — it is the
  fallback of last resort, exactly as unconditional as it was before this
  function existed.

  `context` is the `conn` or `socket` the link is being rendered for;
  `nil` fails every probe closed and returns `"/"`.
  """
  @spec home_path(request_context(), String.t() | nil) :: String.t()
  def home_path(context, locale) do
    # The prefixless-primary rule applies here as everywhere else a locale
    # segment is emitted: the default language on a
    # `default_language_no_prefix: true` site lives at `/`, not `/en`.
    candidates =
      if is_binary(locale) and not (default_locale?(locale) and prefixless_primary?()),
        do: ["/" <> locale, "/"],
        else: ["/"]

    Enum.find(candidates, &routable?(context, &1)) || List.last(candidates)
  end

  # The terminal follows AUTHENTICATION, not the admin flag: sending a signed-in
  # visitor to `/users/log-in` would bounce them straight back — that page
  # redirects an authenticated visitor through `post_auth_path/2`, which
  # re-enters this function, so an auth page as an authenticated terminal is an
  # infinite redirect, not a fallback.
  #
  # Both arms are ASSERTED rather than chosen, because each is a path core
  # declares unconditionally AND permits unconditionally:
  #
  #   * `/admin` — the admin index route is declared unconditionally, and
  #     `:phoenix_kit_ensure_admin` exempts that one view from both of its
  #     permission checks (`PhoenixKitWeb.Users.Auth.landing_view?/1`), so every
  #     authenticated visitor may open it; one holding no rights is greeted and
  #     shown nothing else.
  #
  #     This is why there is no longer an `admin?` gate here. The previous
  #     version gated every /admin arm on it, and had to: an unconditional
  #     /admin arm looped, because the admin guard bounced a non-admin back
  #     through `safe_destination/2` with `skip_admin: true` and got the same
  #     arm again. /admin no longer rejects an authenticated visitor, so THIS
  #     ARM has nothing left to bounce off and nothing left to loop.
  #
  #     That is a statement about the terminal and nothing else — it was once
  #     written as though it settled the whole function, and it did not. A
  #     candidate that resolves is returned INSTEAD of the terminal, so an
  #     admin-area candidate reproduced the very loop this arm had been cleared
  #     of: the guard bounced the visitor back with `skip_admin: true`, the
  #     candidate won again, and the terminal was never reached. Candidates
  #     carry their own rule, in `admissible_candidate?/3`: under `skip_admin`
  #     none of them may be an admin path. Only then is the terminal the one
  #     admin path the resolver can produce on that path, and only then does
  #     "nothing left to loop" describe the function rather than this line.
  #
  #     (`skip_admin` also suppresses the /admin CANDIDATE above — that one is a
  #     preference between two pages the visitor may open, not a permission
  #     check.)
  #
  #   * `/users/log-in` — licensed by a DIFFERENT fact: the public auth surface
  #     (`generate_public_live_routes/1` in `PhoenixKitWeb.Integration`)
  #     declares it unconditionally. That holds independently of anything the
  #     admin area does, and would still hold if the /admin decision were
  #     reversed.
  #
  # The trailing bare `"/"` arm went with them. It was there because neither
  # core landing could be promised — and it is the one destination core cannot
  # promise either, since the route belongs to the host.
  #
  # `routable?/2` is still consulted, but only as a DIAGNOSTIC: the arm is
  # returned either way. See `unreachable_terminal/3`.
  defp terminal(context, authenticated?) do
    arm = if authenticated?, do: path("/admin"), else: path("/users/log-in")

    unreachable_terminal(context, authenticated?, arm)

    arm
  end

  # Core's own landing does not resolve in this host's router. After the two
  # guarantees above that means the install is misconfigured rather than merely
  # minimal — typically `phoenix_kit_routes()` mounted at a prefix that
  # disagrees with `config :phoenix_kit, url_prefix:`. A 404 is unavoidable at
  # that point, so the value of this branch is that the cause is named in the
  # log rather than reaching an operator as "some users get a 404 after logging
  # in".
  #
  # Silent when the router cannot be determined at all (no context, a conn
  # before dispatch, a socket not mounted at the router): `routable?/2` fails
  # closed there by design, and "nothing to ask" is not evidence of a
  # misconfiguration.
  defp unreachable_terminal(context, authenticated?, arm) do
    if router_for(context) && not routable?(context, arm) do
      Logger.error("""
      PhoenixKit's guaranteed landing for \
      #{if authenticated?, do: "an authenticated", else: "an anonymous"} visitor \
      — #{arm} — does not resolve in this application's router. It is being used \
      anyway, and it will 404.

      Core declares that route unconditionally, so a router that cannot match it \
      is misconfigured rather than minimal. Check that `phoenix_kit_routes()` is \
      mounted at the prefix `config :phoenix_kit, url_prefix:` names.\
      """)
    end

    :ok
  end

  # A candidate has to be usable and routable — and, on the rejection path,
  # admissible for a visitor who was just refused the admin area.
  #
  # Routability is necessary but NOT sufficient there. `/admin/users` resolves
  # perfectly well; the visitor simply may not open it, and `:phoenix_kit_ensure_admin`
  # answers that by calling straight back into this function with the same
  # arguments. Probing only `routable?/2` is what let an `after_login_path`
  # inside the admin area loop forever on a host with no `/dashboard` route.
  #
  # This is a PATH test rather than a permission one, deliberately. Asking
  # `PhoenixKitWeb.Users.Auth.can_access_admin_view?/2` would answer the finer
  # question — "may THIS scope open THAT page" — at three costs this module
  # cannot pay: a call from `PhoenixKit.*` into `PhoenixKitWeb.*`, which is the
  # wrong direction (`PhoenixKitWeb.Users.Auth` already depends on this module,
  # so the two would be mutually recursive); a path→LiveView resolution that
  # only works when a router is readable, while `safe_destination/2` is
  # documented to work with `context: nil`; and a verdict that varies with
  # permissions, module enablement and settings, so termination would rest on
  # a computation rather than on the shape of the value. The categorical
  # version needs none of that: under `skip_admin` no candidate is ever an
  # admin path, so the only admin path the resolver can return is the terminal,
  # which admits everyone. Termination by construction.
  defp admissible_candidate?(context, candidate, true) do
    not admin_area_path?(candidate) and routable_candidate?(context, candidate)
  end

  defp admissible_candidate?(context, candidate, false) do
    routable_candidate?(context, candidate)
  end

  @doc """
  The kit's URL prefix as a path base: `""` when the kit is mounted at the
  root (`url_prefix` `"/"` or `""`), the prefix without a trailing slash
  otherwise — so `prefix_base() <> "/access"` is a path in both cases.
  """
  @spec prefix_base() :: String.t()
  def prefix_base do
    case Config.get_url_prefix() do
      prefix when prefix in ["", "/"] -> ""
      prefix -> String.trim_trailing(prefix, "/")
    end
  end

  @doc """
  Whether a REAL URL lands in PhoenixKit's admin area.

  Not the same question as the argument to `path/1` answers. `path/1` takes the
  canonical, unprefixed, unlocalized shape (`"/admin/users"`); this takes the
  other shape — a value an operator typed into a setting, a `?return_to=`, an
  HTTP referer — already wearing the host's mount prefix and, on a multilingual
  site, a locale segment (`/phoenix_kit/et/admin/users`). So the path is
  un-built the way `path/1` builds it: drop the configured `url_prefix`, allow
  one leading segment for the locale, and compare the remainder by **segment**
  against `PhoenixKit.Config.get_admin_path/0`.

  Two properties that matter to callers:

    * It reads the **configured** admin segment, so it keeps working on a host
      that set `config :phoenix_kit, admin_path:`. Hand-rolling
      `String.contains?(path, "/admin/")` does not, and it also claims
      `/administrators` and a host's own page at `/shop/admin`.
    * It is **over-strict on purpose**, exactly as `auth_page?/1` is: a host
      page at `/shop/admin` is reported as admin-area. Refusing one legitimate
      path is a better failure than the alternatives this guards — for core's
      own resolver, an unbounded redirect loop; for a caller allowlisting a
      client-supplied return path, an open redirect.

  ## For module packages

  This is the supported way to ask the question. A package that allowlists a
  redirect target (a `_live_referer`, a `?return_to=`) should pair it with
  `local_path?/1`, which is what rejects `//evil.com`, `/\\evil.com` and ASCII
  control characters:

      if Routes.local_path?(path) and Routes.admin_area_path?(path) do
        path
      end

  Order matters only for readability — neither implies the other.
  `admin_area_path?/1` is about WHERE a path points; `local_path?/1` is about
  whether it points off-site at all.

  ## Examples

      iex> PhoenixKit.Utils.Routes.admin_area_path?("/phoenix_kit/admin/users")
      true

      iex> PhoenixKit.Utils.Routes.admin_area_path?("/phoenix_kit/et/admin/users")
      true

      iex> PhoenixKit.Utils.Routes.admin_area_path?("/phoenix_kit/users/log-in")
      false

  """
  @spec admin_area_path?(term()) :: boolean()
  def admin_area_path?(candidate) when is_binary(candidate) do
    # The CONFIGURED segment, not the canonical `"admin"` — this predicate reads
    # real URLs (a `?return_to=`, an `after_login_path` an operator typed), and
    # on a host that renamed the admin area those wear the new name. Comparing
    # against `"admin"` there would leave the loop guard matching nothing, which
    # is the one failure this function exists to prevent.
    admin = String.trim_leading(Config.get_admin_path(), "/")

    segments =
      candidate
      |> path_only()
      |> strip_url_prefix()
      |> String.split("/", trim: true)

    match?([^admin | _], segments) or match?([_locale, ^admin | _], segments)
  end

  def admin_area_path?(_candidate), do: false

  # Mirrors the `base_path` computation in `path/1`: a `url_prefix` of `"/"`
  # contributes no segment at all, anything else is a literal leading segment.
  defp strip_url_prefix(path) do
    prefix = Config.get_url_prefix()

    cond do
      prefix == "/" -> path
      path == prefix -> "/"
      String.starts_with?(path, prefix <> "/") -> String.replace_prefix(path, prefix, "")
      true -> path
    end
  end

  defp routable_candidate?(context, candidate) do
    usable_candidate?(candidate) and routable?(context, candidate)
  end

  # Raw setting read. Deliberately NOT `after_login_path/0`, which substitutes
  # `"/"` when the setting is blank or unsafe — that would smuggle the unowned
  # root back into the chain as a value core synthesized rather than one an
  # administrator chose.
  defp setting_candidate(key) do
    case key |> PhoenixKit.Settings.get_setting_cached("") |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @doc """
  The configured site main page, or `nil` when unset or unusable.

  `nil` rather than `"/"` is deliberate: an unset setting means "nobody chose",
  and `safe_destination/2` probes `"/"` on its own as the *last* candidate. A
  `"/"` default here would instead assert it as the administrator's
  first-priority choice — ahead of everything, on a host that may not route it.

  The setting is validated as a local path when saved and re-guarded here on
  read, so a hand-edited DB row can't turn it into an open redirect.
  """
  @spec main_page_path() :: String.t() | nil
  def main_page_path do
    case setting_candidate("main_page_path") do
      nil -> nil
      value -> if usable_candidate?(value), do: value, else: nil
    end
  end

  @doc """
  Where the "Settings" entry in the user menu should point.

  Core's own account page, `/profile/settings`, unless an operator set
  `user_settings_path` — the escape hatch for a host that wants to own the
  account UI. Every user-facing link to the settings page resolves through
  here, so pointing one setting at a host page moves all of them at once.

  Replaces the older `/dashboard/settings`, which tied the account UI to the
  user dashboard that hosts can compile out (`user_dashboard_enabled`).

  The override is validated as a local path when saved and re-guarded here on
  read — same `usable_candidate?/1` check as `main_page_path/0` and
  `after_login_path` — so a hand-edited DB row cannot turn a menu entry into
  an off-site link, or into `/users/log-out`, silently converting every
  "Settings" link into a sign-out link. An override names the host's own
  page in **served form** — the shape a browser actually requests, e.g.
  `/crm/settings`, or `/phoenix_kit/profile/settings` for core's own page
  reached through a mount prefix — and gets only a locale segment inserted
  into it, via `localize_served_path/2`, so it moves with the visitor's
  language exactly like `/profile/settings` does. It does NOT go through
  `path/2`: that function's job is to build a served path FROM a canonical
  one by adding both the mount prefix and the locale, and an override is
  already served — running it through `path/2` a second time would add the
  mount prefix again, in front of a path that may not even be mounted under
  it (a host page is normally reached at its own root, not underneath
  `url_prefix`).

  ## Options

    * `:locale` — locale segment for the built-in path, as `path/2` takes it.
      Applied to an override too, via `localize_served_path/2`.

  ## Examples

      iex> PhoenixKit.Utils.Routes.user_settings_path()
      "/phoenix_kit/profile/settings"

  """
  @spec user_settings_path(keyword()) :: String.t()
  def user_settings_path(opts \\ []) do
    case setting_candidate("user_settings_path") do
      nil ->
        path("/profile/settings", opts)

      value ->
        if usable_candidate?(value),
          do: localize_served_path(value, opts),
          else: path("/profile/settings", opts)
    end
  end

  @doc """
  Inserts a locale segment into an already-served path, without touching
  `url_prefix`.

  For a path a host administrator typed in — an override setting, not
  something core builds from a canonical `/foo` via `path/2`. Such a path is
  already in served form: it might sit under core's mount prefix (an
  operator pointed the setting back at one of core's own pages) or it might
  not (the common case — a page the HOST serves at its own root). `path/2`
  cannot tell those apart; it always adds `url_prefix`, which is correct for
  a canonical path and wrong for a served one — pointing `user_settings_path`
  at a host's `/crm/settings` used to come back as
  `/phoenix_kit/en/crm/settings`, nesting the host's own page under core's
  mount point.

  This inserts *only* the locale segment, and only where it is safe to:

    * If `served_path` starts with `url_prefix`, the segment goes right after
      it — the same position `path/2` would put it in for a canonical path,
      so an override pointed back at one of core's own pages (e.g.
      `/phoenix_kit/profile/settings`) localizes identically to the default.
    * Otherwise the segment goes at the very front. `url_prefix` is never
      added — the path is the host's own, mounted independently of core.
    * A `served_path` whose relevant leading segment already matches an
      enabled locale code is returned unchanged, so re-running this on an
      already-localized override (or switching locales without re-reading
      the setting) cannot stack segments.
    * The default locale on a `default_language_no_prefix: true` site is
      never inserted, matching `path/2`'s own primary-prefixless rule.

  `opts` takes `:locale` exactly as `path/2` does.
  """
  @spec localize_served_path(String.t(), keyword()) :: String.t()
  def localize_served_path(served_path, opts \\ []) when is_binary(served_path) do
    case resolve_locale(opts) do
      :none -> served_path
      locale -> insert_locale_segment(served_path, locale)
    end
  end

  defp insert_locale_segment(served_path, locale) do
    if default_locale?(locale) and prefixless_primary?() do
      served_path
    else
      {prefix, rest} = split_served_prefix(served_path)

      if served_locale_segment?(rest) do
        served_path
      else
        prefix <> locale_prefixed_path("", locale, if(rest == "", do: "/", else: rest))
      end
    end
  end

  # Mirrors `strip_url_prefix/1`, but returns the split pair instead of just
  # the remainder — `insert_locale_segment/2` needs the prefix back to put it
  # ahead of the locale segment it inserts.
  defp split_served_prefix(served_path) do
    prefix = Config.get_url_prefix()

    cond do
      prefix in ["", "/"] ->
        {"", served_path}

      served_path == prefix ->
        {prefix, ""}

      String.starts_with?(served_path, prefix <> "/") ->
        {prefix, String.replace_prefix(served_path, prefix, "")}

      true ->
        {"", served_path}
    end
  end

  # Whether the leading segment of a served path (after `url_prefix` has been
  # split off) is already a locale this site recognises. Deliberately the
  # enabled set. An explicit current locale is only added when switching away
  # from a page whose locale may have since been disabled.
  defp served_locale_segment?(rest_path) do
    case String.split(rest_path, "/", parts: 3) do
      ["", segment | _] -> segment in enabled_locale_codes_with_base()
      _ -> false
    end
  end

  defp enabled_locale_codes_with_base do
    codes =
      if Code.ensure_loaded?(Languages) and
           function_exported?(Languages, :enabled_locale_codes, 0) do
        Languages.enabled_locale_codes()
      else
        []
      end

    codes
    |> Enum.flat_map(fn code -> [code, DialectMapper.extract_base(code)] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  `user_settings_path/1` with the locale taken from `assigns`.

  Same relationship to `user_settings_path/1` as `locale_aware_path/2` has to
  `path/2` — for templates that hold the current locale in assigns rather than
  a keyword list.
  """
  @spec locale_aware_user_settings_path(map()) :: String.t()
  def locale_aware_user_settings_path(assigns) do
    locale =
      assigns[:current_locale_base] ||
        DialectMapper.extract_base(assigns[:current_locale] || @default_locale)

    user_settings_path(locale: locale)
  end

  @doc """
  The current page's path, under a different locale.

  What the language switcher links to. Strips whatever locale segment the path
  already carries and rebuilds it for `locale`, so switching twice cannot stack
  prefixes.

  ## The bug this replaces

  Three near-copies of this lived in `AdminNav`, `LayoutWrapper` and
  `UserDashboardNav`, and each decided differently which leading segment counted
  as a locale worth removing:

    * two of them tested membership of an *enabled-codes* list, while the
      dropdown beside them was populated from `get_display_languages/0` — a
      strictly larger set. Any language the switcher offered but the module had
      not enabled was therefore not recognised on the way back out: from
      `/phoenix_kit/ja/admin`, switching to English produced
      `/phoenix_kit/en/ja/admin`, which routes nowhere.
    * the third matched by shape (a 2-character segment, or 5 with a dash),
      which strips `ja` correctly but would also eat an unrelated two-letter
      path segment and misses 3-letter codes entirely.

  The set used here is the site's enabled locale codes, including their base
  codes, plus an explicitly supplied `:current_locale`. Preview defaults and
  disabled languages are excluded: a host path such as `/nl/products` keeps
  its first segment when Dutch is not served by the site.

  ## Options

    * `:current_locale` — the locale the page is being viewed in. Included in
      the strip set, so an active locale is removed even if it has since been
      disabled.
  """
  @spec locale_switch_path(String.t() | nil, String.t(), keyword()) :: String.t()
  def locale_switch_path(current_path, locale, opts \\ []) do
    base = DialectMapper.extract_base(locale)

    url_prefix = Config.get_url_prefix()
    prefix = if url_prefix == "/", do: "", else: url_prefix

    (current_path || "")
    |> String.replace_prefix(prefix, "")
    |> strip_locale_segment(opts[:current_locale])
    |> path(locale: base)
  end

  # Drop a leading locale segment, leaving "/" when it was the whole path.
  defp strip_locale_segment(path, current_locale) do
    known = switchable_locale_codes(current_locale)

    case String.split(path, "/", parts: 3) do
      ["", segment, rest] -> if segment in known, do: "/" <> rest, else: nonempty(path)
      ["", segment] -> if segment in known, do: "/", else: nonempty(path)
      _ -> nonempty(path)
    end
  end

  defp nonempty(""), do: "/"
  defp nonempty(path), do: path

  # Only served locales, plus the page's explicit locale to handle stale links.
  defp switchable_locale_codes(current_locale) do
    (enabled_locale_codes_with_base() ++ List.wrap(current_locale))
    |> Enum.flat_map(fn code -> [code, DialectMapper.extract_base(code)] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  Whether `path` actually resolves to a `GET` route in the application's router.

  The router is taken from the request: `conn.private[:phoenix_router]`, set by
  the generated router before dispatch, or `socket.router`, set when the
  LiveView is mounted at the router.

  **When the router cannot be determined this returns `false`.** The two failure
  modes are asymmetric: emitting an unverified path is the 404 this whole
  mechanism exists to eliminate, while skipping the candidate merely falls
  through to a core-owned page that is guaranteed to exist.
  """
  @spec routable?(request_context(), term()) :: boolean()
  def routable?(context, path) when is_binary(path) do
    case router_for(context) do
      nil ->
        false

      router ->
        Phoenix.Router.route_info(router, "GET", path_only(path), host_for(context)) != :error
    end
  rescue
    # A router module that isn't loaded under a release, or a malformed path.
    _ -> false
  catch
    :exit, _ -> false
  end

  def routable?(_context, _path), do: false

  defp router_for(%Plug.Conn{private: private}), do: Map.get(private, :phoenix_router)
  defp router_for(%Phoenix.LiveView.Socket{router: router}), do: router
  defp router_for(_), do: nil

  defp host_for(%Plug.Conn{host: host}) when is_binary(host), do: host

  defp host_for(%Phoenix.LiveView.Socket{host_uri: %URI{host: host}}) when is_binary(host),
    do: host

  # `socket.host_uri` is the atom `:not_mounted_at_router` outside a router, and
  # routes without a `host:` constraint match any host anyway.
  defp host_for(_), do: "localhost"

  # `route_info/4` matches path SEGMENTS, so "/foo?x=1" would be probed as the
  # single segment "foo?x=1" and never match. Same normalisation `auth_page?/1`
  # applies.
  defp path_only(path), do: path |> String.split(["?", "#"], parts: 2) |> hd()

  @doc """
  Renders `?return_to=<path>` for a link, or `""` when there is nothing safe to
  carry. Lets the auth pages hand the pending destination to each other instead
  of dropping it the moment a visitor switches to another sign-in method.
  """
  @spec return_to_query(term()) :: String.t()
  def return_to_query(path) do
    if local_path?(path), do: "?" <> URI.encode_query(%{"return_to" => path}), else: ""
  end

  # Every path that bounces an authenticated visitor elsewhere, plus log-out.
  # Setting the post-login destination to any of them loops forever; pointing
  # it at `/users/log-out` is worse — it is a real GET route, so every
  # successful login immediately signs the user back out and nobody, including
  # the admin who set it, can stay in to undo it.
  # `/users/referral` belongs here for the same reason `/users/confirm` does:
  # the invite-only gate parks users there and stashes where they came from, so
  # without it a stashed `return_to` could send an admitted user straight back
  # to the page that had just released them.
  @auth_paths ~w(/users/log-in /users/log-out /users/register /users/confirm
  /users/referral /users/magic-link /users/qr-login /users/reset-password)

  # The configured post-login landing, or `nil` when unset or unusable. `nil`
  # rather than `"/"`: the caller decides what an unset setting falls back to,
  # and `post_auth_path/2` can only probe `"/"` if it can tell "the
  # administrator chose the home page" apart from "nobody chose anything".
  #
  # `"/"` is explicitly excluded here even though it is a usable local path,
  # for the same reason main_page_path/0 returns nil rather than "/": it is
  # the synthesized core default written back into the row on every settings
  # save, not a deliberate administrator choice. Treating it as a configured
  # value causes `home_after_auth/1` to return it immediately, bypassing
  # `home_or_core_landing/2` — the only place that probes routability against
  # the host's router. On a host with no root route, post_auth_path/2 would
  # then return "/" and every post-login redirect 404s: the exact defect this
  # module exists to prevent. An explicit non-default path (e.g. "/welcome")
  # is still honoured verbatim — it names a page in the host application.
  defp after_login_setting do
    case setting_candidate("after_login_path") do
      nil -> nil
      "/" -> nil
      value -> if usable_candidate?(value), do: value
    end
  end

  @doc """
  Whether a path lands on one of the sign-in pages (or `/users/log-out`).

  Public because the `after_login_path` / `after_registration_path` changeset
  applies the same rule when the setting is saved — one list, one predicate, so
  a new auth route can't be guarded on read and forgotten on write.

  Suffix-matched, since the real URL carries the host's mount prefix and an
  optional locale segment (`/app/et/users/log-in`). A host page whose own path
  happens to end in one of these segments is refused too — over-strict rather
  than allowing a redirect loop.

  ## Examples

      iex> PhoenixKit.Utils.Routes.auth_page?("/users/log-in")
      true
      iex> PhoenixKit.Utils.Routes.auth_page?("/et/users/log-out/")
      true
      iex> PhoenixKit.Utils.Routes.auth_page?("/dashboard")
      false

  """
  @spec auth_page?(term()) :: boolean()
  def auth_page?(path) when is_binary(path) do
    trimmed = path |> String.split(["?", "#"], parts: 2) |> hd() |> String.trim_trailing("/")
    Enum.any?(@auth_paths, &(trimmed == &1 or String.ends_with?(trimmed, &1)))
  end

  def auth_page?(_), do: false

  @doc """
  Builds a PhoenixKit path: the host's mount prefix, plus a locale segment when
  the site is multilingual.

  ## The `:locale` option

  This is the contract, and it is what a bilingual site needs when auth pages
  come out in the wrong language. Without it the locale is *determined* — from
  the process's Gettext locale — which is right for a link rendered inside a
  request and wrong for a link built outside one (an email, a background job, a
  script).

  - `locale: "et"` — force this locale.
  - `locale: :none` — emit no locale segment at all. For anything that is not a
    page: assets, webhooks, `sitemap.xml`.
  - `locale: nil` or omitted — determine it from the current process.

  ### Examples

      Routes.path("/users/log-in")                 # current locale
      Routes.path("/users/log-in", locale: "et")   # /et/users/log-in
      Routes.path("/sitemap.xml", locale: :none)   # never localized

  Note that the primary language is emitted prefixlessly when the site is
  configured that way, so `locale: "en"` on an English-primary site yields a
  path with no `/en` segment — that is deliberate, not a dropped option.

  See the multilang guide for how locales are resolved and switched; the symptom
  of getting this wrong (English auth pages on a translated site) reads like an
  i18n bug rather than a routing one.
  """
  # NOTE: Locale override logic below exists for the publishing component system integration.
  # Switch to the upcoming media/storage helpers once they land.
  def path(url_path, opts \\ [])

  def path("/" <> _ = url_path, opts) do
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_path = if url_prefix === "/", do: "", else: url_prefix

    cond do
      # Admin paths follow the same primary-prefixless rule as non-admin
      # paths (see `build_admin_path/3`). The dual-scope router emission
      # keeps `/phoenix_kit/admin/*` AND `/phoenix_kit/:locale/admin/*`
      # both reachable, so the emitted shape is purely cosmetic.
      admin_path?(url_path) ->
        locale = resolve_locale(opts)
        build_admin_path(base_path, apply_admin_segment(url_path), locale)

      # Reserved paths (API, webhooks, assets) NEVER get a locale prefix.
      reserved_path?(url_path) ->
        "#{base_path}#{url_path}"

      true ->
        build_localized_path(base_path, url_path, opts)
    end
  end

  def path(_url_path, _opts) do
    raise """
    Url path must start with "/".
    """
  end

  defp build_localized_path(base_path, url_path, opts) do
    locale = resolve_locale(opts)
    build_path_with_locale(base_path, url_path, locale)
  end

  defp resolve_locale(opts) do
    case Keyword.fetch(opts, :locale) do
      {:ok, :none} -> :none
      {:ok, nil} -> determine_locale()
      {:ok, locale_value} -> locale_value
      :error -> determine_locale()
    end
  end

  defp build_path_with_locale(base_path, url_path, :none), do: "#{base_path}#{url_path}"

  defp build_path_with_locale(base_path, url_path, locale_value) do
    if default_locale?(locale_value) and prefixless_primary?() do
      "#{base_path}#{url_path}"
    else
      locale_prefixed_path(base_path, locale_value, url_path)
    end
  end

  # Builds a locale-prefixed URL (`/{locale}{url_path}`).
  #
  # The bare root (`url_path == "/"`) is special-cased to emit
  # `/{locale}` rather than `/{locale}/`: Phoenix routers do not match a
  # trailing slash, so a `/:locale` landing route declared by the parent
  # app would 404 on `/{locale}/`. Every other path keeps its leading
  # slash, so the concatenation is already correct.
  defp locale_prefixed_path(base_path, locale, "/"), do: "#{base_path}/#{locale}"
  defp locale_prefixed_path(base_path, locale, url_path), do: "#{base_path}/#{locale}#{url_path}"

  # Whether a CANONICAL path names the admin area.
  #
  # Segment-aware on purpose: a plain `String.starts_with?(url_path, "/admin")`
  # also claimed `/administrators`, and once `apply_admin_segment/1` started
  # rewriting the prefix that stopped being a cosmetic mismatch — it would have
  # turned `/administrators` into `/backofficeistrators`.
  defp admin_path?(url_path), do: admin_prefix_length(url_path) != nil

  # Length of the leading `/admin` segment, or nil when the path does not have
  # one. `?`/`#` count as boundaries so a path carrying a query or fragment
  # (`/admin?tab=1`) is still recognised.
  defp admin_prefix_length("/admin"), do: 6

  defp admin_prefix_length("/admin" <> rest) do
    if String.starts_with?(rest, ["/", "?", "#"]), do: 6, else: nil
  end

  defp admin_prefix_length(_url_path), do: nil

  @doc """
  The configured top-level segment of the admin area — `"/admin"` by default.

  See `PhoenixKit.Config.get_admin_path/0` for why `/admin` remains the name
  used in code regardless of what this returns.
  """
  @spec admin_segment() :: String.t()
  def admin_segment, do: Config.get_admin_path()

  @doc """
  Rewrites a canonical `/admin...` path onto the configured segment.

  The **emit** half of the rename. Every URL core hands out goes through here,
  via `path/2` or `admin_path/2`; the router's own route table gets the same
  substitution at compile time in `PhoenixKitWeb.Integration`.

  A no-op on the default configuration, and on any path that is not an admin
  path — including one that has already been rewritten, so applying it twice is
  safe.

  ## Examples

      iex> PhoenixKit.Utils.Routes.apply_admin_segment("/admin/users")
      "/admin/users"

      iex> PhoenixKit.Utils.Routes.apply_admin_segment("/users/log-in")
      "/users/log-in"

  """
  @spec apply_admin_segment(String.t()) :: String.t()
  def apply_admin_segment(url_path) when is_binary(url_path) do
    segment = Config.get_admin_path()

    if segment == "/admin" do
      url_path
    else
      case admin_prefix_length(url_path) do
        nil -> url_path
        len -> segment <> binary_slice(url_path, len..-1//1)
      end
    end
  end

  @doc """
  Rewrites a real `/<configured segment>...` path back to canonical `/admin...`.

  The **read** half of the rename, and the exact inverse of
  `apply_admin_segment/1`. Anything that compares an incoming request path
  against a path written in code — tab active state, the admin nav's parser,
  the language switcher — canonicalises first so the comparison is between two
  values spelled the same way.

  Expects the URL prefix and any locale segment to have been stripped already;
  it only looks at the leading segment.

  ## Examples

      iex> PhoenixKit.Utils.Routes.canonical_admin_path("/admin/users")
      "/admin/users"

  """
  @spec canonical_admin_path(String.t()) :: String.t()
  def canonical_admin_path(url_path) when is_binary(url_path) do
    segment = Config.get_admin_path()

    if segment == "/admin" do
      url_path
    else
      rest = String.replace_prefix(url_path, segment, "")

      if rest != url_path and (rest == "" or String.starts_with?(rest, ["/", "?", "#"])) do
        "/admin" <> rest
      else
        url_path
      end
    end
  end

  def canonical_admin_path(url_path), do: url_path

  # Admin paths follow the same primary-prefix rule as non-admin paths.
  # Both URL shapes (`/admin/*` and `/:locale/admin/*`) are emitted by the
  # admin route macros so either shape is routable; the choice between
  # them is the cosmetic site-wide setting controlled via
  # `Languages.default_language_no_prefix?/0`.
  #
  # The two shapes share one `live_session :phoenix_kit_admin`, so
  # switching locales inside admin stays on the WebSocket
  # (`push_navigate`) — no full-page reload. See `generate_admin_routes/2`
  # in `PhoenixKitWeb.Integration`.
  defp build_admin_path(base_path, url_path, :none), do: "#{base_path}#{url_path}"

  defp build_admin_path(base_path, url_path, locale) when is_binary(locale) do
    if default_locale?(locale) and prefixless_primary?() do
      "#{base_path}#{url_path}"
    else
      "#{base_path}/#{locale}#{url_path}"
    end
  end

  defp build_admin_path(base_path, url_path, _), do: "#{base_path}#{url_path}"

  # Reads the site-wide setting controlled by the Languages admin page.
  # Defers to the canonical boot-safe wrapper on `Languages` so all
  # URL-emission call sites (this module + `Users.Auth`) share one
  # rescue policy.
  defp prefixless_primary?, do: Languages.prefixless_primary_safe?()

  # Check if a path starts with one of the reserved prefixes.
  defp reserved_path?(path) do
    Enum.any?(@reserved_prefixes, &String.starts_with?(path, &1))
  end

  defp determine_locale do
    # Fall back to extracting base from Gettext locale
    # This is only used when locale is not explicitly passed to Routes.path
    # Gettext.get_locale/1 always returns a string
    locale = Gettext.get_locale(PhoenixKitWeb.Gettext)
    DialectMapper.extract_base(locale)
  end

  # Check if the given locale is the default language
  # Default locale doesn't need a prefix in URLs for cleaner URLs
  defp default_locale?(locale) do
    default = get_default_language_base()
    locale == default
  end

  defp get_default_language_base do
    # During mix tasks (like phoenix_kit.install), the database may not have
    # the settings table yet. We detect this by checking if we're in a mix task
    # context and fall back to "en" to avoid database errors.
    if mix_task_context?() do
      "en"
    else
      case Languages.get_default_language() do
        %{code: code} when is_binary(code) -> DialectMapper.extract_base(code)
        _ -> "en"
      end
    end
  rescue
    _ -> "en"
  catch
    # A connection-pool failure EXITS rather than raising, so `rescue` alone
    # never delivered the "path building works without a reachable database"
    # guarantee above. Seen as a flaky suite failure: the settings read is
    # ETS-cached, so a DB-less test only reached the pool on a cache miss —
    # which another test's settings write could cause at any time.
    :exit, _ -> "en"
  end

  # Detect if we're running in a mix task context where the database
  # may not be fully set up yet
  defp mix_task_context? do
    # Check if Mix is loaded and we're not in a running application context
    # The settings cache being unavailable is a reliable indicator
    case Process.get(:phoenix_kit_config_status) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Returns a locale-aware admin path. For non-primary locales the locale
  segment is always emitted. For the primary locale the shape follows
  the site-wide `default_language_no_prefix` setting
  (`Languages.default_language_no_prefix?/0`): prefixless when the
  setting is on, prefixed when off.

  Both URL shapes resolve at the router level — the admin route macros
  declare `/:locale/admin/*` AND `/admin/*` scopes — so either shape is
  routable. The two shapes share one `live_session :phoenix_kit_admin`,
  so locale switching across them stays on the WebSocket
  (`push_navigate`) without a full-page reload.

  ## Examples

      iex> Routes.admin_path("/admin/users", "uk")
      "/phoenix_kit/uk/admin/users"

      iex> Routes.admin_path("/admin/users", nil)
      "/phoenix_kit/admin/users"

  Primary-locale shape depends on the `default_language_no_prefix`
  setting (not shown as doctests because the result varies with
  runtime state):

      # setting OFF (default)
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/en/admin/users"

      # setting ON
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/admin/users"

  """
  def admin_path(url_path, locale) when is_binary(locale) do
    url_prefix = Config.get_url_prefix()
    base_prefix = if url_prefix == "/", do: "", else: url_prefix
    url_path = apply_admin_segment(url_path)

    if default_locale?(locale) and prefixless_primary?() do
      "#{base_prefix}#{url_path}"
    else
      "#{base_prefix}/#{locale}#{url_path}"
    end
  end

  def admin_path(url_path, _locale), do: path(url_path)

  @doc """
  Returns a locale-aware path using locale from assigns.

  This function is specifically designed for use in component templates
  where the locale needs to be passed explicitly via assigns.

  Prefers base locale code for URL generation (current_locale_base),
  falls back to extracting base from full dialect code (current_locale).
  """
  def locale_aware_path(assigns, url_path) do
    # Prefer base code, fall back to extracting from full dialect
    locale =
      assigns[:current_locale_base] ||
        DialectMapper.extract_base(assigns[:current_locale] || @default_locale)

    path(url_path, locale: locale)
  end

  @doc """
  `home_path/2` with the locale taken from `assigns` — the same relationship
  `locale_aware_path/2` has to `path/2`.
  """
  @spec locale_aware_home_path(map(), request_context()) :: String.t()
  def locale_aware_home_path(assigns, context) do
    locale =
      assigns[:current_locale_base] ||
        DialectMapper.extract_base(assigns[:current_locale] || @default_locale)

    home_path(context, locale)
  end

  @doc """
  Returns the default locale (base code) from the Languages module.

  Extracts the base code from the default language (e.g., "en-US" becomes "en").
  Falls back to "en" if no default language is configured.

  ## Examples

      iex> Routes.get_default_admin_locale()
      "en"
  """
  def get_default_admin_locale do
    get_default_language_base()
  end

  @doc """
  Returns a full url with preconfigured prefix.

  This function first checks for a configured site URL in Settings,
  then automatically detects the correct URL from the running Phoenix
  application endpoint when possible, falling back to static configuration.
  This ensures that magic links and other email links work correctly in both
  development and production environments, with full control over the base URL
  through the Settings admin panel.
  """
  def url(url_path) do
    base_url = get_base_url_for_emails()
    full_path = path(url_path)

    normalized_base = String.trim_trailing(base_url, "/")
    "#{normalized_base}#{full_path}"
  end

  @doc """
  The bare base URL (scheme + host, no trailing slash), same source `url/1` uses.

  For absolutizing a path that is **already** url-prefixed and locale-prefixed
  (e.g. a notification's `link`, built via `path/1`) — concatenate it onto this
  directly. Do NOT pass such a path to `url/1`, which re-applies `path/1` and
  would double-prefix it.
  """
  @spec base_url() :: String.t()
  def base_url, do: String.trim_trailing(get_base_url_for_emails(), "/")

  # Gets the base URL for email links.
  #
  # Priority:
  # 1. site_url setting from Settings (if configured)
  # 2. Dynamic URL from Phoenix endpoint
  # 3. Static configuration fallback
  #
  # This allows administrators to override the email link URLs through
  # the Settings panel, which is especially useful in production.
  defp get_base_url_for_emails do
    case PhoenixKit.Settings.get_setting("site_url", "") do
      "" ->
        PhoenixKit.Config.get_dynamic_base_url()

      site_url when is_binary(site_url) ->
        site_url
    end
  end

  @doc """
  Gets the base module name for the parent application.

  Reads from :phoenix_kit, :layouts_module config (e.g., MprojectWeb.Layouts -> MprojectWeb).

  ## Examples

      iex> PhoenixKit.Utils.Routes.phoenix_kit_app_base()
      "MprojectWeb"

  """
  @spec phoenix_kit_app_base() :: String.t()
  def phoenix_kit_app_base do
    case PhoenixKit.Config.get(:layouts_module) do
      {:ok, module} when is_atom(module) ->
        module
        |> Module.split()
        # Drop last segment (Layouts)
        |> Enum.slice(0..-2//1)
        |> Module.concat()

      _ ->
        "AppWeb"
    end
  end
end
