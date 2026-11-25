defmodule PhoenixKit.Mentions.Token do
  @moduledoc """
  The stored form of a mention, and the only thing that turns free text into
  a link.

  Two shapes, both closed and both carrying their own label:

      @[user:018e3c4a-9f6b-7890-abcd-ef1234567890|Alice Smith]
      #[project:018e3c4a-9f6b-7890-abcd-ef1234567890|Q3 Launch]

  ## Why the label lives in the text

  The token is self-contained on purpose. Text gets copied between records,
  exported, kept in edit history, and read by people with JavaScript off —
  and a module can be uninstalled entirely. A bare foreign key survives none
  of that; this survives all of it, degrading to something a human can still
  read. It also keeps full-text search working: searching "Alice" finds the
  comment, because "Alice" is literally in the column.

  The label is a SNAPSHOT of what the author saw when they picked. It is not
  the display title — `PhoenixKit.Mentions` re-resolves that per viewer at
  render, and deliberately never shows a refreshed title to someone who
  cannot open the record.

  ## What is NOT a mention

  A bare `@alice` or `#launch` is ordinary prose and is never linked. Only
  the closed form above counts, which is what makes escaping mostly a
  non-problem: a token needs the trigger, a known type, a syntactically valid
  UUID, a `|`, a label and a `]`, so typing one by accident is not a thing
  that happens.

  Two deliberate consequences:

    * Publishing's `#hashtag` feature is untouched — the trigger character is
      shared, the stored form is not.
    * An unfinished token (someone typing, or a truncated paste) stays plain
      text rather than becoming a broken link.

  For the rare case of writing a complete-looking token that should NOT
  link, prefix it with a backslash: `\\@[user:…|Alice]`. `render/2` strips the
  backslash and leaves the rest as text.
  """

  @typedoc "`:user` for an `@` ping, `:resource` for a `#` record link."
  @type kind :: :user | :resource

  @type t :: %__MODULE__{
          kind: kind(),
          type: String.t(),
          uuid: String.t(),
          label: String.t(),
          raw: String.t()
        }

  defstruct [:kind, :type, :uuid, :label, :raw]

  # A resource type is the same namespace `ResourceLinks` uses. The label
  # stops at the first `]` — labels containing a raw `]` or `|` are refused
  # at insert time rather than escaped, because the picker is the only thing
  # that produces tokens and it can simply not produce those.
  @uuid "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  @label "[^\\]|]{1,120}"

  # Unicode mode: `{1,120}` counts characters (codepoints), as `to_string/4`
  # cuts the label. Without it the count was in BYTES, so a picked name of 61
  # two-byte letters ("Õ…") was built into a token the parser then refused,
  # and the mention was stored as text and pinged nobody. Text that is not
  # valid UTF-8 (which `/u` refuses to scan) is read with the byte form.
  @pattern ~r/(?<esc>\\?)(?<trigger>[@#])\[(?<type>[a-z][a-z0-9_]*):(?<uuid>#{@uuid})\|(?<label>#{@label})\]/u
  @byte_pattern ~r/(?<esc>\\?)(?<trigger>[@#])\[(?<type>[a-z][a-z0-9_]*):(?<uuid>#{@uuid})\|(?<label>#{@label})\]/

  @max_label 120

  @doc "The regex that recognises a token. Exposed so consumers can reuse it."
  @spec pattern() :: Regex.t()
  def pattern, do: @pattern

  @doc "Longest label a token may carry."
  @spec max_label_length() :: pos_integer()
  def max_label_length, do: @max_label

  @doc """
  Every mention in `text`, in order, ignoring backslash-escaped ones.

  Returns `[]` for nil or non-binary input so callers can pipe a possibly
  empty field straight in.
  """
  @spec parse(String.t() | nil) :: [t()]
  def parse(text) when is_binary(text) do
    text
    |> pattern_for()
    |> Regex.scan(text, capture: :all_names)
    |> Enum.flat_map(fn captures ->
      # capture: :all_names returns groups sorted by name — esc, label, trigger,
      # type, uuid. Zip rather than index so a renamed group can't silently
      # shift the meaning of every field.
      case Enum.zip(~w(esc label trigger type uuid), captures) |> Map.new() do
        %{"esc" => "\\"} ->
          []

        %{"trigger" => t, "type" => type, "uuid" => uuid, "label" => label} ->
          [build(t, type, uuid, label)]
      end
    end)
  end

  def parse(_), do: []

  @doc """
  Builds the stored form. Returns `:error` when the label can't be
  represented — the picker should then pick a different label rather than
  the caller escaping anything.
  """
  @spec to_string(kind(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def to_string(kind, type, uuid, label) do
    # Cut in codepoints, the unit the parser counts.
    label =
      label
      |> Kernel.to_string()
      |> String.trim()
      |> String.codepoints()
      |> Enum.take(@max_label)
      |> Enum.join()

    trigger = if kind == :user, do: "@", else: "#"

    cond do
      label == "" -> :error
      String.contains?(label, ["]", "|"]) -> :error
      not Regex.match?(~r/\A#{@uuid}\z/, Kernel.to_string(uuid)) -> :error
      not Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, Kernel.to_string(type)) -> :error
      true -> {:ok, "#{trigger}[#{type}:#{uuid}|#{label}]"}
    end
  end

  @doc """
  Splits `text` into a list of plain strings and `t()` structs, in order.

  This is what a renderer walks: everything that isn't a mention comes back
  as a binary to be escaped and printed as-is, and an escaped token comes
  back as text with its backslash removed.
  """
  @spec split(String.t() | nil) :: [String.t() | t()]
  def split(text) when is_binary(text) do
    pattern = pattern_for(text)

    pattern
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.flat_map(&split_piece(&1, pattern))
  end

  def split(_), do: []

  defp split_piece("", _pattern) do
    []
  end

  defp split_piece(piece, pattern) do
    case Regex.run(pattern, piece, capture: :all_names) do
      nil ->
        [piece]

      captures ->
        case Enum.zip(~w(esc label trigger type uuid), captures) |> Map.new() do
          # Escaped: the author wants the characters, not a link.
          %{"esc" => "\\"} ->
            [String.replace_prefix(piece, "\\", "")]

          %{"trigger" => t, "type" => type, "uuid" => uuid, "label" => label} ->
            [build(t, type, uuid, label)]
        end
    end
  end

  defp build(trigger, type, uuid, label) do
    kind = if trigger == "@", do: :user, else: :resource

    %__MODULE__{
      kind: kind,
      type: type,
      uuid: String.downcase(uuid),
      label: label,
      raw: "#{trigger}[#{type}:#{uuid}|#{label}]"
    }
  end

  @doc """
  The text with every mention replaced by its label — what a plain-text
  channel (an email digest, a search index, a notification preview) should
  show instead of raw tokens.
  """
  @spec to_plain_text(String.t() | nil) :: String.t()
  def to_plain_text(text) do
    text
    |> split()
    |> Enum.map_join(fn
      %__MODULE__{kind: :user, label: label} -> "@" <> label
      %__MODULE__{label: label} -> label
      piece -> piece
    end)
  end

  defp pattern_for(text), do: if(String.valid?(text), do: @pattern, else: @byte_pattern)
end
