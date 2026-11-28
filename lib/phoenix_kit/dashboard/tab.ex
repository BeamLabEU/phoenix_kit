defmodule PhoenixKit.Dashboard.Tab do
  @moduledoc """
  Defines the Tab struct and related types for the user dashboard navigation system.

  Tabs can be configured with rich features including:
  - Labels and icons
  - Conditional visibility based on roles, feature flags, or custom logic
  - Badge indicators with live updates via PubSub
  - Attention animations (pulse, bounce, shake)
  - Grouping with headers and dividers
  - Subtabs with parent/child relationships
  - Custom path matching logic
  - Tooltips and accessibility features

  ## Basic Usage

      %Tab{
        id: :orders,
        label: "My Orders",
        icon: "hero-shopping-bag",
        path: "orders",
        priority: 100
      }

  > Tab paths are **relative by convention** — `Tab.resolve_path/2` prepends the context
  > prefix (`/dashboard/` for `user_dashboard_tabs`, `/admin/` for `admin_tabs`,
  > `/admin/settings/` for `settings_tabs`). Absolute paths (starting with `/`) pass through
  > unchanged but the relative form is preferred. An empty `path: ""` resolves to the bare
  > context root (e.g. `/dashboard`).

  ## With Badge

      %Tab{
        id: :notifications,
        label: "Notifications",
        icon: "hero-bell",
        path: "notifications",
        badge: %Badge{type: :count, value: 5, color: :error}
      }

  ## With Live Updates

      %Tab{
        id: :printers,
        label: "Printers",
        icon: "hero-cube",
        path: "printers",
        badge: %Badge{
          type: :count,
          subscribe: {"farm:stats", fn msg -> msg.printing_count end}
        }
      }

  ## Conditional Visibility

  Use `visible` for non-permission conditional logic (feature flags, user data).
  For access control, use the `permission` field instead.

      %Tab{
        id: :beta_feature,
        label: "Beta",
        icon: "hero-beaker",
        path: "beta",
        visible: fn scope -> scope.user.features["beta_enabled"] == true end
      }

  ## Subtabs

  Tabs can have parent/child relationships. Subtabs appear indented under their parent:

      # Parent tab
      %Tab{
        id: :orders,
        label: "Orders",
        icon: "hero-shopping-bag",
        path: "orders",
        subtab_display: :when_active  # Show subtabs only when this tab is active
      }

      # Subtabs
      %Tab{
        id: :pending_orders,
        label: "Pending",
        path: "orders/pending",
        parent: :orders
      }

      %Tab{
        id: :completed_orders,
        label: "Completed",
        path: "orders/completed",
        parent: :orders
      }

  Subtab display modes:
  - `:when_active` - Show subtabs only when parent tab is active (default)
  - `:always` - Always show subtabs regardless of parent state
  """

  alias PhoenixKit.Dashboard.Badge
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @type match_type :: :exact | :prefix | :regex | (String.t() -> boolean())

  @type visibility :: boolean() | nil | (map() -> boolean())

  @type subtab_display :: :when_active | :always

  @typedoc """
  Whether a user-level tab is also offered in the avatar dropdown: `true`,
  `false`, or a function of the scope answering the same question at render
  time (e.g. "only while the shop module is enabled").
  """
  @type user_menu :: boolean() | (map() -> boolean())

  @type subtab_animation :: :none | :slide | :fade | :collapse

  @type level :: :user | :admin | :all

  @typedoc """
  Callback that produces a parent tab's children at render time.

  Two arities are supported and dispatched on at the sidebar layer:

  - **Arity 1** — `(scope -> [tab])`. The original contract; most modules
    use this form.
  - **Arity 2** — `(scope, locale -> [tab])`. Receives the current locale
    (or `nil` outside a localised request) so callbacks can render
    locale-aware children (e.g. translated tab labels) without falling
    back on `Gettext.get_locale/1` at render time. The locale is passed
    explicitly so plugins don't depend on Gettext process state.

  `nil` means "no dynamic children"; the parent tab renders alone.
  """
  @type dynamic_children_fn ::
          (map() -> [t()])
          | (map(), String.t() | nil -> [t()])
          | nil

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          icon: String.t() | nil,
          path: String.t(),
          priority: integer(),
          group: atom() | nil,
          parent: atom() | nil,
          level: level(),
          permission: String.t() | nil,
          personal: boolean(),
          auto_grant_admin: boolean(),
          live_view: {module(), atom()} | nil,
          dynamic_children: dynamic_children_fn(),
          subtab_display: subtab_display(),
          subtab_indent: String.t() | nil,
          subtab_icon_size: String.t() | nil,
          subtab_text_size: String.t() | nil,
          subtab_animation: subtab_animation() | nil,
          redirect_to_first_subtab: boolean(),
          highlight_with_subtabs: boolean(),
          match: match_type(),
          visible: visibility(),
          badge: Badge.t() | nil,
          tooltip: String.t() | nil,
          external: boolean(),
          new_tab: boolean(),
          attention: atom() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          gettext_backend: module() | nil,
          gettext_domain: String.t()
        }

  defstruct [
    :id,
    :label,
    :icon,
    :path,
    :group,
    :parent,
    :badge,
    :tooltip,
    :attention,
    :inserted_at,
    :subtab_indent,
    :subtab_icon_size,
    :subtab_text_size,
    :subtab_animation,
    :permission,
    :live_view,
    :dynamic_children,
    :gettext_backend,
    priority: 500,
    level: :user,
    personal: false,
    auto_grant_admin: true,
    subtab_display: :when_active,
    redirect_to_first_subtab: false,
    highlight_with_subtabs: false,
    match: :prefix,
    # nil = "auto": visible unless the path is parameterized (see visible?/2).
    # A struct literal or constructor call that says nothing about visibility
    # gets the sensible answer for its path; an explicit true/false/function
    # is always honored.
    visible: nil,
    external: false,
    new_tab: false,
    metadata: %{},
    gettext_domain: "default"
  ]

  @doc """
  Creates a new Tab struct from a map or keyword list.

  ## Options

  - `:id` - Unique identifier for the tab (required, atom)
  - `:label` - Display text for the tab (required, string)
  - `:icon` - Heroicon name, e.g., "hero-home" (optional)
  - `:path` - URL path for the tab (required)
  - `:priority` - Sort order, lower numbers appear first (default: 500)
  - `:group` - Group identifier for organizing tabs (optional, atom)
  - `:parent` - Parent tab ID for subtabs (optional, atom)
  - `:subtab_display` - When to show subtabs: :when_active or :always (default: :when_active)
  - `:subtab_indent` - Tailwind padding class for subtab indentation (e.g., "pl-6", "pl-12")
  - `:subtab_icon_size` - Icon size class for subtabs (e.g., "w-3 h-3", "w-5 h-5")
  - `:subtab_text_size` - Text size class for subtabs (e.g., "text-xs", "text-base")
  - `:subtab_animation` - Animation when subtabs appear: :none, :slide, :fade, :collapse
  - `:redirect_to_first_subtab` - Navigate to a subtab the viewer can open when clicking the
    parent: the parent's own landing subtab (the one sharing its path) when reachable, else the
    first reachable subtab by priority — `PhoenixKit.Dashboard.TabHelpers.redirect_target/2`
    (default: false)
  - `:highlight_with_subtabs` - Highlight parent when subtab is active (default: false)
  - `:match` - Path matching strategy: :exact, :prefix, :regex, or function (default: :prefix)
  - `:visible` - Boolean or function(scope) -> boolean for non-permission conditional visibility, e.g. feature flags. For access control, use `:permission` instead. When omitted, the tab is visible unless its path carries router parameters (`:uuid`, `*splat`) — those entries are routes, not navigation, and would render their placeholder segments literally in the sidebar. Pass `visible: true` explicitly to force one into the nav anyway.
  - `:personal` - Set true for a tab whose page shows the viewer their OWN data
    (their inbox, their preferences) rather than granting an administrative
    capability. Such a tab needs no `:permission`, and marking it says so
    deliberately instead of looking like an omission — `ModuleRegistry` warns
    about permission-less tabs precisely because forgetting one is the common
    mistake. Reaching admin chrome at all is still gated.
  - `:user_menu` - Also list this user-level tab in the avatar dropdown
    (`PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1` and the admin
    top bar's), between Settings and the language switcher. `true`, or a
    function `(scope -> boolean)` evaluated at render time — a module whose
    page only makes sense beside another module gates on that module here.
    Only top-level, in-app tabs with a path are offered (not subtabs, not
    `external: true` ones). With the user dashboard
    deprecated, this is how a shopper reaches "My Orders" from anywhere
    (default: false). Stored under `metadata[:user_menu]` rather than as a
    struct field — the struct sits at the 31-field mark past which the BEAM
    stops storing a map flat — so read it through `user_menu?/2`
  - `:badge` - Badge struct or map for displaying indicators (optional)
  - `:tooltip` - Hover text for the tab (optional)
  - `:external` - Whether this links to an external site (default: false)
  - `:new_tab` - Whether to open in a new tab (default: false)
  - `:attention` - Attention animation: :pulse, :bounce, :shake, :glow (optional)
  - `:metadata` - Custom metadata map for advanced use cases (default: %{})

  ## Examples

      iex> Tab.new(id: :home, label: "Home", path: "/dashboard", icon: "hero-home")
      {:ok, %Tab{id: :home, label: "Home", path: "/dashboard", icon: "hero-home"}}

      iex> Tab.new(%{id: :orders, label: "Orders", path: "/orders", priority: 100})
      {:ok, %Tab{id: :orders, label: "Orders", path: "/orders", priority: 100}}
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs),
         :ok <- validate_id(attrs),
         :ok <- validate_path(attrs),
         {:ok, badge} <- parse_badge(attrs) do
      {:ok, build_tab_struct(attrs, badge)}
    end
  end

  defp build_tab_struct(attrs, badge) do
    %__MODULE__{
      id: get_attr(attrs, :id),
      label: get_attr(attrs, :label),
      icon: get_attr(attrs, :icon),
      path: get_attr(attrs, :path),
      priority: get_attr(attrs, :priority) || 500,
      group: get_attr(attrs, :group),
      parent: get_attr(attrs, :parent),
      level: parse_level(get_attr(attrs, :level)),
      permission: get_attr(attrs, :permission),
      personal: get_attr(attrs, :personal) || false,
      auto_grant_admin:
        if(is_nil(get_attr(attrs, :auto_grant_admin)),
          do: true,
          else: get_attr(attrs, :auto_grant_admin)
        ),
      dynamic_children: get_attr(attrs, :dynamic_children),
      subtab_display: parse_subtab_display(get_attr(attrs, :subtab_display)),
      subtab_indent: get_attr(attrs, :subtab_indent),
      subtab_icon_size: get_attr(attrs, :subtab_icon_size),
      subtab_text_size: get_attr(attrs, :subtab_text_size),
      subtab_animation: parse_subtab_animation(get_attr(attrs, :subtab_animation)),
      redirect_to_first_subtab: get_attr(attrs, :redirect_to_first_subtab) || false,
      highlight_with_subtabs: get_attr(attrs, :highlight_with_subtabs) || false,
      match: parse_match(get_attr(attrs, :match) || :prefix),
      visible: get_attr(attrs, :visible),
      badge: badge,
      tooltip: get_attr(attrs, :tooltip),
      external: get_attr(attrs, :external) || false,
      new_tab: get_attr(attrs, :new_tab) || false,
      attention: parse_attention(get_attr(attrs, :attention)),
      live_view: get_attr(attrs, :live_view),
      metadata: put_user_menu(get_attr(attrs, :metadata) || %{}, get_attr(attrs, :user_menu)),
      inserted_at: UtilsDate.utc_now(),
      gettext_backend: get_attr(attrs, :gettext_backend),
      gettext_domain: get_attr(attrs, :gettext_domain) || "default"
    }
  end

  defp put_user_menu(metadata, fun) when is_function(fun, 1),
    do: Map.put(metadata, :user_menu, fun)

  defp put_user_menu(metadata, true), do: Map.put(metadata, :user_menu, true)
  defp put_user_menu(metadata, _), do: metadata

  defp get_attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end

  @doc """
  Creates a new Tab struct, raising on error.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, tab} -> tab
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Returns the tab's label, translated via the configured gettext backend if one is set.

  Falls back to the raw label string when:
    * `gettext_backend` is `nil` (default — no translation configured)
    * the label is `nil` (e.g. divider tabs)
    * gettext has no translation for the msgid (gettext's own fallback)

  Reads `gettext_backend` and `gettext_domain` via `Map.get/2` rather than
  pattern matching, so an old-shape struct cached in ETS or `:persistent_term`
  before the 1.8.0 upgrade — which lacks those keys entirely — gracefully
  falls back to the raw label instead of raising `FunctionClauseError`.
  """
  @spec localized_label(t()) :: String.t() | nil
  def localized_label(%__MODULE__{label: nil}), do: nil

  def localized_label(%__MODULE__{label: label} = tab) do
    case Map.get(tab, :gettext_backend) do
      nil ->
        label

      backend ->
        domain = Map.get(tab, :gettext_domain) || "default"
        Gettext.dgettext(backend, domain, label)
    end
  end

  @doc """
  Returns the tab's tooltip, translated via the configured gettext backend if one is set.

  Same fallback semantics as `localized_label/1`, including resilience to old
  struct shapes cached before the 1.8.0 upgrade.
  """
  @spec localized_tooltip(t()) :: String.t() | nil
  def localized_tooltip(%__MODULE__{tooltip: nil}), do: nil

  def localized_tooltip(%__MODULE__{tooltip: tooltip} = tab) do
    case Map.get(tab, :gettext_backend) do
      nil ->
        tooltip

      backend ->
        domain = Map.get(tab, :gettext_domain) || "default"
        Gettext.dgettext(backend, domain, tooltip)
    end
  end

  @doc """
  Creates a divider pseudo-tab for visual separation.

  ## Options

  - `:id` - Unique identifier (default: auto-generated)
  - `:priority` - Sort order (required to position the divider)
  - `:group` - Group this divider belongs to (optional)
  - `:label` - Optional label text for the divider (shows as a header)
  - `:gettext_backend` - Optional Gettext backend module for label translation (default: nil)
  - `:gettext_domain` - Gettext domain for translation lookups (default: "default")

  ## Examples

      Tab.divider(priority: 150)
      Tab.divider(priority: 200, label: "Account")
  """
  @spec divider(keyword()) :: t()
  def divider(opts \\ []) do
    id = opts[:id] || :"divider_#{System.unique_integer([:positive])}"

    %__MODULE__{
      id: id,
      label: opts[:label],
      icon: nil,
      path: nil,
      priority: opts[:priority] || 500,
      group: opts[:group],
      match: :exact,
      personal: opts[:personal] || false,
      visible: opts[:visible],
      metadata: %{type: :divider},
      gettext_backend: opts[:gettext_backend],
      gettext_domain: opts[:gettext_domain] || "default"
    }
  end

  @doc """
  Creates a group header pseudo-tab for organizing sections.

  ## Options

  - `:id` - Unique identifier (required)
  - `:label` - Header text (required)
  - `:priority` - Sort order (required)
  - `:icon` - Optional icon for the header
  - `:collapsible` - Whether the group can be collapsed (default: false)
  - `:collapsed` - Initial collapsed state (default: false)
  - `:gettext_backend` - Optional Gettext backend module for label translation (default: nil)
  - `:gettext_domain` - Gettext domain for translation lookups (default: "default")

  ## Examples

      Tab.group_header(id: :farm_section, label: "Farm Management", priority: 100)
      Tab.group_header(id: :account_section, label: "Account", priority: 200, collapsible: true)
  """
  @spec group_header(keyword()) :: t()
  def group_header(opts) do
    %__MODULE__{
      id: opts[:id] || raise(ArgumentError, "group_header requires :id"),
      label: opts[:label] || raise(ArgumentError, "group_header requires :label"),
      icon: opts[:icon],
      path: nil,
      priority: opts[:priority] || 500,
      group: opts[:group],
      match: :exact,
      visible: opts[:visible],
      metadata: %{
        type: :group_header,
        collapsible: opts[:collapsible] || false,
        collapsed: opts[:collapsed] || false
      },
      gettext_backend: opts[:gettext_backend],
      gettext_domain: opts[:gettext_domain] || "default"
    }
  end

  @doc """
  Checks if this tab is a divider.
  """
  @spec divider?(t()) :: boolean()
  def divider?(%__MODULE__{metadata: %{type: :divider}}), do: true
  def divider?(_), do: false

  @doc """
  Checks if this tab is a group header.
  """
  @spec group_header?(t()) :: boolean()
  def group_header?(%__MODULE__{metadata: %{type: :group_header}}), do: true
  def group_header?(_), do: false

  @doc """
  Checks if this tab is a regular navigable tab (not divider or header).
  """
  @spec navigable?(t()) :: boolean()
  def navigable?(%__MODULE__{} = tab) do
    not divider?(tab) and not group_header?(tab) and is_binary(tab.path)
  end

  @doc """
  Checks if this tab is a subtab (has a parent).
  """
  @spec subtab?(t()) :: boolean()
  def subtab?(%__MODULE__{parent: nil}), do: false
  def subtab?(%__MODULE__{parent: parent}) when is_atom(parent), do: true
  def subtab?(_), do: false

  @doc """
  Checks if this tab is a top-level tab (not a subtab).
  """
  @spec top_level?(t()) :: boolean()
  def top_level?(%__MODULE__{} = tab), do: not subtab?(tab)

  @doc """
  Gets the parent ID of a subtab, or nil if it's a top-level tab.
  """
  @spec parent_id(t()) :: atom() | nil
  def parent_id(%__MODULE__{parent: parent}), do: parent

  @doc """
  Checks if subtabs should be shown for this tab based on its display setting and active state.

  ## Examples

      iex> tab = %Tab{subtab_display: :always}
      iex> Tab.show_subtabs?(tab, false)
      true

      iex> tab = %Tab{subtab_display: :when_active}
      iex> Tab.show_subtabs?(tab, false)
      false

      iex> tab = %Tab{subtab_display: :when_active}
      iex> Tab.show_subtabs?(tab, true)
      true
  """
  @spec show_subtabs?(t(), boolean()) :: boolean()
  def show_subtabs?(%__MODULE__{subtab_display: :always}, _active), do: true
  def show_subtabs?(%__MODULE__{subtab_display: :when_active}, active), do: active
  def show_subtabs?(_, _), do: false

  @doc """
  Checks if the current path matches this tab's path according to its match strategy.

  ## Examples

      iex> tab = %Tab{path: "/dashboard", match: :exact}
      iex> Tab.matches_path?(tab, "/dashboard")
      true
      iex> Tab.matches_path?(tab, "/dashboard/orders")
      false

      iex> tab = %Tab{path: "/dashboard", match: :prefix}
      iex> Tab.matches_path?(tab, "/dashboard/orders")
      true
  """
  @spec matches_path?(t(), String.t()) :: boolean()
  def matches_path?(%__MODULE__{path: nil}, _current_path), do: false

  def matches_path?(%__MODULE__{path: path, match: :exact}, current_path) do
    normalize_path(path) == normalize_path(current_path)
  end

  def matches_path?(%__MODULE__{path: path, match: :prefix}, current_path) do
    normalized_path = normalize_path(path)
    normalized_current = normalize_path(current_path)

    normalized_current == normalized_path or
      String.starts_with?(normalized_current, normalized_path <> "/")
  end

  def matches_path?(%__MODULE__{path: _path, match: {:regex, regex}}, current_path) do
    Regex.match?(regex, normalize_path(current_path))
  end

  def matches_path?(%__MODULE__{match: match_fn}, current_path) when is_function(match_fn, 1) do
    match_fn.(normalize_path(current_path))
  end

  def matches_path?(_, _), do: false

  @doc """
  Evaluates the visibility of a tab given a scope.

  ## Examples

      iex> tab = %Tab{visible: true}
      iex> Tab.visible?(tab, %{})
      true

      iex> tab = %Tab{visible: fn scope -> scope.user.beta_enabled end}
      iex> Tab.visible?(tab, %{user: %{beta_enabled: true}})
      true
  """
  @spec visible?(t(), map() | nil) :: boolean()
  def visible?(%__MODULE__{visible: true}, _scope), do: true
  def visible?(%__MODULE__{visible: false}, _scope), do: false

  # Unset: visible unless the path is a route pattern. A ":uuid" segment in
  # the sidebar is never what anyone wanted, and every host was hand-marking
  # such entries visible: false (or worse, forgetting to).
  def visible?(%__MODULE__{visible: nil, path: path}, _scope),
    do: not parameterized_path?(path)

  def visible?(%__MODULE__{visible: visible_fn}, scope) when is_function(visible_fn, 1) do
    visible_fn.(scope)
  rescue
    _ -> false
  end

  def visible?(_, _), do: true

  @doc """
  Whether the tab is offered in the avatar dropdown for `scope` — see the
  `:user_menu` option. A raising gate answers `false`: the dropdown renders on
  every page, so one broken module must not take the menu down with it —
  whether the gate raises or exits (a call into a stopped process).
  """
  @spec user_menu?(t(), map() | nil) :: boolean()
  def user_menu?(%__MODULE__{metadata: %{user_menu: true}}, _scope), do: true

  def user_menu?(%__MODULE__{metadata: %{user_menu: fun}}, scope) when is_function(fun, 1) do
    fun.(scope) == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def user_menu?(_, _), do: false

  @doc """
  Whether `path` contains router parameter segments (`:uuid`, `*splat`).

  Matched per segment, not by searching for a colon — `https://…` external
  tabs, ports, and `mailto:` links all contain colons in positions that are
  not parameters.
  """
  @spec parameterized_path?(String.t() | nil) :: boolean()
  def parameterized_path?(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.any?(&Regex.match?(~r/^:[A-Za-z_]\w*$|^\*/, &1))
  end

  def parameterized_path?(_), do: false

  @doc """
  Whether the tab is hidden regardless of scope: an explicit
  `visible: false`, or an unset `visible` on a parameterized path.

  For callers that have no scope to evaluate visibility functions against —
  function-visibility tabs are NOT hard-hidden.
  """
  @spec hard_hidden?(t()) :: boolean()
  def hard_hidden?(%__MODULE__{visible: false}), do: true
  def hard_hidden?(%__MODULE__{visible: nil, path: path}), do: parameterized_path?(path)
  def hard_hidden?(_), do: false

  @doc """
  Checks if this is an admin-level tab.
  """
  @spec admin?(t()) :: boolean()
  def admin?(%__MODULE__{level: :admin}), do: true
  def admin?(_), do: false

  @doc """
  Checks if this is a user-level tab.
  """
  @spec user?(t()) :: boolean()
  def user?(%__MODULE__{level: :user}), do: true
  def user?(_), do: false

  @doc """
  Checks if permission is granted for this tab given a scope.

  Returns true if:
  - The tab has no permission requirement (permission is nil)
  - The scope has module access for the tab's permission key
  """
  @spec permission_granted?(t(), map()) :: boolean()
  def permission_granted?(%__MODULE__{permission: nil}, _scope), do: true

  def permission_granted?(%__MODULE__{permission: permission}, scope)
      when is_binary(permission) do
    Scope.has_module_access?(scope, permission)
  rescue
    _ -> false
  end

  def permission_granted?(%__MODULE__{permission: permission}, scope)
      when is_atom(permission) do
    Scope.has_module_access?(scope, Atom.to_string(permission))
  rescue
    _ -> false
  end

  def permission_granted?(_, _), do: true

  @doc """
  Checks if the module associated with this tab is enabled.

  Returns true if:
  - The tab has no permission requirement (permission is nil)
  - The feature module for the permission key is enabled
  """
  @spec module_enabled?(t()) :: boolean()
  def module_enabled?(%__MODULE__{permission: nil}), do: true

  def module_enabled?(%__MODULE__{permission: permission}) when is_binary(permission) do
    Permissions.feature_enabled?(permission)
  rescue
    _ -> false
  end

  def module_enabled?(_), do: true

  @doc """
  Updates a tab's badge value.
  """
  @spec update_badge(t(), Badge.t() | map() | nil) :: t()
  def update_badge(%__MODULE__{} = tab, nil), do: %{tab | badge: nil}

  def update_badge(%__MODULE__{} = tab, %Badge{} = badge) do
    %{tab | badge: badge}
  end

  def update_badge(%__MODULE__{} = tab, badge_attrs) when is_map(badge_attrs) do
    case Badge.new(badge_attrs) do
      {:ok, badge} -> %{tab | badge: badge}
      _ -> tab
    end
  end

  @doc """
  Sets an attention animation on the tab.
  """
  @spec set_attention(t(), atom() | nil) :: t()
  def set_attention(%__MODULE__{} = tab, attention)
      when attention in [nil, :pulse, :bounce, :shake, :glow] do
    %{tab | attention: attention}
  end

  def set_attention(tab, _), do: tab

  @doc """
  Clears the attention animation from the tab.
  """
  @spec clear_attention(t()) :: t()
  def clear_attention(%__MODULE__{} = tab), do: %{tab | attention: nil}

  @doc """
  Resolves a relative tab path to an absolute path based on context.

  Modules define short relative paths (e.g., `"hello-world"`) and the core
  prepends the appropriate prefix based on which callback returned the tab:

    * `:admin` — prepends `/admin`
    * `:settings` — prepends `/admin/settings`
    * `:user_dashboard` — prepends `/dashboard`

  Absolute paths (starting with `/`) pass through unchanged.
  Empty strings resolve to the context root (e.g., `""` + `:admin` → `"/admin"`).
  """
  @spec resolve_path(t(), :admin | :settings | :user_dashboard) :: t()
  def resolve_path(%__MODULE__{path: path} = tab, context),
    do: %{tab | path: resolve_path_string(path, context)}

  @doc """
  The same rule as `resolve_path/2`, for a bare path string — used where a
  tab is still a config map (the router's `:admin_dashboard_tabs` routes, the
  admin fallback redirect), so a relative path lands where the sidebar links.
  """
  @spec resolve_path_string(String.t(), :admin | :settings | :user_dashboard) :: String.t()
  def resolve_path_string("/" <> _ = path, _context), do: path
  def resolve_path_string("", context), do: context_to_prefix(context)
  def resolve_path_string(path, context), do: "#{context_to_prefix(context)}/#{path}"

  defp context_to_prefix(:admin), do: "/admin"
  defp context_to_prefix(:settings), do: "/admin/settings"
  defp context_to_prefix(:user_dashboard), do: "/dashboard"

  # Private functions

  defp validate_required(attrs) do
    id = attrs[:id] || attrs["id"]
    label = attrs[:label] || attrs["label"]
    path = attrs[:path] || attrs["path"]

    cond do
      is_nil(id) -> {:error, "Tab requires :id"}
      is_nil(label) -> {:error, "Tab requires :label"}
      is_nil(path) -> {:error, "Tab requires :path"}
      true -> :ok
    end
  end

  defp validate_id(attrs) do
    id = attrs[:id] || attrs["id"]

    if is_atom(id) do
      :ok
    else
      {:error, "Tab :id must be an atom, got: #{inspect(id)}"}
    end
  end

  defp validate_path(attrs) do
    path = attrs[:path] || attrs["path"]

    if is_binary(path) do
      :ok
    else
      {:error, "Tab :path must be a string, got: #{inspect(path)}"}
    end
  end

  defp parse_badge(attrs) do
    badge_attrs = attrs[:badge] || attrs["badge"]

    case badge_attrs do
      nil -> {:ok, nil}
      %Badge{} = badge -> {:ok, badge}
      map when is_map(map) -> Badge.new(map)
      _ -> {:error, "Invalid badge configuration"}
    end
  end

  defp parse_level(nil), do: :user
  defp parse_level(:user), do: :user
  defp parse_level(:admin), do: :admin
  defp parse_level(:all), do: :all
  defp parse_level("user"), do: :user
  defp parse_level("admin"), do: :admin
  defp parse_level("all"), do: :all
  defp parse_level(_), do: :user

  defp parse_match(:exact), do: :exact
  defp parse_match(:prefix), do: :prefix
  defp parse_match({:regex, regex}) when is_struct(regex, Regex), do: {:regex, regex}
  defp parse_match(fun) when is_function(fun, 1), do: fun
  defp parse_match(_), do: :prefix

  defp parse_attention(nil), do: nil
  defp parse_attention(:pulse), do: :pulse
  defp parse_attention(:bounce), do: :bounce
  defp parse_attention(:shake), do: :shake
  defp parse_attention(:glow), do: :glow
  defp parse_attention("pulse"), do: :pulse
  defp parse_attention("bounce"), do: :bounce
  defp parse_attention("shake"), do: :shake
  defp parse_attention("glow"), do: :glow
  defp parse_attention(_), do: nil

  defp parse_subtab_display(nil), do: :when_active
  defp parse_subtab_display(:when_active), do: :when_active
  defp parse_subtab_display(:always), do: :always
  defp parse_subtab_display("when_active"), do: :when_active
  defp parse_subtab_display("always"), do: :always
  defp parse_subtab_display(_), do: :when_active

  defp parse_subtab_animation(nil), do: nil
  defp parse_subtab_animation(:none), do: :none
  defp parse_subtab_animation(:slide), do: :slide
  defp parse_subtab_animation(:fade), do: :fade
  defp parse_subtab_animation(:collapse), do: :collapse
  defp parse_subtab_animation("none"), do: :none
  defp parse_subtab_animation("slide"), do: :slide
  defp parse_subtab_animation("fade"), do: :fade
  defp parse_subtab_animation("collapse"), do: :collapse
  defp parse_subtab_animation(_), do: nil

  defp normalize_path(path) when is_binary(path) do
    path
    # Matching is about the PATH: a current_path carrying a query or
    # fragment (pages that publish their full URL so the language
    # switcher can preserve state — catalogue detail's ?category=,
    # 2026-08-31) must not break exact/prefix tab matches.
    |> String.split(["?", "#"], parts: 2)
    |> hd()
    |> String.trim_trailing("/")
    |> remove_url_prefix()
    |> remove_locale_prefix()
    # Tab paths are written canonically (`/admin/users`); the request path
    # arrives wearing the configured admin segment. Without this the two never
    # match on a host that renamed the admin area, and every tab renders
    # inactive. See `PhoenixKit.Config.get_admin_path/0`.
    |> Routes.canonical_admin_path()
  end

  defp normalize_path(_), do: ""

  defp remove_locale_prefix(path) do
    case Regex.run(~r/^\/[a-z]{2,3}(-[A-Za-z]{2,4})?(\/.*)?$/, path) do
      [_, _locale, rest] when is_binary(rest) -> rest
      [_, _locale] -> "/"
      _ -> path
    end
  end

  defp remove_url_prefix(path) do
    url_prefix = PhoenixKit.Config.get_url_prefix()

    if url_prefix != "/" and String.starts_with?(path, url_prefix) do
      String.replace_prefix(path, url_prefix, "")
    else
      path
    end
  end
end
