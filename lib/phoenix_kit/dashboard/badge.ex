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

  ## Badge with Attention Animation

      %Badge{
        type: :count,
        value: 3,
        color: :error,
        pulse: true
      }
  """

  @type badge_type :: :count | :dot | :status | :new | :text

  @type badge_color ::
          :primary | :secondary | :accent | :info | :success | :warning | :error | :neutral

  @type subscribe_config :: {String.t(), (map() -> any())} | {String.t(), atom()} | String.t()

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
          metadata: map()
        }

  defstruct [
    :value,
    :subscribe,
    :format,
    :max,
    type: :count,
    color: :primary,
    pulse: false,
    animate: true,
    hidden_when_zero: true,
    metadata: %{}
  ]

  @valid_types [:count, :dot, :status, :new, :text]
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

  ## Subscribe Configuration

  The `:subscribe` option can be:

  1. A tuple of {topic, extractor_function}:
     `{"farm:stats", fn msg -> msg.printing_count end}`

  2. A tuple of {topic, key_atom} to extract from message:
     `{"farm:stats", :printing_count}`

  3. Just a topic string (uses full message as value):
     `"user:notifications:count"`

  ## Examples

      iex> Badge.new(type: :count, value: 5)
      {:ok, %Badge{type: :count, value: 5}}

      iex> Badge.new(type: :dot, color: :error, pulse: true)
      {:ok, %Badge{type: :dot, color: :error, pulse: true}}

      iex> Badge.new(type: :count, subscribe: {"orders:count", :count})
      {:ok, %Badge{type: :count, subscribe: {"orders:count", :count}}}
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    type = parse_type(attrs[:type] || attrs["type"])
    color = parse_color(attrs[:color] || attrs["color"])

    if type in @valid_types and color in @valid_colors do
      badge = %__MODULE__{
        type: type,
        value: attrs[:value] || attrs["value"],
        color: color,
        max: attrs[:max] || attrs["max"],
        pulse: attrs[:pulse] || attrs["pulse"] || false,
        animate: Map.get(attrs, :animate, Map.get(attrs, "animate", true)),
        hidden_when_zero:
          Map.get(attrs, :hidden_when_zero, Map.get(attrs, "hidden_when_zero", true)),
        subscribe: parse_subscribe(attrs[:subscribe] || attrs["subscribe"]),
        format: attrs[:format] || attrs["format"],
        metadata: attrs[:metadata] || attrs["metadata"] || %{}
      }

      {:ok, badge}
    else
      cond do
        type not in @valid_types ->
          {:error,
           "Invalid badge type: #{inspect(type)}. Must be one of #{inspect(@valid_types)}"}

        color not in @valid_colors ->
          {:error,
           "Invalid badge color: #{inspect(color)}. Must be one of #{inspect(@valid_colors)}"}
      end
    end
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
  """
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{type: :count, value: 0, hidden_when_zero: true}), do: false
  def visible?(%__MODULE__{type: :count, value: nil, hidden_when_zero: true}), do: false
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
  defp parse_type("count"), do: :count
  defp parse_type("dot"), do: :dot
  defp parse_type("status"), do: :status
  defp parse_type("new"), do: :new
  defp parse_type("text"), do: :text
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
end
