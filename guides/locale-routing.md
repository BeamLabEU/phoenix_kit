# Locale Routing: the Language Lives in the URL

PhoenixKit serves each language of a page at its own URL — `/et/products`,
`/ru/products` — and sets the page language from that URL on every
navigation. The default language may be served without a prefix when the site
is configured that way. **A session-based language is not supported, on
purpose.** This guide explains why, and how to move a session-locale app onto
the supported shape.

If you arrived here because the language switcher's links "don't work", this
is almost certainly the cause: the page is showing a language its URL does not
carry. In development the switcher logs a warning that points here.

## Single-language sites

With multi-language support off (Admin → Settings → Languages, the first
card), the site is single-language and **no URL carries a locale segment** —
`/cart`, `/users/log-in`, `/admin`, never `/en/cart`. There is nothing to
switch to, so a segment would mean nothing. The site's language is its
**primary language**, set on the same page ("Primary language & URLs", shown
whether the switch is on or off; Settings → General links to it). Unset, it is
`config :phoenix_kit, default_locale` (default `"en-US"`), read at runtime.

Kit routes redirect (302) a request carrying a locale segment to the same path
without it — old `/en/...` links keep working. An admin URL renders as-is under
the primary language, since both admin shapes route.

What this means for a host:

- **The segment-less route must exist.** The redirect's target is the same
  path without the segment (`/products`), so a host that only declares
  `/:locale/products` — and reaches it through `Routes.path/2` — has nothing to
  land on. Declare the unprefixed route (see "Migrating a session-locale app"
  below for the two-scope shape) or turn multi-language support on.
- **Link builders stop emitting the segment.** `Routes.path/2`,
  `Routes.locale_aware_path/2`, `Routes.home_path/2`, `Routes.admin_path/2` and
  `Routes.localize_served_path/2` return the path without it, for any locale
  — including an explicit `locale: "et"`.
- **`:default_locale_redirect` covers this redirect too.** A host that opted
  into 301/308 for the default-locale redirect gets it for the single-language
  one (GET and HEAD); other methods always get a 307.

That redirect is done by the kit's locale plug, so it covers the kit's own
routes only. **A host that declares its own `scope "/:locale"` routes** must
either turn multi-language support on (the supported shape for a site served in
several languages) or drop the segment itself. On a single-language site it can
reuse the kit's plug for that — put the scope behind the kit's locale pipeline:

```elixir
scope "/:locale", MyAppWeb do
  pipe_through [:browser, :phoenix_kit_locale_validation]
  live "/products", ProductLive.Index
end
```

`phoenix_kit_routes()` defines that pipeline, so the scope goes after the
call. The plug reads `path_params["locale"]` and redirects `/<code>/products`
to `/products`; with multi-language support on it validates the code instead,
as it does for the kit's own routes. Two limits:

- It looks for the segment right after the kit's `url_prefix`. With
  `url_prefix: "/"` that is any host scope's first segment; under
  `url_prefix: "/phoenix_kit"` a host `/:locale` scope is not found, and the
  page renders under the primary language without a redirect.
- It treats whatever binds `:locale` as a locale, so reuse it only on a scope
  whose first segment is always one.

A multilingual site is unaffected: the primary language is prefixless only
when "Primary language without prefix" is on, and every other language keeps
its prefix. The first time multi-language support is switched on, that setting
is turned on (unless it was ever saved), so a site that was single-language
keeps its clean URLs.

## Why the URL, not the session

- **A link must mean one thing.** Someone sends a link to a colleague; the
  colleague must see the same language. With a session language the same URL
  shows different content to different people.
- **Search engines index URLs.** `hreflang` and canonical links point at URLs,
  and crawlers send no cookies. A page whose language comes from the session is
  indexed in one language for everyone. Google's own guidance is to use a
  distinct URL per language rather than cookies or browser settings.
- **Caches and CDNs key on the URL.** A session-varying page is either
  uncacheable or served in the wrong language.
- **Link previews fetch without cookies.** Chat apps and social cards would
  always show the default language.
- **PhoenixKit tried it.** A session fallback once existed and was removed
  after it overrode the language of URLs people had been sent.

The invariant is *a distinct, stable URL per language*. A subdomain per
language satisfies it just as well as a path segment.

## Migrating a session-locale app

1. **Put the locale in your routes.** Wrap the localized pages in a locale
   scope, next to the unprefixed one if your default language is prefixless:

   ```elixir
   scope "/", MyAppWeb do
     pipe_through :browser
     live "/products", ProductLive.Index   # default language
   end

   scope "/:locale", MyAppWeb do
     pipe_through :browser
     live "/products", ProductLive.Index   # every other language
   end
   ```

2. **Build links with the kit's helpers**, so they keep the current language:

   ```elixir
   PhoenixKit.Utils.Routes.path("/products")
   PhoenixKit.Utils.Routes.path("/products", locale: "et")
   ```

3. **Stop reading the language from the session** when rendering a page. Let
   the URL decide; PhoenixKit's `on_mount` hooks set Gettext from it.

4. **Keep the preference for the landing page only.** A saved preference or a
   cookie may choose where a bare `/` goes:

   ```elixir
   def home(conn, _params) do
     locale = get_session(conn, :preferred_locale) || "en"
     redirect(conn, to: PhoenixKit.Utils.Routes.path("/", locale: locale))
   end
   ```

   PhoenixKit does the same after sign-in: when the sign-in page's address
   named no language, the redirect goes to the person's saved one. And a person
   who registers or signs in on a page in another language than the site's gets
   that language saved, if they had none.

   Once a URL carries a locale, the URL wins — never consult the preference on
   a URL that already has one. (That is exactly the bug the removed session
   fallback had.) If the redirect depends on the visitor, don't let a shared
   cache store it.

5. **Switching language is navigation.** The switcher links to the same page
   under the other locale. If you need your own switcher markup, build the
   links with `PhoenixKitWeb.Components.Core.LanguageSwitcher.locale_path/2`,
   which returns exactly what the component renders.

## What is deliberately not offered

- A "session locale mode".
- A switcher hook that can produce the same URL for every language.

Both would make PhoenixKit carry two routing models, and every URL it builds
— email links, sitemaps, social cards — would have to support both.

## Host locale routes

A host can serve its own pages under the languages the kit serves, with the
kit's Languages settings (Admin → Settings → Languages) as the one list:
`PhoenixKitWeb.Plugs.HostLocale` validates the segment, and `PhoenixKit.I18n`
builds the links. All of it is opt-in; the kit never mounts a `/:locale` scope
for the host.

### The router

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import PhoenixKitWeb.Integration

  pipeline :host_locale do
    plug PhoenixKitWeb.Plugs.HostLocale, gettext: MyAppWeb.Gettext
  end

  # 1. Everything with a fixed first segment comes first.
  scope "/", MyAppWeb do
    pipe_through :browser
    get "/health", HealthController, :show
  end

  phoenix_kit_routes()

  # 2. The localized pages come last.
  scope "/", MyAppWeb do
    pipe_through [:browser, :host_locale]

    live_session :localized,
      on_mount: [{PhoenixKitWeb.Plugs.HostLocale, gettext: MyAppWeb.Gettext}] do
      # The primary language, when the site serves it without a segment
      live "/", HomeLive
      live "/products/:slug", ProductLive.Show

      # Every language that carries a segment
      scope "/:locale" do
        live "/", HomeLive
        live "/products/:slug", ProductLive.Show
      end
    end
  end
end
```

The plug and the hook take the same options: `param:` (default `"locale"`),
`on_unknown: :not_found | :primary`, `on_primary_segment: :redirect | :serve`
(plug only) and `gettext:` (the host's backends to set too).

What a request gets:

| Request | Answer |
|---|---|
| `/et/products/x`, Estonian served | rendered in Estonian; Gettext, `@current_locale` (`"et"` or `"et-EE"`, as configured), `@current_locale_base`, `@current_language` set |
| `/products/x` | the primary language |
| `/en/products/x`, English is the prefixless primary | 302 to `/products/x` (`on_primary_segment: :serve` renders it) |
| `/ET/products/x`, `/en-US/products/x` | 302 to the canonical segment (307 for a POST) |
| `/de/products/x`, German not served | 404 (`HostLocale.NotFoundError`, rendered by the host's error view); `on_unknown: :primary` renders the primary language instead |

On a single-language site (multi-language support off) the primary is the
only language and is always prefixless, so `/:locale` URLs either redirect to
the clean path (the primary's own code) or 404.

### ⚠️ The scope-ordering trap

Phoenix matches routes in the order they are declared, and `:locale` matches
any segment. A wide localized scope declared **before** `phoenix_kit_routes()`
or a fixed-prefix scope takes those paths for itself:

```elixir
# WRONG — "/:locale" is first, so "/admin" is HomeLive with locale "admin",
# and "/assets/app.css" is a page with locale "assets"
scope "/:locale", MyAppWeb do
  pipe_through [:browser, :host_locale]
  live "/", HomeLive
  live "/*path", PageLive
end

phoenix_kit_routes()
```

With `HostLocale` in front the mistake shows up as a 404 on `/admin` rather
than as a page rendered in a language called "admin", and the plug logs a
warning naming this section the first time a kit path (the admin segment, the
kit's `url_prefix`, `assets`, `api`, …) is captured. The fix is always the
order: fixed-prefix scopes and `phoenix_kit_routes()` first, the `/:locale`
scope last. Static files are served by the endpoint before the router, so
only a path `Plug.Static` does not cover (a missing file) reaches the router —
another reason to keep the catch-all last.

Do not reuse `:phoenix_kit_locale_validation` for these scopes: that pipeline
looks for the segment right after the kit's `url_prefix` and redirects unknown
codes, where `HostLocale` reads the route's own `:locale` and answers 404.

### Links, hreflang and the switcher

The kit does not guess how a host's URL is shaped. Every builder takes the
host's function — called with the language's URL segment, or `nil` for a
prefixless primary — or names a strategy explicitly:

```elixir
url = fn
  nil -> ~p"/products/#{product.slug}"
  locale -> ~p"/#{locale}/products/#{product.slug}"
end

PhoenixKit.I18n.enabled_locales()                       # ["en", "et", "ru"]
PhoenixKit.I18n.localized_url(socket, "et", url: url)   # "/et/products/tool"
PhoenixKit.I18n.hreflang_links(socket, url: url)        # [%{hreflang: "en", href: "https://…"}, …, x-default]
PhoenixKit.I18n.language_links(socket, url: url)        # [%{code, name, native_name, url, current?, …}]

# The current page with its leading segment replaced (same path in every language)
PhoenixKit.I18n.language_links(socket, strategy: :path)
# ?locale=et instead of a path segment
PhoenixKit.I18n.language_links(socket, strategy: :query)
```

A per-language slug (`/et/tooted/…`, `/ru/produkty/…`) is exactly why the
builder is the host's: look the slug up inside the function.

In templates:

```heex
<%!-- root layout <head> --%>
<.hreflang_tags url={@locale_url} />

<%!-- the host's own switcher markup --%>
<.language_switcher_items :let={link} url={@locale_url} current_locale={@current_locale}
  class="flex gap-2">
  <.link navigate={link.url} class={link.current? && "font-bold"} hreflang={link.hreflang}>
    {link.native_name || link.name}
  </.link>
</.language_switcher_items>
```

Both components live in `PhoenixKitWeb.Components.Core.LanguageSwitcher`
(import it, or call them by module). `language_switcher_items` also takes an
`:item` slot, precomputed `links`, `strategy`, `hide_current` and `tag`
(default `nav`); with no slot it renders plain `<a>` links. The daisyUI
switchers (`language_switcher_dropdown` and friends) are unchanged.

`hreflang_links/2` returns the same `%{hreflang:, href:}` shape a sitemap
`UrlEntry`'s `alternates` uses, so a host sitemap source can pass it through.
Hrefs are absolute: a path is put on `:base_url` (default `Routes.base_url/0`,
the site URL the kit puts in emails); a builder that returns absolute URLs (a
domain per language) is used as is.
