defmodule PhoenixKitWeb.Live.Dashboard do
  @moduledoc """
  The `/admin` landing page.

  It is built to be the page ANY authenticated visitor can safely be sent to,
  whatever their permissions. Two halves:

    * a **welcome block**, rendered for everyone, greeting the visitor by name;
    * the **operator overview** (`PhoenixKitWeb.Components.Core.DashboardOverview`),
      every block of which is permission-gated by
      `PhoenixKitWeb.Live.Dashboard.Overview`.

  A visitor holding no permissions sees the welcome block and nothing else —
  no statistics, no System Information, no cards, and (because the overview
  decides before it queries) not one operator query or PubSub subscription on
  their behalf. That is what makes the page safe as a universal landing.

  Reaching it is not the same as being allowed to see all of it. The route sits
  in the ordinary admin `live_session`, alongside every other `/admin/*` page,
  so admin navigation to and from it stays a live patch rather than a full page
  reload. What admits a permission-less visitor is the GATE:
  `:phoenix_kit_ensure_admin` recognises this view via
  `PhoenixKitWeb.Users.Auth.landing_view?/1` and skips the admin-area and
  per-view permission checks for it alone — authentication, the account gate
  and the locale hook still run. The overview's own gates are what keep the
  operator blocks away from whoever gets in.

  Because nobody is ever evicted from this page, it has to survive a permission
  change in place: `PhoenixKitWeb.Users.Auth`'s scope-refresh hook skips its
  eviction for the landing view and instead calls
  `phoenix_kit_scope_changed/1`, which re-runs
  `PhoenixKitWeb.Live.Dashboard.Overview.assign_scope_gates/1`. A demoted
  operator watches the cards and statistics disappear (and the subscriptions
  behind them close) without leaving the page or reloading it.

  `/dashboard` is a SEPARATE page (`PhoenixKitWeb.Live.Dashboard.Index`),
  deprecated since 2026-07-27 and sharing nothing with this one.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext
  use PhoenixKitWeb.Live.Dashboard.Overview

  # These MUST sit immediately after `use Overview`, which injects its own
  # `handle_info/2` clause here — Elixir warns when one function's clauses are
  # not grouped, and `mix precommit` compiles with `--warnings-as-errors`. See
  # `Overview`'s moduledoc.
  #
  # The embedded admin-home view (an optional module's, rendered below) reports
  # whether it has a dashboard to show, so the built-in overview can hide and
  # come back LIVE as an administrator binds or unbinds one — rather than this
  # page deciding once at mount and needing a reload.
  # Deliberately NO catch-all below it: `Overview`'s guard names its ten tags
  # and nothing else precisely so the host keeps control of every other
  # message, and a test asserts that an unrelated one still raises rather than
  # being silently swallowed. The embedded home view runs in its own process
  # and sends only this one message, so nothing else arrives here.
  @impl true
  def handle_info({:admin_home, state}, socket) when state in [:shown, :empty] do
    {:noreply, assign(socket, :home_dashboard?, state == :shown)}
  end

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Values
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Dashboard.Overview

  # Greeting pools for the welcome block. One KEY is drawn per mount — the
  # visitor gets a different phrase each page load, but live updates to the
  # overview (PubSub-driven re-renders) never re-roll it mid-visit. Keys
  # resolve to text through `greeting_text/1` at RENDER time, so gettext
  # still follows a locale switch (see `welcome_block/1`).
  #
  # `mount/3` itself runs TWICE per page load (disconnected HTTP render, then
  # the connected websocket mount) — picking randomly in both would re-roll
  # the greeting out from under the visitor the instant the socket connects.
  # Only the connected pass draws; the disconnected pass gets the plain
  # default, same as every other visitor-specific value this page defers
  # until it can subscribe (see `Overview.assign_overview/3`).
  @generic_greetings ~w(welcome_back good_to_see_you hello_again hey_there glad_youre_here back_at_it)a

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, gettext("Dashboard"))
      |> assign(:greeting_key, greeting_key_for_mount(socket))
      # Every scope-derived assign on this page — `:can_access_admin_area?`
      # included — comes from `Overview.assign_scope_gates/1`, and from nowhere
      # else. That is what lets a mid-session permission change recompute all of
      # them at once: the scope-refresh hook calls the same function through the
      # `phoenix_kit_scope_changed/1` callback `use Overview` injects.
      |> Overview.assign_overview(session, Routes.path("/admin"))
      |> assign_home_view(session)

    {:ok, socket}
  end

  # The dashboards module, when installed AND enabled, may own this page. It is
  # resolved duck-typed — `Code.ensure_loaded?/1` before `function_exported?/3`,
  # since on a cold VM the latter answers false without loading the module — so
  # core keeps no dependency on an optional package and this page is unchanged
  # wherever that package is absent.
  #
  # `home_dashboard?` is answered UP FRONT, by asking the module's own
  # `admin_home_dashboards/1` for this viewer. The child view flips it later
  # too — that is what makes binding and unbinding a dashboard land live — but
  # it cannot be the FIRST answer: the child renders its board in the very same
  # pass, so a page that starts with "no dashboard" paints the board and the
  # built-in overview stacked together until the child's message arrives.
  defp assign_home_view(socket, session) do
    socket
    |> assign(:home_view, home_view())
    |> assign(:home_dashboard?, home_dashboard?(socket))
    |> assign(:home_session, %{
      "current_user_uuid" => Actor.uuid(socket),
      "locale" => session["locale"],
      "parent_pid" => self()
    })
  end

  defp home_view do
    module = PhoenixKitDashboards.Web.AdminHomeLive

    if Code.ensure_loaded?(module) and enabled_module?(PhoenixKitDashboards) do
      module
    end
  rescue
    _ -> nil
  end

  # Whether anything is bound to the home place FOR THIS VIEWER — audience
  # rules included, so a role-only board does not blank the overview for
  # everyone else. Resolved through the same duck-typed contract as the view
  # itself, and false on any failure: an optional module must never be able to
  # leave `/admin` with neither half rendered.
  defp home_dashboard?(socket), do: home_dashboard?(PhoenixKitDashboards, scope_of(socket))

  # The module arrives as an argument for the same reason it does in
  # `enabled_module?/1`: core does not depend on this package, and a call
  # written against the literal alias warns at compile time here. Public only
  # so a test can drive it with a stand-in module — core has no dependency to
  # drive it with.
  @doc false
  def home_dashboard?(module, scope) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :admin_home_dashboards, 1) and
      match?({_tier, [_ | _]}, module.admin_home_dashboards(scope))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp scope_of(socket), do: socket.assigns[:phoenix_kit_current_scope]

  defp enabled_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :enabled?, 0) and module.enabled?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  attr :scope, :any,
    required: true,
    doc: "the visitor's `PhoenixKit.Users.Auth.Scope`, or `nil`"

  attr :greeting, :atom,
    default: :welcome_back,
    doc: "greeting key drawn once per mount — see `pick_greeting/1`"

  @doc """
  The welcome half of `/admin` — the part with no permission gate at all, and
  therefore the whole page for a visitor holding nothing.

  Deliberately an `<h2>`, not an `<h1>`: the page's one header is the
  `LayoutWrapper` breadcrumb, and this sits at the same level as the operator
  overview's own section headings.

  The greeting is a key resolved through `greeting_text/1`, whose clauses are
  literal `gettext/1` calls — new phrases fall back to English until locales
  catch up, `"Welcome back"` stays translated everywhere. The name is appended
  in markup rather than interpolated into a `"…, %{name}"` msgid, which would
  ship untranslated everywhere. It is a function component rather than mount
  assigns so that `gettext` runs at RENDER time: a locale switch that only
  patches params (`handle_params`, after mount) still reaches it.

  Greeting and name render inside ONE child element: `card-title` is a flex
  container with a gap, and as sibling flex items the phrase and the `, name`
  span drew that gap between the phrase and the comma.
  """
  def welcome_block(assigns) do
    name = welcome_name(assigns.scope)

    assigns =
      assigns
      |> assign(:welcome_name, name)
      |> assign(:welcome_email, welcome_email(assigns.scope, name))

    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-2xl">
          <span>{greeting_text(@greeting)}<span :if={@welcome_name}>, {@welcome_name}</span></span>
        </h2>
        <p :if={@welcome_email} class="text-sm text-base-content/60">{@welcome_email}</p>
      </div>
    </div>
    """
  end

  # Who to greet, most personal identifier first: full name, then username,
  # then email. `Scope.user_full_name/1` is `nil` for anyone who never filled
  # in a name — most plain users — and `User.full_name/1` can still hand back a
  # blank string (an organization row whose `organization_name` was cleared, or
  # a first name of `" "`), hence `presence/1` rather than a `nil` test.
  #
  # The last fallback is the email: every account has one and it is the
  # identifier a brand-new user recognises. A scope with no user yields `nil`,
  # and the greeting then renders without a name rather than with a dangling
  # comma.
  defp welcome_name(scope) do
    Values.presence(Scope.user_full_name(scope)) ||
      Values.presence(user_username(scope)) ||
      Values.presence(Scope.user_email(scope))
  end

  defp user_username(%Scope{user: %User{username: username}}), do: username
  defp user_username(_), do: nil

  # The email is the page's only statement of WHICH account the visitor is
  # signed in as — core ships a multi-account switcher, so that is a real
  # question. Suppressed when the greeting already fell back to the email, so
  # it is never printed twice.
  defp welcome_email(scope, welcome_name) do
    case Values.presence(Scope.user_email(scope)) do
      ^welcome_name -> nil
      email -> email
    end
  end

  # ── Greeting rotation ──────────────────────────────────────────────
  # A fresh phrase every page load: the generic pool plus the bucket for the
  # visitor's local hour (personal timezone, else the system `time_zone`
  # setting). Time-of-day phrases are tripled so roughly half the loads greet
  # by the clock.
  #
  # Either setting may hold an IANA identifier ("Europe/Tallinn") or one of the
  # fixed offsets written before identifiers; `shift_to_offset/2` resolves both,
  # so the hour is the visitor's real local hour with daylight saving applied
  # rather than whatever offset was saved months ago.

  defp greeting_key_for_mount(socket) do
    if connected?(socket) do
      pick_greeting(socket.assigns[:phoenix_kit_current_scope])
    else
      :welcome_back
    end
  end

  defp pick_greeting(scope) do
    pool = time_greetings(local_hour(scope))
    Enum.random(@generic_greetings ++ pool ++ pool ++ pool)
  end

  defp local_hour(scope) do
    offset =
      case scope do
        %Scope{user: %User{} = user} -> UtilsDate.get_user_timezone(user)
        _ -> Settings.get_setting("time_zone", "0")
      end

    UtilsDate.shift_to_offset(DateTime.utc_now(), offset).hour
  end

  defp time_greetings(hour) when hour in 5..11, do: [:good_morning, :rise_and_shine]
  defp time_greetings(hour) when hour in 12..17, do: [:good_afternoon, :good_day]
  defp time_greetings(hour) when hour in 18..22, do: [:good_evening]
  defp time_greetings(_night), do: [:working_late, :night_owl]

  # Literal gettext/1 per phrase — interpolating the key would defeat POT
  # extraction. The catch-all keeps an unknown key (a stale session after a
  # deploy) from crashing the landing page.
  defp greeting_text(:good_morning), do: gettext("Good morning")
  defp greeting_text(:rise_and_shine), do: gettext("Rise and shine")
  defp greeting_text(:good_afternoon), do: gettext("Good afternoon")
  defp greeting_text(:good_day), do: gettext("Good day")
  defp greeting_text(:good_evening), do: gettext("Good evening")
  defp greeting_text(:working_late), do: gettext("Working late")
  defp greeting_text(:night_owl), do: gettext("Night owl")
  defp greeting_text(:good_to_see_you), do: gettext("Good to see you")
  defp greeting_text(:hello_again), do: gettext("Hello again")
  defp greeting_text(:hey_there), do: gettext("Hey there")
  defp greeting_text(:glad_youre_here), do: gettext("Glad you're here")
  defp greeting_text(:back_at_it), do: gettext("Back at it")
  defp greeting_text(_), do: gettext("Welcome back")
end
