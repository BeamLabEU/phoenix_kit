defmodule PhoenixKit.Dashboard.Badge do
  @moduledoc """
  Defines badge types for dashboard tab indicators.

  Badges provide visual feedback on tabs to show counts, status, or draw attention.
  They can be static or update live via PubSub subscriptions.

  ## Badge Types

  - `:count` - Numeric count badge (e.g., "5", "99+")
  - `:dot` - Simple colored dot indicator
  - `:status` - Status indicator with color (green/yellow/red)
  - `:new` - "New" text indicator
  - `:text` - Custom text badge

  ## Static Badge

      %Badge{type: :count, value: 5}
      %Badge{type: :dot, color: :success}
      %Badge{type: :status, value: :online, color: :success}

  ## Live Badge with PubSub

      %Badge{
        type: :count,
        subscribe: {"farm:stats", fn msg -> msg.printing_count end}
      }

  ## Context-Aware Badge

  For badges that show different values per user/organization/context, use `context_key`
  and optionally `loader`. The badge value is stored per-context in socket assigns
  instead of globally.

      # Badge depends on current organization context
      %Badge{
        type: :count,
        context_key: :organization,
        loader: {MyApp.Alerts, :count_for_org},  # Called with (context)
        subscribe: "org:{id}:alerts"  # {id} replaced with context.id
      }

  ### Context Placeholders

  Subscribe topics support `{field}` placeholders that are resolved from the current context:
  - `{id}` - context.id or context[:id]
  - `{name}` - context.name or context[:name]
  - Any field accessible on the context struct/map

  ### Loader Function

  The loader is called when the LiveView mounts to get the initial badge value:
  - `{Module, :function}` - Called as `Module.function(context)`
  - `fn context -> value end` - Anonymous function

  ## Badge with Attention Animation

      %Badge{
        type: :count,
        value: 3,
        color: :error,
        pulse: true
      }
  """

  @type badge_type :: :count | :dot | :status | :new | :text | :compound

  @type badge_color ::
          :primary | :secondary | :accent | :info | :success | :warning | :error | :neutral

  @type subscribe_config :: {String.t(), (map() -> any())} | {String.t(), atom()} | String.t()

  @type loader_config :: {module(), atom()} | (any() -> any())

  @type compound_segment :: %{
          required(:value) => integer() | String.t(),
          required(:color) => badge_color(),
          optional(:label) => String.t()
        }

  @type compound_style :: :text | :blocks | :dots

  @type t :: %__MODULE__{
          type: badge_type(),
          value: any(),
          color: badge_color(),
          max: integer() | nil,
          pulse: boolean(),
          animate: boolean(),
          hidden_when_zero: boolean(),
          subscribe: subscribe_config() | nil,
          format: (any() -> String.t()) | nil,
          metadata: map(),
          context_key: atom() | nil,
          loader: loader_config() | nil,
          # Compound badge fields
          segments: list(compound_segment()),
          compound_style: compound_style(),
          separator: String.t(),
          hide_zero_segments: boolean()
        }

  defstruct [
    :value,
    :subscribe,
    :format,
    :max,
    :context_key,
    :loader,
    type: :count,
    color: :primary,
    pulse: false,
    animate: true,
    hidden_when_zero: true,
    metadata: %{},
    # Compound badge fields
    segments: [],
    compound_style: :text,
    separator: "/",
    hide_zero_segments: false
  ]

  @valid_types [:count, :dot, :status, :new, :text, :compound]
  @valid_colors [:primary, :secondary, :accent, :info, :success, :warning, :error, :neutral]

  @doc """
  Creates a new Badge struct from a map or keyword list.

  ## Options

  - `:type` - Badge type: :count, :dot, :status, :new, :text (default: :count)
  - `:value` - The value to display (number for count, atom/string for status/text)
  - `:color` - Badge color: :primary, :secondary, :accent, :info, :success, :warning, :error, :neutral (default: :primary)
  - `:max` - Maximum display value for count badges (e.g., 99 shows "99+") (optional)
  - `:pulse` - Enable pulse animation (default: false)
  - `:animate` - Enable value change animation (default: true)
  - `:hidden_when_zero` - Hide count badge when value is 0 (default: true)
  - `:subscribe` - PubSub subscription config for live updates (optional)
  - `:format` - Custom formatter function for the value (optional)
  - `:metadata` - Custom metadata map (default: %{})
  - `:context_key` - Context selector key for per-context badges (optional, e.g., :organization)
  - `:loader` - Function to load initial value for context: `{Module, :function}` or `fn context -> value end`

  ## Subscribe Configuration

  The `:subscribe` option can be:

  1. A tuple of {topic, extractor_function}:
     `{"farm:stats", fn msg -> msg.printing_count end}`

  2. A tuple of {topic, key_atom} to extract from message:
     `{"farm:stats", :printing_count}`

  3. Just a topic string (uses full message as value):
     `"user:notifications:count"`

  Topics support `{field}` placeholders for context-aware badges:
     `"org:{id}:alerts"` - resolves to `"org:123:alerts"` when context.id is 123

  ## Examples

      iex> Badge.new(type: :count, value: 5)
      {:ok, %Badge{type: :count, value: 5}}

      iex> Badge.new(type: :dot, color: :error, pulse: true)
      {:ok, %Badge{type: :dot, color: :error, pulse: true}}

      iex> Badge.new(type: :count, subscribe: {"orders:count", :count})
      {:ok, %Badge{type: :count, subscribe: {"orders:count", :count}}}

      # Context-aware badge
      iex> Badge.new(type: :count, context_key: :organization, loader: {MyApp.Alerts, :count_for_org})
      {:ok, %Badge{type: :count, context_key: :organization, loader: {MyApp.Alerts, :count_for_org}}}
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    type = parse_type(get_attr(attrs, :type))
    color = parse_color(get_attr(attrs, :color))

    cond do
      type not in @valid_types ->
        {:error, "Invalid badge type: #{inspect(type)}. Must be one of #{inspect(@valid_types)}"}

      color not in @valid_colors ->
        {:error,
         "Invalid badge color: #{inspect(color)}. Must be one of #{inspect(@valid_colors)}"}

      true ->
        {:ok, build_badge_struct(attrs, type, color)}
    end
  end

  defp build_badge_struct(attrs, type, color) do
    %__MODULE__{
      type: type,
      value: get_attr(attrs, :value),
      color: color,
      max: get_attr(attrs, :max),
      pulse: get_attr(attrs, :pulse) || false,
      animate: get_attr_with_default(attrs, :animate, true),
      hidden_when_zero: get_attr_with_default(attrs, :hidden_when_zero, true),
      subscribe: parse_subscribe(get_attr(attrs, :subscribe)),
      format: get_attr(attrs, :format),
      metadata: get_attr(attrs, :metadata) || %{},
      context_key: get_attr(attrs, :context_key),
      loader: parse_loader(get_attr(attrs, :loader)),
      # Compound badge fields
      segments: parse_segments(get_attr(attrs, :segments)),
      compound_style: parse_compound_style(get_attr(attrs, :compound_style)),
      separator: get_attr(attrs, :separator) || "/",
      hide_zero_segments: get_attr(attrs, :hide_zero_segments) || false
    }
  end

  defp get_attr(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  defp get_attr_with_default(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  @doc """
  Creates a new Badge struct, raising on error.
  """
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, badge} -> badge
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # Convenience constructors

  @doc """
  Creates a count badge.

  ## Examples

      Badge.count(5)
      Badge.count(10, color: :error, max: 99)
  """
  @spec count(integer(), keyword()) :: t()
  def count(value, opts \\ []) do
    new!(Keyword.merge([type: :count, value: value], opts))
  end

  @doc """
  Creates a dot badge.

  ## Examples

      Badge.dot()
      Badge.dot(color: :success)
      Badge.dot(color: :error, pulse: true)
  """
  @spec dot(keyword()) :: t()
  def dot(opts \\ []) do
    new!(Keyword.merge([type: :dot], opts))
  end

  @doc """
  Creates a status badge.

  ## Examples

      Badge.status(:online, color: :success)
      Badge.status(:busy, color: :warning)
      Badge.status(:offline, color: :error)
  """
  @spec status(atom() | String.t(), keyword()) :: t()
  def status(value, opts \\ []) do
    new!(Keyword.merge([type: :status, value: value], opts))
  end

  @doc """
  Creates a "New" badge.

  ## Examples

      Badge.new_indicator()
      Badge.new_indicator(color: :accent)
  """
  @spec new_indicator(keyword()) :: t()
  def new_indicator(opts \\ []) do
    new!(Keyword.merge([type: :new, value: "New"], opts))
  end

  @doc """
  Creates a text badge with custom text.

  ## Examples

      Badge.text("Beta")
      Badge.text("Pro", color: :accent)
  """
  @spec text(String.t(), keyword()) :: t()
  def text(value, opts \\ []) do
    new!(Keyword.merge([type: :text, value: value], opts))
  end

  @doc """
  Creates a compound badge with multiple colored segments.

  A compound badge displays multiple values with different colors in a single badge.
  Useful for showing status breakdowns like "10 success / 5 pending / 2 error".

  ## Styles

  - `:text` (default) - Colored text values with separator (e.g., "10 / 5 / 2")
  - `:blocks` - Colored background pills side by side
  - `:dots` - Colored dots with numbers beside them

  ## Options

  - `:style` - Display style: `:text`, `:blocks`, `:dots` (default: `:text`)
  - `:separator` - Separator string for `:text` style (default: "/")
  - `:hide_zero_segments` - Hide segments with value 0 (default: false)
  - `:pulse` - Enable pulse animation (default: false)

  ## Segment Format

  Each segment is a map with:
  - `:value` (required) - Integer or string value to display
  - `:color` (required) - Badge color atom (:success, :warning, :error, etc.)
  - `:label` (optional) - Text label shown after value (e.g., "done", "pending")

  ## Examples

      # Simple compound badge
      Badge.compound([
        %{value: 10, color: :success},
        %{value: 5, color: :warning},
        %{value: 2, color: :error}
      ])

      # With labels and blocks style
      Badge.compound([
        %{value: 10, color: :success, label: "done"},
        %{value: 5, color: :warning, label: "pending"}
      ], style: :blocks)

      # Hide zero segments
      Badge.compound([
        %{value: 10, color: :success},
        %{value: 0, color: :error}
      ], hide_zero_segments: true)
      # Only shows: "10"
  """
  @spec compound(list(compound_segment()), keyword()) :: t()
  def compound(segments, opts \\ []) when is_list(segments) do
    new!(
      Keyword.merge(
        [
          type: :compound,
          segments: segments,
          compound_style: Keyword.get(opts, :style, :text),
          separator: Keyword.get(opts, :separator, "/"),
          hide_zero_segments: Keyword.get(opts, :hide_zero_segments, false)
        ],
        opts
      )
    )
  end

  @doc """
  Creates a context-aware compound badge that loads segments per-context.

  The loader function should return a list of segment maps.

  ## Examples

      # Loader returns list of segments for current organization
      Badge.compound_context(:organization, {MyApp.Tasks, :get_status_counts},
        style: :blocks
      )

      # In MyApp.Tasks
      def get_status_counts(org) do
        [
          %{value: count_completed(org.id), color: :success},
          %{value: count_pending(org.id), color: :warning},
          %{value: count_overdue(org.id), color: :error}
        ]
      end
  """
  @spec compound_context(atom(), loader_config(), keyword()) :: t()
  def compound_context(context_key, loader, opts \\ []) do
    new!(
      Keyword.merge(
        [
          type: :compound,
          context_key: context_key,
          loader: loader,
          compound_style: Keyword.get(opts, :style, :text),
          separator: Keyword.get(opts, :separator, "/"),
          hide_zero_segments: Keyword.get(opts, :hide_zero_segments, false)
        ],
        opts
      )
    )
  end

  @doc """
  Returns visible segments for a compound badge.

  If `hide_zero_segments` is true, filters out segments with value 0 or nil.

  ## Examples

      badge = Badge.compound([
        %{value: 10, color: :success},
        %{value: 0, color: :error}
      ], hide_zero_segments: true)

      Badge.visible_segments(badge)
      # => [%{value: 10, color: :success}]
  """
  @spec visible_segments(t()) :: list(compound_segment())
  def visible_segments(%__MODULE__{type: :compound, segments: segments, hide_zero_segments: true}) do
    Enum.reject(segments, fn seg ->
      value = seg[:value] || seg["value"]
      value == 0 or is_nil(value)
    end)
  end

  def visible_segments(%__MODULE__{type: :compound, segments: segments}), do: segments
  def visible_segments(_), do: []

  @doc """
  Updates segments for a compound badge.
  """
  @spec update_segments(t(), list(compound_segment())) :: t()
  def update_segments(%__MODULE__{type: :compound} = badge, segments) when is_list(segments) do
    %{badge | segments: segments}
  end

  def update_segments(badge, _segments), do: badge

  @doc """
  Creates a live badge that subscribes to PubSub updates.

  ## Examples

      Badge.live("user:notifications", :count)
      Badge.live("farm:stats", fn msg -> msg.printing_count end, color: :info)
  """
  @spec live(String.t(), atom() | (map() -> any()), keyword()) :: t()
  def live(topic, extractor, opts \\ []) do
    subscribe =
      case extractor do
        key when is_atom(key) -> {topic, key}
        fun when is_function(fun, 1) -> {topic, fun}
      end

    new!(Keyword.merge([type: :count, subscribe: subscribe], opts))
  end

  @doc """
  Updates the badge value.
  """
  @spec update_value(t(), any()) :: t()
  def update_value(%__MODULE__{} = badge, value) do
    %{badge | value: value}
  end

  @doc """
  Formats the badge value for display.

  ## Examples

      iex> badge = Badge.count(5)
      iex> Badge.display_value(badge)
      "5"

      iex> badge = Badge.count(150, max: 99)
      iex> Badge.display_value(badge)
      "99+"
  """
  @spec display_value(t()) :: String.t() | nil
  def display_value(%__MODULE__{type: :dot}), do: nil
  def display_value(%__MODULE__{type: :new}), do: "New"

  def display_value(%__MODULE__{type: :count, value: value, max: max, format: format}) do
    formatted =
      cond do
        is_function(format, 1) -> format.(value)
        is_nil(value) -> nil
        is_nil(max) -> to_string(value)
        value > max -> "#{max}+"
        true -> to_string(value)
      end

    formatted
  end

  def display_value(%__MODULE__{value: value, format: format}) when is_function(format, 1) do
    format.(value)
  end

  def display_value(%__MODULE__{value: value}) when is_binary(value), do: value
  def display_value(%__MODULE__{value: value}) when is_atom(value), do: Atom.to_string(value)
  def display_value(%__MODULE__{value: value}), do: to_string(value)

  @doc """
  Checks if the badge should be visible.

  Count badges with value 0 are hidden by default when hidden_when_zero is true.
  Compound badges are hidden when all segments have zero value (and hide_zero_segments is true).
  """
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{type: :count, value: 0, hidden_when_zero: true}), do: false
  def visible?(%__MODULE__{type: :count, value: nil, hidden_when_zero: true}), do: false

  def visible?(%__MODULE__{type: :compound, segments: segments, hide_zero_segments: true}) do
    Enum.any?(segments, fn seg ->
      value = seg[:value] || seg["value"]
      value != nil and value != 0
    end)
  end

  def visible?(%__MODULE__{type: :compound, segments: []}), do: false
  def visible?(%__MODULE__{}), do: true

  @doc """
  Extracts value from a PubSub message using the badge's subscription config.
  """
  @spec extract_value(t(), map()) :: any()
  def extract_value(%__MODULE__{subscribe: {_topic, extractor}}, message)
      when is_function(extractor, 1) do
    extractor.(message)
  end

  def extract_value(%__MODULE__{subscribe: {_topic, key}}, message) when is_atom(key) do
    Map.get(message, key)
  end

  def extract_value(%__MODULE__{subscribe: _topic}, message) when is_binary(message) do
    message
  end

  def extract_value(%__MODULE__{subscribe: _topic}, message) when is_map(message) do
    message
  end

  def extract_value(_, message), do: message

  @doc """
  Gets the PubSub topic for this badge, if it has a subscription.
  """
  @spec get_topic(t()) :: String.t() | nil
  def get_topic(%__MODULE__{subscribe: {topic, _}}), do: topic
  def get_topic(%__MODULE__{subscribe: topic}) when is_binary(topic), do: topic
  def get_topic(_), do: nil

  @doc """
  Checks if this badge has a live subscription.
  """
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{subscribe: nil}), do: false
  def live?(%__MODULE__{subscribe: _}), do: true

  @doc """
  Returns the CSS color class for the badge.
  """
  @spec color_class(t()) :: String.t()
  def color_class(%__MODULE__{color: :primary}), do: "badge-primary"
  def color_class(%__MODULE__{color: :secondary}), do: "badge-secondary"
  def color_class(%__MODULE__{color: :accent}), do: "badge-accent"
  def color_class(%__MODULE__{color: :info}), do: "badge-info"
  def color_class(%__MODULE__{color: :success}), do: "badge-success"
  def color_class(%__MODULE__{color: :warning}), do: "badge-warning"
  def color_class(%__MODULE__{color: :error}), do: "badge-error"
  def color_class(%__MODULE__{color: :neutral}), do: "badge-neutral"
  def color_class(_), do: "badge-primary"

  @doc """
  Returns the CSS background color class for dot badges.
  """
  @spec dot_color_class(t()) :: String.t()
  def dot_color_class(%__MODULE__{color: :primary}), do: "bg-primary"
  def dot_color_class(%__MODULE__{color: :secondary}), do: "bg-secondary"
  def dot_color_class(%__MODULE__{color: :accent}), do: "bg-accent"
  def dot_color_class(%__MODULE__{color: :info}), do: "bg-info"
  def dot_color_class(%__MODULE__{color: :success}), do: "bg-success"
  def dot_color_class(%__MODULE__{color: :warning}), do: "bg-warning"
  def dot_color_class(%__MODULE__{color: :error}), do: "bg-error"
  def dot_color_class(%__MODULE__{color: :neutral}), do: "bg-neutral"
  def dot_color_class(_), do: "bg-primary"

  # Private helpers

  defp parse_type(:count), do: :count
  defp parse_type(:dot), do: :dot
  defp parse_type(:status), do: :status
  defp parse_type(:new), do: :new
  defp parse_type(:text), do: :text
  defp parse_type(:compound), do: :compound
  defp parse_type("count"), do: :count
  defp parse_type("dot"), do: :dot
  defp parse_type("status"), do: :status
  defp parse_type("new"), do: :new
  defp parse_type("text"), do: :text
  defp parse_type("compound"), do: :compound
  defp parse_type(nil), do: :count
  defp parse_type(other), do: other

  defp parse_color(:primary), do: :primary
  defp parse_color(:secondary), do: :secondary
  defp parse_color(:accent), do: :accent
  defp parse_color(:info), do: :info
  defp parse_color(:success), do: :success
  defp parse_color(:warning), do: :warning
  defp parse_color(:error), do: :error
  defp parse_color(:neutral), do: :neutral
  defp parse_color("primary"), do: :primary
  defp parse_color("secondary"), do: :secondary
  defp parse_color("accent"), do: :accent
  defp parse_color("info"), do: :info
  defp parse_color("success"), do: :success
  defp parse_color("warning"), do: :warning
  defp parse_color("error"), do: :error
  defp parse_color("neutral"), do: :neutral
  defp parse_color(nil), do: :primary
  defp parse_color(other), do: other

  defp parse_subscribe(nil), do: nil
  defp parse_subscribe({topic, extractor}) when is_binary(topic), do: {topic, extractor}
  defp parse_subscribe(topic) when is_binary(topic), do: topic
  defp parse_subscribe(_), do: nil

  defp parse_loader(nil), do: nil
  defp parse_loader({mod, fun}) when is_atom(mod) and is_atom(fun), do: {mod, fun}
  defp parse_loader(fun) when is_function(fun, 1), do: fun
  defp parse_loader(_), do: nil

  defp parse_segments(nil), do: []
  defp parse_segments(segments) when is_list(segments), do: segments
  defp parse_segments(_), do: []

  defp parse_compound_style(:text), do: :text
  defp parse_compound_style(:blocks), do: :blocks
  defp parse_compound_style(:dots), do: :dots
  defp parse_compound_style("text"), do: :text
  defp parse_compound_style("blocks"), do: :blocks
  defp parse_compound_style("dots"), do: :dots
  defp parse_compound_style(nil), do: :text
  defp parse_compound_style(_), do: :text

  # Context-aware badge functions

  @doc """
  Creates a context-aware badge that loads values per-context.

  ## Examples

      # Badge that shows alert count for current organization
      Badge.context(:organization, {MyApp.Alerts, :count_for_org}, color: :error)

      # With live updates via context-specific PubSub topic
      Badge.context(:farm, {MyApp.Farms, :printing_count},
        subscribe: "farm:{id}:stats",
        color: :info
      )
  """
  @spec context(atom(), loader_config(), keyword()) :: t()
  def context(context_key, loader, opts \\ []) do
    new!(Keyword.merge([type: :count, context_key: context_key, loader: loader], opts))
  end

  @doc """
  Checks if this badge is context-aware (requires per-context value storage).
  """
  @spec context_aware?(t()) :: boolean()
  def context_aware?(%__MODULE__{context_key: nil}), do: false
  def context_aware?(%__MODULE__{context_key: _}), do: true

  @doc """
  Resolves placeholders in a topic string using context data.

  Supports `{field}` syntax where field is accessed from the context.

  ## Examples

      iex> Badge.resolve_topic("org:{id}:alerts", %{id: 123})
      "org:123:alerts"

      iex> Badge.resolve_topic("farm:{farm_id}:stats", %{farm_id: "abc"})
      "farm:abc:stats"
  """
  @spec resolve_topic(String.t() | nil, map() | struct()) :: String.t() | nil
  def resolve_topic(nil, _context), do: nil

  def resolve_topic(topic, context) when is_binary(topic) do
    Regex.replace(~r/\{(\w+)\}/, topic, fn _match, field ->
      field_atom = String.to_existing_atom(field)
      value = get_context_field(context, field_atom)
      to_string(value)
    end)
  rescue
    ArgumentError -> topic
  end

  @doc """
  Gets the resolved topic for this badge given a context.

  For context-aware badges, resolves placeholders. For regular badges, returns the topic as-is.
  """
  @spec get_resolved_topic(t(), map() | struct() | nil) :: String.t() | nil
  def get_resolved_topic(%__MODULE__{} = badge, context) do
    topic = get_topic(badge)

    if context_aware?(badge) and topic do
      resolve_topic(topic, context)
    else
      topic
    end
  end

  @doc """
  Loads the initial badge value using the loader function.

  ## Examples

      iex> badge = Badge.context(:org, {MyApp.Alerts, :count_for_org})
      iex> Badge.load_value(badge, %{id: 123})
      5  # Result from MyApp.Alerts.count_for_org(%{id: 123})
  """
  @spec load_value(t(), map() | struct() | nil) :: any()
  def load_value(%__MODULE__{loader: nil}, _context), do: nil

  def load_value(%__MODULE__{loader: {mod, fun}}, context) do
    apply(mod, fun, [context])
  rescue
    _ -> nil
  end

  def load_value(%__MODULE__{loader: fun}, context) when is_function(fun, 1) do
    fun.(context)
  rescue
    _ -> nil
  end

  def load_value(_, _), do: nil

  # Helper to get a field from context (supports both maps and structs)
  defp get_context_field(context, field) when is_map(context) do
    Map.get(context, field) || Map.get(context, Atom.to_string(field))
  end

  defp get_context_field(context, field) when is_struct(context) do
    Map.get(context, field)
  end

  defp get_context_field(_, _), do: nil
end
