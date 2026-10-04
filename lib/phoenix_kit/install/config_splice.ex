defmodule PhoenixKit.Install.ConfigSplice do
  @moduledoc """
  Appends entries to a literal list (`crontab: [...]`, `plugins: [...]`,
  `queues: [...]`) inside a host's own `config :app, Oban` block, by text.

  Every list-append in `PhoenixKit.Install.ObanConfig` used to do the same
  thing: trim the list body, look at whether it ends in `,`, and glue
  `",\\n" <> entries` on. That reads the *tail of the source text* as if it
  were the tail of the list, and a host's list is full of things that are not
  list elements — a `# every minute` after the last tuple, a block of comment
  lines before the closing `]`. The comma landed inside the comment, the
  candidate did not parse, `ConfigVerify.verify_or_rollback/3` rolled it back,
  and the host was told to add the entries by hand. A real host lost four cron
  entries (the job-run sweeper among them) to a five-line comment.

  ## How it avoids reading the tail

  The content is first **masked**: comments (and, for bracket matching, the
  insides of strings and sigils) are overwritten with spaces, byte for byte,
  newlines kept — so every offset in the masked copy is the same offset in the
  original. All decisions (where the list opens, where it closes, which
  character is the last real token) are made on the masked copy; the edit is
  made on the original. The new entries go **after the last real token** and
  the comma that separates them goes right behind that token — in front of
  any trailing comment, never inside it. Whatever the host wrote after that
  token (comment lines, an end-of-line comment, an unusual indent) stays where
  it was.

  Inserting at the *start* of the list was the alternative: it makes the tail
  irrelevant too. It was not chosen because it reorders a host's list (Lifeline
  would land ahead of Pruner, queues ahead of `default`), which a host reads as
  PhoenixKit rewriting its config; appending keeps the diff a pure addition at
  the end.

  This is still string surgery, so callers keep
  `ConfigVerify.verify_or_rollback/3` as the net: the masking is a heuristic
  (it does not parse interpolation nested inside a string, for one), and a
  wrong guess must come out as a rolled-back candidate, never a corrupted file.

  ## Refusals

  A list this module cannot take returns `{:error, reason}` — see
  `reason_text/2` for the wording a caller shows. Notably an *empty*
  `queues: []` is refused when `allow_empty: false` (Oban documents an empty
  queue list as "run no queues", which a node should not silently be given).
  """

  @type reason ::
          :no_block
          | :key_not_found
          | :not_literal_list
          | :combined_list
          | :unbalanced
          | :empty_list

  @doc """
  Replaces comments with spaces (newlines kept). With `strings: true`, string
  and sigil bodies are blanked too (their delimiters stay) — use that before
  matching brackets or keywords; leave it off (the default) when the text of a
  string matters, e.g. `cadence: "daily"`.

  The result has the same byte length as the input and the same newlines.
  """
  @spec mask(String.t(), keyword()) :: String.t()
  def mask(content, opts \\ []) when is_binary(content) do
    content |> do_mask(Keyword.get(opts, :strings, false), []) |> IO.iodata_to_binary()
  end

  @doc """
  True when `module_name` occurs in the code of `content` (not only in a
  comment).
  """
  @spec active?(String.t(), String.t()) :: boolean()
  def active?(content, module_name), do: String.contains?(mask(content), module_name)

  @doc """
  True when `module_name` occurs in a comment of `content` but nowhere in its
  code — the host commented the entry out. `ObanConfig` treats that as a
  deliberate refusal.
  """
  @spec declined?(String.t(), String.t()) :: boolean()
  def declined?(content, module_name),
    do: String.contains?(content, module_name) and not active?(content, module_name)

  @doc """
  Appends `entries` (each a string, possibly several lines) to the literal
  list opened by `key:` inside `config :app_name, Oban`.

  Continuation lines of an entry are re-indented to the list's entry indent.
  Returns `{:ok, candidate}` — still to be verified by the caller — or
  `{:error, reason}`.

  Options: `allow_empty: false` refuses a list with no real element.
  """
  @spec append_to_list(String.t(), atom() | String.t(), atom(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, reason()}
  def append_to_list(content, app_name, key, entries, opts \\ []) when entries != [] do
    masked = mask(content, strings: true)

    with {:ok, block} <- oban_block(masked, app_name),
         {:ok, open} <- find_open(masked, block, key),
         {:ok, close} <- find_close(masked, open),
         :ok <- check_followed_by(masked, close) do
      inner = binary_part(masked, open + 1, close - open - 1)
      first_code = first_code_index(inner)

      cond do
        first_code == nil and not Keyword.get(opts, :allow_empty, true) ->
          {:error, :empty_list}

        first_code == nil ->
          {:ok, splice_empty(content, open, close, entries)}

        true ->
          last = last_code_index(inner) + open + 1
          {:ok, splice_after(content, masked, open, close, first_code + open + 1, last, entries)}
      end
    end
  end

  @doc "Operator-facing explanation of an `append_to_list/5` refusal."
  @spec reason_text(reason(), atom()) :: String.t()
  def reason_text(reason, key)

  def reason_text(:no_block, _key),
    do:
      "there is no literal `config :app, Oban` block in config/config.exs (it may live in runtime.exs or an included file)"

  def reason_text(:key_not_found, key),
    do: "the Oban block has no `#{key}:` option"

  def reason_text(:not_literal_list, key),
    do: "`#{key}:` is not a literal list (a variable, module attribute or function call)"

  def reason_text(:combined_list, key),
    do: "`#{key}: [...]` is combined with another expression (`++`, a pipe)"

  def reason_text(:unbalanced, key),
    do: "the `#{key}:` list could not be matched to its closing bracket"

  def reason_text(:empty_list, key),
    do: "`#{key}: []` is empty, which Oban reads as \"run none\" — left as the host wrote it"

  # --- locating -----------------------------------------------------------

  # The span of `config :app, Oban ...` up to the next top-level `config` /
  # `import_config`, as {start, stop} offsets into the masked content.
  defp oban_block(masked, app_name) do
    app = Regex.escape(to_string(app_name))

    case Regex.run(
           ~r/^config\s+:#{app},\s+Oban\b((?:(?!\n(?:config\s|import_config\s)).)*)/ms,
           masked,
           return: :index
         ) do
      [{start, len}, _] -> {:ok, {start, start + len}}
      nil -> {:error, :no_block}
    end
  end

  # Offset of the `[` opening `key: [` inside the block.
  defp find_open(masked, {start, stop}, key) do
    block = binary_part(masked, start, stop - start)

    case Regex.run(~r/(?<![A-Za-z0-9_])#{Regex.escape(to_string(key))}:[ \t\r\n]*(\S)/, block,
           return: :index
         ) do
      [_, {at, 1}] ->
        if binary_part(block, at, 1) == "[",
          do: {:ok, start + at},
          else: {:error, :not_literal_list}

      nil ->
        {:error, :key_not_found}
    end
  end

  # Matching `]` by bracket depth over the masked text, where string bodies
  # and comments are already blank.
  defp find_close(masked, open) do
    rest = binary_part(masked, open, byte_size(masked) - open)

    case scan_depth(rest, 0, 0) do
      {:ok, offset} -> {:ok, open + offset}
      :error -> {:error, :unbalanced}
    end
  end

  defp scan_depth(<<>>, _depth, _i), do: :error

  defp scan_depth(<<c, rest::binary>>, depth, i) when c in [?[, ?{, ?(],
    do: scan_depth(rest, depth + 1, i + 1)

  defp scan_depth(<<c, rest::binary>>, depth, i) when c in [?], ?}, ?)] do
    if depth == 1 and c == ?], do: {:ok, i}, else: scan_depth(rest, depth - 1, i + 1)
  end

  defp scan_depth(<<_, rest::binary>>, depth, i), do: scan_depth(rest, depth, i + 1)

  # `crontab: [...] ++ extra` / `|> f()`: the list is only part of the value,
  # so a new element would not be where the caller means it.
  defp check_followed_by(masked, close) do
    tail = binary_part(masked, close + 1, byte_size(masked) - close - 1)

    case String.trim_leading(tail) do
      <<"++", _::binary>> -> {:error, :combined_list}
      <<"|>", _::binary>> -> {:error, :combined_list}
      <<"--", _::binary>> -> {:error, :combined_list}
      _ -> :ok
    end
  end

  defp first_code_index(inner) do
    case Regex.run(~r/\S/, inner, return: :index) do
      [{i, _}] -> i
      nil -> nil
    end
  end

  defp last_code_index(inner) do
    trimmed = String.trim_trailing(inner)
    byte_size(trimmed) - 1
  end

  # --- editing ------------------------------------------------------------

  # `[` ... `]` holding nothing but blanks/comments.
  defp splice_empty(content, open, close, entries) do
    base = line_indent(content, open)
    entry_indent = base <> unit(base)
    block = render(entries, entry_indent)

    if newline_between?(content, open, close) do
      # Entries go right after the line that opens the list — before any
      # comment lines inside it, after a comment on the `[` line itself.
      eol = eol_index(content, open)
      split_insert(content, eol, "\n" <> block)
    else
      before = binary_part(content, 0, open + 1)
      after_ = binary_part(content, close, byte_size(content) - close)
      before <> "\n" <> block <> "\n" <> base <> after_
    end
  end

  defp splice_after(content, masked, open, close, first_code, last, entries) do
    base = line_indent(content, open)

    entry_indent =
      if newline_between?(masked, open, first_code),
        do: line_indent(content, first_code),
        else: base <> unit(base)

    block = render(entries, entry_indent)
    comma = if binary_part(masked, last, 1) == ",", do: "", else: ","

    if newline_between?(masked, last, close) do
      # The closing `]` is on a later line: new entries start on the line
      # after the last real token's line, so an end-of-line comment stays with
      # its own entry and comment lines below it stay below the new ones.
      eol = eol_index(content, last)

      binary_part(content, 0, last + 1) <>
        comma <>
        binary_part(content, last + 1, eol - last - 1) <>
        "\n" <> block <> binary_part(content, eol, byte_size(content) - eol)
    else
      # `[{a}, {b}]` on one line: break before the `]`.
      binary_part(content, 0, last + 1) <>
        comma <>
        "\n" <>
        block <> "\n" <> base <> binary_part(content, close, byte_size(content) - close)
    end
  end

  defp render(entries, entry_indent) do
    Enum.map_join(entries, ",\n", fn entry ->
      entry
      |> String.split("\n")
      |> Enum.map_join("\n", &(entry_indent <> &1))
    end)
  end

  defp split_insert(content, at, text) do
    binary_part(content, 0, at) <> text <> binary_part(content, at, byte_size(content) - at)
  end

  # Index of the "\n" ending the line that holds `index` (or the end).
  defp eol_index(content, index) do
    rest = binary_part(content, index, byte_size(content) - index)

    case :binary.match(rest, "\n") do
      {at, _} -> index + at
      :nomatch -> byte_size(content)
    end
  end

  defp newline_between?(text, from, to) do
    from < to and :binary.match(binary_part(text, from, to - from), "\n") != :nomatch
  end

  # Leading whitespace of the line that holds `index`.
  defp line_indent(content, index) do
    head = binary_part(content, 0, index)

    line =
      case :binary.matches(head, "\n") do
        [] ->
          head

        matches ->
          {at, _} = List.last(matches)
          binary_part(head, at + 1, byte_size(head) - at - 1)
      end

    [indent] = Regex.run(~r/^[ \t]*/, line)
    indent
  end

  defp unit(base), do: if(String.contains?(base, "\t"), do: "\t", else: "  ")

  # --- masking ------------------------------------------------------------

  defp do_mask(<<>>, _strings?, acc), do: Enum.reverse(acc)

  # Comment: blank to end of line.
  defp do_mask(<<"#", rest::binary>>, strings?, acc) do
    {comment, tail} = take_until_newline(rest)
    do_mask(tail, strings?, [blank(comment), " " | acc])
  end

  # Heredoc.
  defp do_mask(<<"\"\"\"", rest::binary>>, strings?, acc) do
    {body, tail} = take_until(rest, "\"\"\"")
    do_mask(tail, strings?, ["\"\"\"", body_out(body, strings?), "\"\"\"" | acc])
  end

  defp do_mask(<<"\"", rest::binary>>, strings?, acc) do
    {body, tail} = take_quoted(rest, ?")
    do_mask(tail, strings?, ["\"", body_out(body, strings?), "\"" | acc])
  end

  defp do_mask(<<"'", rest::binary>>, strings?, acc) do
    {body, tail} = take_quoted(rest, ?')
    do_mask(tail, strings?, ["'", body_out(body, strings?), "'" | acc])
  end

  # `?#`, `?"`, `?'` — a character literal, not a comment or a quote.
  defp do_mask(<<"?", c, rest::binary>>, strings?, acc) when c in [?#, ?", ?'],
    do: do_mask(rest, strings?, [<<"?", c>> | acc])

  # Sigil with a delimiter: `~w(...)`, `~r/.../`, `~s[...]`.
  defp do_mask(<<"~", l, d, rest::binary>>, strings?, acc)
       when l in ?a..?z or l in ?A..?Z do
    if d in [?(, ?[, ?{, ?<, ?/, ?|, ?", ?'] do
      {body, tail} = take_quoted(rest, closer(d))
      do_mask(tail, strings?, [<<closer(d)>>, body_out(body, strings?), <<"~", l, d>> | acc])
    else
      do_mask(<<d, rest::binary>>, strings?, [<<"~", l>> | acc])
    end
  end

  defp do_mask(<<c, rest::binary>>, strings?, acc), do: do_mask(rest, strings?, [<<c>> | acc])

  defp closer(?(), do: ?)
  defp closer(?[), do: ?]
  defp closer(?{), do: ?}
  defp closer(?<), do: ?>
  defp closer(c), do: c

  defp body_out(body, true), do: blank(body)
  defp body_out(body, false), do: body

  # Everything except newlines becomes a space — same length, same lines.
  # Byte-wise on purpose: offsets must line up with the original binary.
  defp blank(body) do
    for <<b <- body>>, into: "", do: if(b == ?\n, do: "\n", else: " ")
  end

  defp take_until_newline(bin) do
    case :binary.match(bin, "\n") do
      {at, _} -> {binary_part(bin, 0, at), binary_part(bin, at, byte_size(bin) - at)}
      :nomatch -> {bin, ""}
    end
  end

  defp take_until(bin, marker) do
    case :binary.match(bin, marker) do
      {at, len} ->
        {binary_part(bin, 0, at), binary_part(bin, at + len, byte_size(bin) - at - len)}

      :nomatch ->
        {bin, ""}
    end
  end

  # Body of a quoted run up to the unescaped `close`; the closing delimiter is
  # consumed (the caller re-emits it).
  defp take_quoted(bin, close), do: take_quoted(bin, close, [])

  defp take_quoted(<<>>, _close, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_quoted(<<"\\", c, rest::binary>>, close, acc),
    do: take_quoted(rest, close, [<<"\\", c>> | acc])

  defp take_quoted(<<c, rest::binary>>, close, acc) when c == close,
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_quoted(<<c, rest::binary>>, close, acc), do: take_quoted(rest, close, [<<c>> | acc])
end
