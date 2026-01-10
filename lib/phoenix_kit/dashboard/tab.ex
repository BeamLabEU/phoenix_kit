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
        path: "/dashboard/orders",
        priority: 100
      }

  ## With Badge

      %Tab{
        id: :notifications,
        label: "Notifications",
        icon: "hero-bell",
        path: "/dashboard/notifications",
        badge: %Badge{type: :count, value: 5, color: :error}
      }

  ## With Live Updates

      %Tab{
        id: :printers,
        label: "Printers",
        icon: "hero-cube",
        path: "/dashboard/printers",
        badge: %Badge{
          type: :count,
          subscribe: {"farm:stats", fn msg -> msg.printing_count end}
        }
      }

  ## Conditional Visibility

      %Tab{
        id: :admin_settings,
        label: "Admin Settings",
        icon: "hero-cog-6-tooth",
        path: "/dashboard/admin",
        visible: fn scope -> PhoenixKit.Users.Roles.has_role?(scope.user, "admin") end
      }

  ## Subtabs

  Tabs can have parent/child relationships. Subtabs appear indented under their parent:

      # Parent tab
      %Tab{
        id: :orders,
        label: "Orders",
        icon: "hero-shopping-bag",
        path: "/dashboard/orders",
        subtab_display: :when_active  # Show subtabs only when this tab is active
      }

      # Subtabs
      %Tab{
        id: :pending_orders,
        label: "Pending",
        path: "/dashboard/orders/pending",
        parent: :orders
      }

      %Tab{
        id: :completed_orders,
        label: "Completed",
        path: "/dashboard/orders/completed",
        parent: :orders
      }

  Subtab display modes:
  - `:when_active` - Show subtabs only when parent tab is active (default)
  - `:always` - Always show subtabs regardless of parent state
  """

  alias PhoenixKit.Dashboard.Badge

  @type match_type :: :exact | :prefix | :regex | (String.t() -> boolean())

  @type visibility :: boolean() | (map() -> boolean())

  @type subtab_display :: :when_active | :always

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t(),
          icon: String.t() | nil,
          path: String.t(),
          priority: integer(),
          group: atom() | nil,
          parent: atom() | nil,
          subtab_display: subtab_display(),
          match: match_type(),
          visible: visibility(),
          badge: Badge.t() | nil,
          tooltip: String.t() | nil,
          external: boolean(),
          new_tab: boolean(),
          attention: atom() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil
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
    priority: 500,
    subtab_display: :when_active,
    match: :prefix,
    visible: true,
    external: false,
    new_tab: false,
    metadata: %{}
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
  - `:match` - Path matching strategy: :exact, :prefix, :regex, or function (default: :prefix)
  - `:visible` - Boolean or function(scope) -> boolean for conditional visibility (default: true)
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
      subtab_display: parse_subtab_display(get_attr(attrs, :subtab_display)),
      match: parse_match(get_attr(attrs, :match) || :prefix),
      visible: get_attr(attrs, :visible) || true,
      badge: badge,
      tooltip: get_attr(attrs, :tooltip),
      external: get_attr(attrs, :external) || false,
      new_tab: get_attr(attrs, :new_tab) || false,
      attention: parse_attention(get_attr(attrs, :attention)),
      metadata: get_attr(attrs, :metadata) || %{},
      inserted_at: DateTime.utc_now()
    }
  end

  defp get_attr(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

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
  Creates a divider pseudo-tab for visual separation.

  ## Options

  - `:id` - Unique identifier (default: auto-generated)
  - `:priority` - Sort order (required to position the divider)
  - `:group` - Group this divider belongs to (optional)
  - `:label` - Optional label text for the divider (shows as a header)

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
      visible: opts[:visible] || true,
      metadata: %{type: :divider}
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
      visible: opts[:visible] || true,
      metadata: %{
        type: :group_header,
        collapsible: opts[:collapsible] || false,
        collapsed: opts[:collapsed] || false
      }
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

      iex> tab = %Tab{visible: fn scope -> scope.admin? end}
      iex> Tab.visible?(tab, %{admin?: true})
      true
  """
  @spec visible?(t(), map()) :: boolean()
  def visible?(%__MODULE__{visible: true}, _scope), do: true
  def visible?(%__MODULE__{visible: false}, _scope), do: false

  def visible?(%__MODULE__{visible: visible_fn}, scope) when is_function(visible_fn, 1) do
    visible_fn.(scope)
  rescue
    _ -> false
  end

  def visible?(_, _), do: true

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

    if is_binary(path) and String.starts_with?(path, "/") do
      :ok
    else
      {:error, "Tab :path must be a string starting with /, got: #{inspect(path)}"}
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

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim_trailing("/")
    |> remove_locale_prefix()
    |> remove_url_prefix()
  end

  defp normalize_path(_), do: ""

  defp remove_locale_prefix(path) do
    case Regex.run(~r/^\/[a-z]{2}(-[A-Z]{2})?(\/.*)?$/, path) do
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
