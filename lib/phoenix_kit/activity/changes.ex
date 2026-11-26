defmodule PhoenixKit.Activity.Changes do
  @moduledoc """
  Builds the field-level "what changed" record an Activity entry carries under
  its reserved `"changes"` metadata key:

      %{"name" => %{"from" => "Old", "to" => "New"},
        "password" => %{"changed" => true}}

  Use it through `PhoenixKit.Activity.changes/2,3` or the `changes:` option of
  `PhoenixKit.Activity.log/3` (and the `:changes` key of `log/1`); this module
  holds the rules:

    * **Only what moved.** A field whose value is the same on both sides is left
      out, so an untouched save yields `%{}` (and `log/3` then writes no
      `"changes"` key at all). The changeset of an insert (a struct not loaded
      from the database) is recorded from `nil`, not from the schema defaults.
    * **JSON-safe values.** The metadata column is JSONB. Dates and times become
      ISO 8601 strings, a `Decimal` its plain number string, an atom its name, a
      raw 16-byte UUID its text form; a list of scalars stays a list, any other
      list, map or schema struct is written as JSON text; a struct with no
      `String.Chars` is never dumped raw (`"%MyStruct{}"`). An association that
      was not loaded is not compared at all.
    * **No secrets.** A field whose name looks like a secret (`password`,
      `hashed_password`, `passphrase`, `token`, `secret`, `api_key`,
      `private_key`, `access_key`, `credential`, `salt`, `encrypt…`, `totp`,
      `otp`, `pin`, `signature`, `cookie`, `authorization`, `session_id`, and
      `key` or any `…_key`) is recorded as
      `%{"changed" => true}`, never with its values. The rule cannot be turned
      off; `:redact` adds more fields to it. Inside a map or schema value, a key
      that looks like a secret is written as `"[FILTERED]"`.
    * **Bounded size.** A string longer than `:max_length` (500) characters is
      cut and ends in `"…"`; when both sides cut to the same text the field is
      recorded as `%{"changed" => true}`. A list keeps its first 50 items, the
      51st being `"…"`. At most `:max_fields` (50) fields are kept, the first in
      alphabetical order.

  This is the shape the Catalogue module writes and the Activity pages render
  ("Name: Old → New" in the feed, a Before/After table on the entry's page).
  """

  @default_max_length 500
  @default_max_fields 50
  @max_list_items 50
  @max_depth 4

  # Never worth a line in an audit diff: the entry's own timestamp says when.
  # Compared by name: a plain map from params or JSON has string keys.
  @always_skipped ~w(__meta__ __struct__ inserted_at updated_at)

  # Errs toward redacting: a flagged field still says it changed. The short
  # words only as a whole `_`-separated part (`pin`, not `pinned`; `otp`, not
  # `footprint`), and `key` only as the last part (`key`, `ssh_key`, not
  # `key_name` or `monkey`).
  @secret_pattern ~r/password|passwd|passphrase|secret|token|credential|salt|encrypt|totp|signature|cookie|authorization|api_?key|private_?key|access_?key|session_?id|(^|_)otp($|_)|(^|_)pin($|_)|(^|_)key$/i

  @flag %{"changed" => true}

  @type opts :: [
          only: [atom() | String.t()],
          except: [atom() | String.t()],
          redact: [atom() | String.t()],
          max_length: pos_integer(),
          max_fields: pos_integer()
        ]

  @doc "See `PhoenixKit.Activity.changes/2`."
  @spec from_changeset(Ecto.Changeset.t(), opts()) :: %{optional(String.t()) => map()}
  def from_changeset(%Ecto.Changeset{} = changeset, opts \\ []) do
    applied = Ecto.Changeset.apply_changes(changeset)

    changeset.changes
    |> Map.keys()
    |> build(before_of(changeset.data), applied, opts)
  end

  # A record not yet inserted had no values: its struct holds the schema's
  # defaults (`is_active: true`), which never were in the database. An insert
  # is recorded from nil.
  defp before_of(%{__meta__: %Ecto.Schema.Metadata{state: :built}}), do: %{}
  defp before_of(data), do: data

  @doc "See `PhoenixKit.Activity.changes/3`."
  @spec from_values(map(), map(), opts()) :: %{optional(String.t()) => map()}
  def from_values(before, later, opts \\ []) when is_map(before) and is_map(later) do
    fields =
      case Keyword.get(opts, :only) do
        nil -> default_fields(before, later)
        only -> only
      end

    build(fields, before, later, opts)
  end

  @doc """
  Makes a diff map that was built elsewhere (by hand, or by an older helper)
  safe to store: keys as strings, sides JSON-safe and bounded, secret fields
  flagged. An entry that is neither a `from`/`to` pair nor the `changed` flag
  is kept as its JSON-safe value.
  """
  @spec normalize(map(), opts()) :: %{optional(String.t()) => term()}
  def normalize(changes, opts \\ []) when is_map(changes) and not is_struct(changes) do
    max = Keyword.get(opts, :max_length, @default_max_length)
    redact = name_set(Keyword.get(opts, :redact, []))

    changes
    |> Enum.map(fn {field, change} ->
      key = to_string(field)

      value =
        if secret?(key, redact),
          do: @flag,
          else: normalize_change(change, max)

      {key, value}
    end)
    |> cap_fields(Keyword.get(opts, :max_fields, @default_max_fields))
  end

  @doc """
  Turns what `log/3`'s `changes:` option accepts into the stored map: a
  changeset, a `{before, after}` or `{before, after, opts}` tuple, a ready map,
  or `nil`.
  """
  @spec build_option(term()) :: %{optional(String.t()) => term()}
  def build_option(nil), do: %{}
  def build_option(%Ecto.Changeset{} = changeset), do: from_changeset(changeset)

  def build_option({%Ecto.Changeset{} = changeset, opts}) when is_list(opts),
    do: from_changeset(changeset, opts)

  def build_option({before, later}) when is_map(before) and is_map(later),
    do: from_values(before, later)

  def build_option({before, later, opts}) when is_map(before) and is_map(later) and is_list(opts),
    do: from_values(before, later, opts)

  def build_option(%{} = changes) when not is_struct(changes), do: normalize(changes)
  def build_option(_other), do: %{}

  @doc "Whether a field name looks like it holds a secret."
  @spec secret_field?(atom() | String.t()) :: boolean()
  def secret_field?(field), do: Regex.match?(@secret_pattern, to_string(field))

  # ── Building ─────────────────────────────────────────────────────────

  defp build(fields, before, later, opts) do
    only = Keyword.get(opts, :only)
    except = name_set(Keyword.get(opts, :except, []))
    redact = name_set(Keyword.get(opts, :redact, []))
    max = Keyword.get(opts, :max_length, @default_max_length)
    allowed = only && name_set(only)

    fields
    |> Enum.uniq()
    |> Enum.reject(&always_skipped?/1)
    |> Enum.filter(fn field ->
      name = to_string(field)
      (allowed == nil or MapSet.member?(allowed, name)) and not MapSet.member?(except, name)
    end)
    |> Enum.flat_map(fn field ->
      key = to_string(field)
      old = fetch(before, field)
      new = fetch(later, field)

      case diff_field(key, old, new, redact, max) do
        nil -> []
        change -> [{key, change}]
      end
    end)
    |> cap_fields(Keyword.get(opts, :max_fields, @default_max_fields))
  end

  defp always_skipped?(field) when is_atom(field), do: Atom.to_string(field) in @always_skipped
  defp always_skipped?(field) when is_binary(field), do: field in @always_skipped
  defp always_skipped?(_field), do: false

  defp diff_field(_key, %Ecto.Association.NotLoaded{}, _new, _redact, _max), do: nil
  defp diff_field(_key, _old, %Ecto.Association.NotLoaded{}, _redact, _max), do: nil

  defp diff_field(key, old, new, redact, max) do
    cond do
      same?(old, new) ->
        nil

      secret?(key, redact) ->
        @flag

      true ->
        {from, from_cut?} = json_value(old, max)
        {to, to_cut?} = json_value(new, max)

        cond do
          from != to -> %{"from" => from, "to" => to}
          from_cut? or to_cut? -> @flag
          true -> nil
        end
    end
  end

  # A field named by a string may still be an atom key on the struct, and the
  # reverse; look both ways, never creating atoms.
  defp fetch(map, field) when is_atom(field) do
    case Map.fetch(map, field) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(field))
    end
  end

  defp fetch(map, field) when is_binary(field) do
    case Map.fetch(map, field) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {key, value} when is_atom(key) -> if Atom.to_string(key) == field, do: value
          _ -> nil
        end)
    end
  end

  defp fetch(_map, _field), do: nil

  defp default_fields(%{__struct__: schema} = before, later) do
    if function_exported?(schema, :__schema__, 1),
      do: schema.__schema__(:fields),
      else: plain_fields(before, later)
  end

  defp default_fields(before, later), do: plain_fields(before, later)

  defp plain_fields(before, later),
    do: (Map.keys(before) ++ Map.keys(later)) |> Enum.uniq() |> Enum.sort_by(&to_string/1)

  defp same?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp same?(a, b), do: a === b

  defp secret?(key, redact), do: MapSet.member?(redact, key) or secret_field?(key)

  defp name_set(names), do: names |> List.wrap() |> MapSet.new(&to_string/1)

  defp cap_fields(pairs, max_fields) do
    pairs
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.take(max_fields)
    |> Map.new()
  end

  defp normalize_change(%{} = change, max) when not is_struct(change) do
    cond do
      Map.get(change, "changed") == true or Map.get(change, :changed) == true ->
        @flag

      has_side?(change) ->
        %{
          "from" => change |> side("from", :from) |> json_value(max) |> elem(0),
          "to" => change |> side("to", :to) |> json_value(max) |> elem(0)
        }

      true ->
        change |> json_value(max) |> elem(0)
    end
  end

  defp normalize_change(value, max), do: value |> json_value(max) |> elem(0)

  defp has_side?(change),
    do: Enum.any?(["from", "to", :from, :to], &Map.has_key?(change, &1))

  defp side(change, string, atom), do: Map.get(change, string, Map.get(change, atom))

  # ── Values ───────────────────────────────────────────────────────────

  # Returns `{json_safe_value, cut?}`.
  defp json_value(nil, _max), do: {nil, false}
  defp json_value(value, _max) when is_boolean(value) or is_number(value), do: {value, false}
  defp json_value(value, _max) when is_atom(value), do: {Atom.to_string(value), false}
  defp json_value(value, max) when is_binary(value), do: value |> text() |> clip(max)
  defp json_value(%Decimal{} = value, _max), do: {Decimal.to_string(value, :normal), false}
  defp json_value(%Date{} = value, _max), do: {Date.to_iso8601(value), false}
  defp json_value(%Time{} = value, _max), do: {Time.to_iso8601(value), false}
  defp json_value(%DateTime{} = value, _max), do: {DateTime.to_iso8601(value), false}
  defp json_value(%NaiveDateTime{} = value, _max), do: {NaiveDateTime.to_iso8601(value), false}

  defp json_value(value, max) when is_list(value) do
    if Enum.all?(value, &scalar?/1) do
      {items, rest} = Enum.split(value, @max_list_items)

      {items, cut?} =
        Enum.map_reduce(items, false, fn item, cut? ->
          {item, item_cut?} = json_value(item, max)
          {item, cut? or item_cut?}
        end)

      if rest == [], do: {items, cut?}, else: {items ++ ["…"], true}
    else
      value |> to_term(0) |> encode() |> clip(max)
    end
  end

  defp json_value(%{__struct__: module} = value, max) do
    cond do
      schema?(module) -> value |> to_term(0) |> encode() |> clip(max)
      String.Chars.impl_for(value) -> value |> to_string() |> clip(max)
      true -> {struct_label(module), false}
    end
  end

  defp json_value(value, max) when is_map(value),
    do: value |> to_term(0) |> encode() |> clip(max)

  defp json_value(value, max), do: value |> inspect(limit: 20) |> clip(max)

  defp scalar?(value),
    do:
      is_nil(value) or is_binary(value) or is_number(value) or is_atom(value) or
        match?(%Decimal{}, value) or match?(%Date{}, value) or match?(%DateTime{}, value) or
        match?(%NaiveDateTime{}, value) or match?(%Time{}, value)

  # Invalid UTF-8 cannot go into JSONB, nor can U+0000 (it becomes U+FFFD).
  # A 16-byte binary is most likely a raw UUID; anything else is described,
  # not stored.
  defp text(value) do
    cond do
      String.valid?(value) ->
        String.replace(value, <<0>>, "\uFFFD")

      byte_size(value) == 16 ->
        case Ecto.UUID.load(value) do
          {:ok, uuid} -> uuid
          :error -> binary_label(value)
        end

      true ->
        binary_label(value)
    end
  end

  defp binary_label(value), do: "(binary, #{byte_size(value)} bytes)"

  # A text this module already cut (max characters and the marker) is left
  # alone, so normalizing a stored diff twice changes nothing.
  defp clip(text, max) do
    length = String.length(text)

    cond do
      length <= max -> {text, false}
      length == max + 1 and String.ends_with?(text, "…") -> {text, true}
      true -> {String.slice(text, 0, max) <> "…", true}
    end
  end

  defp encode(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _} -> "(value)"
    end
  end

  # A JSON term with string keys, secret-looking keys filtered, depth-bounded.
  defp to_term(_value, depth) when depth > @max_depth, do: "…"

  defp to_term(%Ecto.Association.NotLoaded{}, _depth), do: nil

  defp to_term(%{__struct__: module} = value, depth) do
    cond do
      schema?(module) ->
        module.__schema__(:fields)
        |> Map.new(fn field -> {field, Map.get(value, field)} end)
        |> to_term(depth)

      match?(%Decimal{}, value) or match?(%Date{}, value) or match?(%DateTime{}, value) or
        match?(%NaiveDateTime{}, value) or match?(%Time{}, value) ->
        value |> json_value(@default_max_length) |> elem(0)

      String.Chars.impl_for(value) ->
        to_string(value)

      true ->
        struct_label(module)
    end
  end

  defp to_term(value, depth) when is_map(value) do
    Map.new(value, fn {key, item} ->
      key = if is_binary(key), do: text(key), else: inspect_key(key)

      if secret_field?(key),
        do: {key, "[FILTERED]"},
        else: {key, to_term(item, depth + 1)}
    end)
  end

  defp to_term(value, depth) when is_list(value) do
    {items, rest} = Enum.split(value, @max_list_items)
    items = Enum.map(items, &to_term(&1, depth + 1))
    if rest == [], do: items, else: items ++ ["…"]
  end

  defp to_term(value, _depth) when is_binary(value), do: text(value)

  defp to_term(value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: value

  defp to_term(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp to_term(value, _depth), do: inspect(value, limit: 20)

  defp inspect_key(key) when is_atom(key), do: Atom.to_string(key)
  defp inspect_key(key), do: inspect(key, limit: 5)

  defp schema?(module), do: function_exported?(module, :__schema__, 1)

  defp struct_label(module),
    do: "%" <> String.replace_prefix(inspect(module), "Elixir.", "") <> "{}"
end
