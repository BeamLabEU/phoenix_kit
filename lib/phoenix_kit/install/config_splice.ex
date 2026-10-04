defmodule PhoenixKit.Install.ConfigSplice do
  @moduledoc """
  Reads and appends to the literal lists (`crontab: [...]`, `plugins: [...]`,
  `queues: [...]`) inside a host's own `config :app, Oban` block, by text.

  Every list-append in `PhoenixKit.Install.ObanConfig` used to do the same
  thing: trim the list body, look at whether it ended in `,`, and glue
  `",\\n" <> entries` on. That reads the *tail of the source text* as if it
  were the tail of the list, and a host's list is full of things that are not
  list elements — a `# every minute` after the last tuple, a block of comment
  lines before the closing `]`. The comma landed inside the comment, the
  candidate did not parse, `ConfigVerify.verify_or_rollback/3` rolled it back,
  and the host was told to add the entries by hand. A real host lost four cron
  entries (the job-run sweeper among them) to a five-line comment.

  ## How it avoids reading the tail

  The content is first **masked**: comments (and, for bracket matching, the
  insides of strings, sigils, heredocs and character literals) are overwritten
  with spaces, byte for byte, newlines kept — so every offset in the masked
  copy is the same offset in the original. All decisions (where the block and
  the list open and close, which character is the last real token) are made
  on the masked copy; the edit is made on the original. The new entries go
  **after the last real token** and the comma that separates them goes right
  behind that token — in front of any trailing comment, never inside it.
  Whatever the host wrote after that token (comment lines, an end-of-line
  comment, an unusual indent) stays where it was.

  Inserting at the *start* of the list was the alternative: it makes the tail
  irrelevant too. It was not chosen because it reorders a host's list (Lifeline
  would land ahead of Pruner, queues ahead of `default`), which a host reads as
  PhoenixKit rewriting its config; appending keeps the diff a pure addition at
  the end.

  ## Two nets

  The masking is a lexer written for this purpose, not Elixir's, so it can be
  wrong about an unusual file. Two checks keep a wrong guess from becoming a
  corrupted file:

    * a file whose masked text does not balance its brackets is refused as
      `:unreadable` — the usual symptom of a construct the masker lost track of;
    * callers verify the candidate (`ConfigVerify.verify_or_rollback/3`: it
      parses and the entries are members of the intended list) and then
      `preserves_original?/3` (nothing but the entries changed).

  ## Refusals

  A list this module cannot take returns `{:error, reason}` — see
  `reason_text/2` for the wording a caller shows. Notably an *empty*
  `queues: []` is refused when `allow_empty: false` (Oban documents an empty
  queue list as "run no queues", which a node should not silently be given).
  """

  @type reason ::
          :no_block
          | :nested_block
          | :oban_disabled
          | :option_disabled
          | :plugins_disabled
          | :plugins_not_literal
          | :cron_only_nested
          | :key_not_found
          | :not_literal_list
          | :combined_list
          | :unbalanced
          | :unreadable
          | :empty_list

  @doc """
  Replaces comments with spaces (newlines kept). With `strings: true`, string,
  sigil, heredoc and character-literal bodies are blanked too (their delimiters
  stay) — use that before matching brackets or module names; leave it off (the
  default) when the text of a string matters, e.g. `cadence: "daily"`. With
  `strings: :all` the delimiters go as well: nothing of a string is left, so
  a `"` or `\"""` standing in column 0 cannot be mistaken for code there.

  The result has the same byte length as the input and the same newlines.
  """
  @spec mask(String.t(), keyword()) :: String.t()
  def mask(content, opts \\ []) when is_binary(content) do
    content |> do_mask(Keyword.get(opts, :strings, false), 0, []) |> IO.iodata_to_binary()
  end

  @doc """
  The comments of `content` and nothing else: code and string bodies are
  blanked, the `#` markers and the comment text stay, newlines are kept. A
  commented-out entry that spans several lines reads as consecutive text.
  """
  @spec comments_only(String.t()) :: String.t()
  def comments_only(content) when is_binary(content) do
    code = mask(content)

    for {a, b} <- Enum.zip(:binary.bin_to_list(content), :binary.bin_to_list(code)),
        into: "" do
      cond do
        a == b and a == ?\n -> "\n"
        a == b -> " "
        true -> <<a>>
      end
    end
  end

  @doc """
  Where `key:`'s literal list sits inside `config :app_name, Oban`: the offsets
  of its `[` and its matching `]`, and the masked copy they index into.
  `{:error, reason}` when there is no such list (see `reason_text/2`).

  For `:crontab` only the list of an `Oban.Plugins.Cron` tuple counts — a
  `crontab:` of another plugin (`DynamicCron`) is not the one entries belong
  in.
  """
  @spec locate_list(String.t(), atom() | String.t(), atom()) ::
          {:ok, %{masked: String.t(), open: non_neg_integer(), close: non_neg_integer()}}
          | {:error, reason()}
  def locate_list(content, app_name, key) do
    masked = mask(content, strings: true)

    with :ok <- balanced(masked),
         {:ok, block} <- oban_block(span_mask(content), app_name),
         {:ok, open} <- find_open(masked, block, key, cron_names(content)),
         {:ok, close} <- find_close(masked, open),
         :ok <- check_followed_by(masked, close) do
      {:ok, %{masked: masked, open: open, close: close}}
    end
  end

  @doc """
  The text between the brackets of `key:`'s list, as written (`:original`) and
  with comments blanked (`:code`).
  """
  @spec list_text(String.t(), atom() | String.t(), atom()) ::
          {:ok, %{original: String.t(), code: String.t()}} | {:error, reason()}
  def list_text(content, app_name, key) do
    with {:ok, %{open: open, close: close}} <- locate_list(content, app_name, key) do
      inner = binary_part(content, open + 1, close - open - 1)
      {:ok, %{original: inner, code: mask(inner)}}
    end
  end

  @doc """
  `config :app_name, Oban`'s own text with comments blanked (`strings: true`
  blanks string bodies too), or `nil` when there is no literal block to scope
  to.
  """
  @spec block_code(String.t(), atom() | String.t(), keyword()) :: String.t() | nil
  def block_code(content, app_name, opts \\ []) do
    case oban_block(span_mask(content), app_name) do
      {:ok, {start, stop}} -> content |> mask(opts) |> binary_part(start, stop - start)
      _ -> nil
    end
  end

  @doc """
  The whole file's code with comments blanked and every `config :x, Oban` block
  blanked too — the app's own, other apps', and any nested in an `if` / `case`
  (a prod-only block says nothing about the other environments). What is left
  is what a presence check may read when the app's own list is not a literal
  one: the variable or attribute defined outside any Oban block.
  """
  @spec file_code(String.t(), keyword()) :: String.t()
  def file_code(content, opts \\ []) do
    masked = span_mask(content)

    top =
      Regex.scan(Regex.compile!("^config\\s+:\\w+,\\s+Oban\\b" <> block_body(), "ms"), masked,
        return: :index
      )

    nested = nested_block_ranges(masked)

    Enum.reduce(top ++ nested, mask(content, opts), fn [{start, len} | _], acc ->
      blank_range(acc, start, len)
    end)
  end

  @doc """
  Applies `fun` to the original text of `config :app_name, Oban` and splices the
  result back. The content is returned untouched when there is no literal block.
  """
  @spec update_block(String.t(), atom() | String.t(), (String.t() -> String.t())) :: String.t()
  def update_block(content, app_name, fun) do
    case oban_block(span_mask(content), app_name) do
      {:ok, {start, stop}} ->
        binary_part(content, 0, start) <>
          fun.(binary_part(content, start, stop - start)) <>
          binary_part(content, stop, byte_size(content) - stop)

      _ ->
        content
    end
  end

  @doc "True when the app's block is `config :app, Oban, false` (or `nil`)."
  @spec oban_disabled?(String.t(), atom() | String.t()) :: boolean()
  def oban_disabled?(content, app_name),
    do: oban_block(span_mask(content), app_name) == {:error, :oban_disabled}

  @doc "True when the block says `key: false` (or `nil`)."
  @spec option_off?(String.t(), atom() | String.t(), atom()) :: boolean()
  def option_off?(content, app_name, key) do
    case block_code(content, app_name, strings: true) do
      nil ->
        false

      block ->
        Regex.match?(
          ~r/(?<![A-Za-z0-9_])#{Regex.escape(to_string(key))}:[ \t\r\n]*(?:false|nil)\b/,
          block
        )
    end
  end

  @doc """
  Appends `entries` (each a string, possibly several lines) to the literal
  list opened by `key:` inside `config :app_name, Oban`.

  Continuation lines of an entry are re-indented to the list's entry indent,
  and the line ending (LF or CRLF) of the list's own neighbourhood is kept.
  Returns `{:ok, candidate}` — still to be verified by the caller — or
  `{:error, reason}`.

  Options: `allow_empty: false` refuses a list with no real element.
  """
  @spec append_to_list(String.t(), atom() | String.t(), atom(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, reason()}
  def append_to_list(content, app_name, key, entries, opts \\ []) when entries != [] do
    with {:ok, %{masked: masked, open: open, close: close}} <-
           locate_list(content, app_name, key) do
      nl = line_ending(content, open, close)
      inner = binary_part(masked, open + 1, close - open - 1)
      first_code = first_code_index(inner)

      cond do
        first_code == nil and not Keyword.get(opts, :allow_empty, true) ->
          {:error, :empty_list}

        first_code == nil ->
          {:ok, splice_empty(content, open, close, entries, nl)}

        true ->
          last = last_code_index(inner) + open + 1

          {:ok,
           splice_after(content, masked, open, close, first_code + open + 1, last, entries, nl)}
      end
    end
  end

  @doc """
  True when `candidate` equals `original` apart from the `entries`: with every
  list element equal to one of the entries removed from both, the two parse to
  the same tree (source positions ignored).

  This is the net under the masking heuristic. A splice that put the comma
  inside one of the host's strings, or merged two of its elements, still
  parses — and still contains the new entries — but changes something the
  host wrote, which this catches. It does not say *where* the entries went;
  callers confirm that with their own check on the parsed candidate.
  """
  @spec preserves_original?(String.t(), String.t(), [String.t()]) :: boolean()
  def preserves_original?(original, candidate, entries) do
    with {:ok, a} <- parse(original),
         {:ok, b} <- parse(candidate),
         {:ok, new} when is_list(new) <- parse("[" <> Enum.join(entries, ",\n") <> "]") do
      drop = Enum.map(new, &normalize/1)
      without(normalize(a), drop) == without(normalize(b), drop)
    else
      _ -> false
    end
  end

  # `emit_warnings: false`: a host's single-quoted charlists would otherwise
  # print a deprecation warning for every parse the updater does.
  defp parse(text), do: Code.string_to_quoted(text, emit_warnings: false)

  defp normalize(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp without(ast, drop) do
    Macro.prewalk(ast, fn
      list when is_list(list) -> Enum.reject(list, &(&1 in drop))
      other -> other
    end)
  end

  @doc "Whether a refusal is the host's own choice (nothing to add), not a failure."
  @spec quiet?(reason()) :: boolean()
  def quiet?(reason), do: reason in [:oban_disabled, :option_disabled, :plugins_disabled]

  @doc "Whether a refusal means the list is not a literal one (`crontab: some_var`)."
  @spec not_literal?(reason()) :: boolean()
  def not_literal?(reason),
    do: reason in [:not_literal_list, :combined_list, :plugins_not_literal]

  @doc "Operator-facing explanation of a refusal."
  @spec reason_text(reason(), atom()) :: String.t()
  def reason_text(reason, key)

  def reason_text(:no_block, _key),
    do:
      "there is no literal `config :app, Oban` block in config/config.exs " <>
        "(it may live in runtime.exs or an included file)"

  def reason_text(:nested_block, _key),
    do:
      "the `config :app, Oban` block is nested in an expression (an `if`, a `case`…) — " <>
        "check it by hand"

  def reason_text(:oban_disabled, _key),
    do: "Oban is disabled in this config (`config :app, Oban, false`), nothing to add"

  def reason_text(:option_disabled, key),
    do: "`#{key}:` is switched off (`false`/`nil`), nothing to add"

  def reason_text(:plugins_disabled, _key),
    do: "Oban plugins are switched off (`plugins: false`), nothing to add"

  def reason_text(:plugins_not_literal, _key),
    do:
      "the Oban `plugins:` are not a literal list (a variable, module attribute or " <>
        "function call), so the crontab inside cannot be found"

  def reason_text(:cron_only_nested, _key),
    do:
      "Cron is configured only in a nested `config` for an environment; add the entries " <>
        "there, or add `Oban.Plugins.Cron` to this block"

  def reason_text(:key_not_found, :crontab),
    do: "the Oban block has no `Oban.Plugins.Cron` with a `crontab:` option"

  def reason_text(:key_not_found, key),
    do: "the Oban block has no `#{key}:` option"

  def reason_text(:not_literal_list, key),
    do: "`#{key}:` is not a literal list (a variable, module attribute or function call)"

  def reason_text(:combined_list, key),
    do: "`#{key}: [...]` is combined with another expression (`++`, `--`, a pipe)"

  def reason_text(:unbalanced, key),
    do: "the `#{key}:` list could not be matched to its closing bracket"

  def reason_text(:unreadable, _key),
    do:
      "could not read the Oban block safely (the file uses a construct the updater " <>
        "cannot follow)"

  def reason_text(:empty_list, key),
    do: "`#{key}: []` is empty, which Oban reads as \"run none\" — left as the host wrote it"

  # --- locating -----------------------------------------------------------

  # A top-level block runs up to the next line that starts in column 0 with
  # something that is not part of it: not whitespace, not a closing bracket, not
  # a list/tuple/map/sigil opener and not a keyword option (`repo: …` — an
  # unformatted block has its options in column 0). That is the next `config`,
  # an `import_config`, an `if … do` wrapping another block.
  #
  # The text it runs over is the span mask (`strings: :all`), where no string
  # delimiter is left: a `"` or `"""` in column 0 is not a line start.
  defp block_body, do: "((?:(?!\\n(?=[^\\s)\\]}{\\[%~<])(?![a-z_]\\w*:)).)*)"

  defp span_mask(content), do: mask(content, strings: :all)

  # The span of `config :app, Oban ...` as {start, stop} offsets into the
  # masked content.
  defp oban_block(masked, app_name) do
    app = Regex.escape(to_string(app_name))

    case Regex.run(Regex.compile!("^config\\s+:#{app},\\s+Oban\\b" <> block_body(), "ms"), masked,
           return: :index
         ) do
      [{start, len}, {body, body_len}] ->
        if Regex.match?(
             ~r/\A\s*,\s*(?:false|nil)\s*(?:\n|\z)/,
             binary_part(masked, body, body_len)
           ),
           do: {:error, :oban_disabled},
           else: {:ok, {start, start + len}}

      nil ->
        if Regex.match?(~r/^[ \t]+config\s+:#{app},\s+Oban\b/m, masked),
          do: {:error, :nested_block},
          else: {:error, :no_block}
    end
  end

  # Offset of the `[` opening `key: [` inside the block.
  #
  # For `:crontab` it is the list of the Cron plugin, in any spelling the file
  # uses: `{Oban.Plugins.Cron, crontab: [...]}`, an aliased or Oban 2.24
  # `{Oban.Cron, …}`, the keyword-list form `{Cron, [crontab: [...]]}`, 2.24's
  # top-level `cron: [crontab: [...]]` and the legacy top-level `crontab: [...]`
  # (the last two only at the block's own level — a `crontab:` inside another
  # plugin's tuple, `DynamicCron`, is not the list entries belong in).
  defp find_open(masked, {start, stop}, :crontab, names) do
    block = binary_part(masked, start, stop - start)
    cron = Enum.map_join(names, "|", &Regex.escape/1)
    crontab = "(?<![A-Za-z0-9_])crontab:[ \\t\\r\\n]*(\\S)"

    patterns = [
      {"\\{\\s*(?:" <> cron <> ")\\s*,\\s*\\[?[^{}\\[\\]]*?" <> crontab, false},
      {"(?<![A-Za-z0-9_])cron:[ \\t\\r\\n]*\\[?[^{}\\[\\]]*?" <> crontab, true},
      {crontab, true}
    ]

    found =
      Enum.find_value(patterns, fn {source, top_level?} ->
        source
        |> Regex.compile!()
        |> Regex.scan(block, return: :index)
        |> Enum.find_value(fn [{at, _}, {char_at, 1}] ->
          if not top_level? or depth_at(block, at) == 0, do: char_at
        end)
      end)

    case found do
      nil ->
        cond do
          option_value(block, "plugins") in [:false_value] -> {:error, :plugins_disabled}
          option_value(block, "plugins") == :not_a_list -> {:error, :plugins_not_literal}
          cron_only_nested?(masked, block, names) -> {:error, :cron_only_nested}
          true -> {:error, :key_not_found}
        end

      char_at ->
        classify_open(block, start, char_at, :crontab)
    end
  end

  defp find_open(masked, {start, stop}, key, _names) do
    block = binary_part(masked, start, stop - start)
    key_s = Regex.escape(to_string(key))

    case Regex.run(~r/(?<![A-Za-z0-9_])#{key_s}:[ \t\r\n]*(\S)/, block, return: :index) do
      [_, {at, 1}] -> classify_open(block, start, at, key)
      nil -> {:error, :key_not_found}
    end
  end

  defp classify_open(block, start, at, _key) do
    cond do
      binary_part(block, at, 1) == "[" ->
        {:ok, start + at}

      Regex.match?(~r/\A(?:false|nil)\b/, binary_part(block, at, byte_size(block) - at)) ->
        {:error, :option_disabled}

      true ->
        {:error, :not_literal_list}
    end
  end

  # Bracket depth of `block` at byte `at` (the block's own options are at 0).
  defp depth_at(block, at) do
    block
    |> binary_part(0, at)
    |> :binary.bin_to_list()
    |> Enum.reduce(0, fn
      c, d when c in [?[, ?{, ?(] -> d + 1
      c, d when c in [?], ?}, ?)] -> d - 1
      _, d -> d
    end)
  end

  # The block has no Cron of its own, but a `config :app, Oban` nested in an
  # `if`/`case` (an environment's) does: Config merges it over this one, so the
  # entries belong there, not here.
  defp cron_only_nested?(masked, _block, names) do
    cron = Enum.map_join(names, "|", &Regex.escape/1)

    masked
    |> nested_blocks()
    |> Enum.any?(&Regex.match?(Regex.compile!("(?:" <> cron <> ")\\b"), &1))
  end

  # What `plugins:` holds, when the block has it: `:list`, `:false_value`,
  # `:not_a_list`, or nil.
  defp option_value(block, key) do
    case Regex.run(~r/(?<![A-Za-z0-9_])#{key}:[ \t\r\n]*(\S)/, block, return: :index) do
      [_, {at, 1}] ->
        cond do
          binary_part(block, at, 1) == "[" ->
            :list

          Regex.match?(~r/\A(?:false|nil)\b/, binary_part(block, at, byte_size(block) - at)) ->
            :false_value

          true ->
            :not_a_list
        end

      nil ->
        nil
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

  # Every bracket of the masked file is closed, and none is closed twice. A
  # file that fails this is one the masker lost track of (or one that is not
  # valid Elixir) — either way not a file to edit by text.
  defp balanced(masked) do
    if balanced?(masked, []), do: :ok, else: {:error, :unreadable}
  end

  defp balanced?(<<>>, stack), do: stack == []

  defp balanced?(<<c, rest::binary>>, stack) when c in [?[, ?{, ?(],
    do: balanced?(rest, [c | stack])

  defp balanced?(<<c, rest::binary>>, [top | stack])
       when (c == ?] and top == ?[) or (c == ?} and top == ?{) or (c == ?) and top == ?(),
       do: balanced?(rest, stack)

  defp balanced?(<<c, _::binary>>, _stack) when c in [?], ?}, ?)], do: false
  defp balanced?(<<_, rest::binary>>, stack), do: balanced?(rest, stack)

  # `crontab: [...] ++ extra` / `|> f()`: the list is only part of the value,
  # so a new element would not be where the caller means it.
  defp check_followed_by(masked, close) do
    tail = binary_part(masked, close + 1, byte_size(masked) - close - 1)

    case String.trim_leading(tail) do
      <<"++", _::binary>> -> {:error, :combined_list}
      <<"|>", _::binary>> -> {:error, :combined_list}
      <<"--", _::binary>> -> {:error, :combined_list}
      <<"<>", _::binary>> -> {:error, :combined_list}
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

  defp blank_range(text, start, len) do
    binary_part(text, 0, start) <>
      blank(binary_part(text, start, len)) <>
      binary_part(text, start + len, byte_size(text) - start - len)
  end

  # --- the file as a tree ---------------------------------------------------
  #
  # Text decides where an edit goes; the tree answers "what does this file
  # mean" — which services (Cron, Lifeline, Pruner…) the block configures once
  # `alias` and Oban's own renaming are applied, and whether an edit left a
  # duplicate behind.
  #
  # Oban 2.24 renamed `Oban.Plugins.Cron` to `Oban.Cron` (likewise Lifeline,
  # Pruner, Reindexer) and added top-level `cron:`, `lifeline:`, `pruner:`,
  # `reindexer:` and the legacy `crontab:` options. `Oban.Config` renames first,
  # then looks for duplicates, so every check here goes through `service/1`'s
  # view of the names, not the spelling in the file.

  @renamed_services %{
    Oban.Plugins.Cron => Oban.Cron,
    Oban.Plugins.Lifeline => Oban.Lifeline,
    Oban.Plugins.Pruner => Oban.Pruner,
    Oban.Plugins.Reindexer => Oban.Reindexer
  }

  # Top-level option => the service it configures (Oban's `@service_plugins`).
  @service_keys [
    cron: Oban.Cron,
    pruner: Oban.Pruner,
    lifeline: Oban.Lifeline,
    reindexer: Oban.Reindexer
  ]

  @doc """
  Oban's name for a plugin module: `Oban.Plugins.Cron` and `Oban.Cron` are the
  same service, as are the other renamed plugins.
  """
  @spec service(module()) :: module()
  def service(module), do: Map.get(@renamed_services, module, module)

  @doc """
  Every spelling of the Cron plugin the file can use: both module names, plus
  each short form its `alias` lines give them (`alias Oban.Plugins.Cron`,
  `alias Oban.Plugins.{Cron, Pruner}`, `alias Oban.{Plugins.Cron}`,
  `alias Oban.Plugins.Cron, as: C`, `alias Oban.Plugins` + `Plugins.Cron`).
  """
  @spec cron_names(String.t()) :: [String.t()]
  def cron_names(content) do
    targets = [[:Oban, :Plugins, :Cron], [:Oban, :Cron]]
    full = Enum.map(targets, &Enum.join(&1, "."))

    short =
      case parse(content) do
        {:ok, ast} ->
          for {name, expansion} <- alias_map(ast),
              target <- targets,
              {^expansion, rest} <- [Enum.split(target, length(expansion))],
              Enum.take(target, length(expansion)) == expansion,
              do: Enum.join([Atom.to_string(name) | Enum.map(rest, &Atom.to_string/1)], ".")

        _ ->
          []
      end

    Enum.uniq(full ++ short)
  end

  @doc """
  The services the app's Oban config sets up, as Oban sees them: the modules of
  `plugins:` (aliases resolved, renamed), the top-level `cron:`, `pruner:`,
  `lifeline:`, `reindexer:` options, and a legacy non-empty `crontab:`. `:error`
  when the file does not parse, there is no `config :app, Oban`, or an option
  holds something the tree cannot read (a variable).
  """
  @spec services(String.t(), atom() | String.t()) :: {:ok, [module()]} | :error
  def services(content, app_name) do
    with {:ok, ast} <- parse(content),
         [_ | _] = calls <- oban_calls(ast, app_name) do
      aliases = alias_map(ast)
      results = Enum.map(calls, &call_services(&1.opts, aliases))

      if Enum.any?(results, &(&1 == :unknown)),
        do: :error,
        else: {:ok, results |> Enum.concat() |> Enum.uniq()}
    else
      _ -> :error
    end
  end

  @doc """
  True when `module` (a full name, as a string) is used in the code of the app's
  TOP-LEVEL Oban block, with `alias` resolved: `alias PhoenixKit.Jobs.SweepWorker`
  plus `{"*/5 * * * *", SweepWorker}` uses `PhoenixKit.Jobs.SweepWorker`.
  """
  @spec module_used?(String.t(), atom() | String.t(), String.t()) :: boolean()
  def module_used?(content, app_name, module) do
    target = Module.concat([module])

    with {:ok, ast} <- parse(content),
         [_ | _] = calls <- oban_calls(ast, app_name) do
      aliases = alias_map(ast)

      calls
      |> Enum.reject(& &1.nested?)
      |> Enum.any?(fn %{opts: opts} ->
        {_, found} =
          Macro.prewalk(opts, false, fn
            {:__aliases__, _, parts} = node, acc ->
              {node, acc or resolve(parts, aliases) == target}

            node, acc ->
              {node, acc}
          end)

        found
      end)
    else
      _ -> false
    end
  end

  @doc """
  True when `candidate` has a duplicate that `original` did not: the same service
  twice (`plugins:` and the top-level service options together, names as Oban
  renames them), the same tuple twice in one crontab (worker aliases resolved),
  the same key twice in `queues:`. Oban refuses a duplicate plugin at boot, so
  this is the check that catches a splice whose idea of the block was wrong,
  whatever the reason.
  """
  @spec introduces_duplicates?(String.t(), String.t(), atom() | String.t()) :: boolean()
  def introduces_duplicates?(original, candidate, app_name),
    do: duplicates(candidate, app_name) -- duplicates(original, app_name) != []

  defp duplicates(content, app_name) do
    case parse(content) do
      {:ok, ast} ->
        aliases = alias_map(ast)

        for %{opts: opts} <- oban_calls(ast, app_name),
            dup <- opts_duplicates(opts, aliases),
            do: dup

      _ ->
        []
    end
  end

  defp opts_duplicates(opts, aliases) do
    service_dups =
      case call_services(opts, aliases) do
        :unknown -> []
        mods -> for mod <- Enum.uniq(mods -- Enum.uniq(mods)), do: {:service, mod}
      end

    cron_dups =
      for crontab <- crontabs_in(opts),
          entries = Enum.map(crontab, &(&1 |> expand_aliases(aliases) |> normalize())),
          entry <- Enum.uniq(entries -- Enum.uniq(entries)),
          do: {:cron_entry, entry}

    queue_dups =
      case List.keyfind(opts, :queues, 0) do
        {:queues, list} when is_list(list) ->
          keys = for {k, _v} <- list, do: k
          for key <- Enum.uniq(keys -- Enum.uniq(keys)), do: {:queue, key}

        _ ->
          []
      end

    service_dups ++ cron_dups ++ queue_dups
  end

  # The services one `config :app, Oban, opts` sets up, or `:unknown` when an
  # option cannot be read.
  defp call_services(opts, aliases) do
    plugins = plugin_services(opts, aliases)
    legacy = legacy_crontab_services(opts)

    if :unknown in [plugins, legacy],
      do: :unknown,
      else:
        (plugins ++ keyed_services(opts, aliases) ++ legacy)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&service/1)
  end

  defp plugin_services(opts, aliases) do
    case List.keyfind(opts, :plugins, 0) do
      {:plugins, list} when is_list(list) -> Enum.map(list, &plugin_module(&1, aliases))
      {:plugins, other} when other in [nil, false] -> []
      nil -> []
      {:plugins, _other} -> :unknown
    end
  end

  defp keyed_services(opts, aliases) do
    Enum.flat_map(@service_keys, fn {key, default} ->
      case List.keyfind(opts, key, 0) do
        nil -> []
        {^key, false} -> []
        {^key, value} -> [service_module(value, default, aliases)]
      end
    end)
  end

  # Oban's legacy top-level `crontab:` (a non-empty list) is a Cron plugin too.
  defp legacy_crontab_services(opts) do
    case List.keyfind(opts, :crontab, 0) do
      nil -> []
      {:crontab, []} -> []
      {:crontab, [_ | _]} -> [Oban.Cron]
      {:crontab, _other} -> :unknown
    end
  end

  # `cron: [opts]`, `cron: Module`, `cron: {Module, opts}`.
  defp service_module({:__aliases__, _, parts}, _default, aliases), do: resolve(parts, aliases)

  defp service_module({{:__aliases__, _, parts}, _opts}, _default, aliases),
    do: resolve(parts, aliases)

  defp service_module(_options, default, _aliases), do: default

  # Every `crontab: [...]` list in the options, wherever it sits.
  defp crontabs_in(opts) do
    {_, found} =
      Macro.prewalk(opts, [], fn
        {:crontab, list} = node, acc when is_list(list) -> {node, [list | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(found)
  end

  # Every `config :app, Oban, opts` of the file: %{opts: keyword, nested?: bool}.
  # The top-level statements are the un-nested ones; a call found deeper (inside
  # an `if`, a `case`) is an environment's.
  defp oban_calls(ast, app_name) do
    target = if is_atom(app_name), do: app_name, else: String.to_atom(app_name)

    top =
      case ast do
        {:__block__, _, list} -> list
        other -> [other]
      end

    top_calls = for node <- top, opts = config_opts(node, target), opts != nil, do: opts

    {_, all} =
      Macro.prewalk(ast, [], fn node, acc ->
        case config_opts(node, target) do
          nil -> {node, acc}
          opts -> {node, [opts | acc]}
        end
      end)

    nested = all |> Enum.reverse() |> Enum.reject(&Enum.any?(top_calls, fn t -> t === &1 end))

    Enum.map(top_calls, &%{opts: &1, nested?: false}) ++
      Enum.map(nested, &%{opts: &1, nested?: true})
  end

  defp config_opts({:config, _meta, [app, {:__aliases__, _, [:Oban]}, opts]}, target)
       when app == target and is_list(opts),
       do: opts

  defp config_opts(_node, _target), do: nil

  defp plugin_module({:__aliases__, _, parts}, aliases), do: resolve(parts, aliases)
  defp plugin_module({{:__aliases__, _, parts}, _opts}, aliases), do: resolve(parts, aliases)

  defp plugin_module({:{}, _, [{:__aliases__, _, parts} | _]}, aliases),
    do: resolve(parts, aliases)

  # `:"Elixir.Oban.Plugins.Cron"` is the module itself.
  defp plugin_module(atom, _aliases) when is_atom(atom) and atom not in [nil, true, false],
    do: atom

  defp plugin_module({atom, _opts}, _aliases)
       when is_atom(atom) and atom not in [nil, true, false],
       do: atom

  defp plugin_module(_, _), do: nil

  defp resolve(parts, aliases) do
    case parts do
      [first | rest] when is_atom(first) ->
        Module.concat((Map.get(aliases, first) || [first]) ++ rest)

      _ ->
        nil
    end
  end

  # Replaces every alias node in `ast` by the full module it stands for.
  defp expand_aliases(ast, aliases) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, [first | rest]} when is_atom(first) ->
        {:__aliases__, meta, (Map.get(aliases, first) || [first]) ++ rest}

      other ->
        other
    end)
  end

  # short name => full module parts, from the file's top-level `alias` lines, in
  # order (a later alias sees the earlier ones: `alias Oban.Plugins` then
  # `alias Plugins.Cron`).
  defp alias_map(ast) do
    statements =
      case ast do
        {:__block__, _, list} -> list
        other -> [other]
      end

    Enum.reduce(statements, %{}, fn
      {:alias, _, [{:__aliases__, _, parts}]}, acc ->
        full = expand_parts(parts, acc)
        Map.put(acc, List.last(parts), full)

      {:alias, _, [{:__aliases__, _, parts}, opts]}, acc when is_list(opts) ->
        case Keyword.get(opts, :as) do
          {:__aliases__, _, [name]} -> Map.put(acc, name, expand_parts(parts, acc))
          _ -> acc
        end

      {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, members}]}, acc ->
        base = expand_parts(base, acc)

        Enum.reduce(members, acc, fn
          {:__aliases__, _, tail}, inner -> Map.put(inner, List.last(tail), base ++ tail)
          _, inner -> inner
        end)

      _, acc ->
        acc
    end)
  end

  defp expand_parts([first | rest], aliases) when is_atom(first),
    do: (Map.get(aliases, first) || [first]) ++ rest

  defp expand_parts(parts, _aliases), do: parts

  @doc "True when an indented (nested in `if`/`case`) `config :app, Oban` exists."
  @spec nested_block?(String.t(), atom() | String.t()) :: boolean()
  def nested_block?(content, app_name) do
    app = Regex.escape(to_string(app_name))
    Regex.match?(~r/^[ \t]+config\s+:#{app},\s+Oban\b/m, span_mask(content))
  end

  @doc """
  True when a nested `config :app, Oban` comes AFTER the app's top-level block —
  the order Config evaluates them in, so the nested one can override it.
  """
  @spec nested_block_follows?(String.t(), atom() | String.t()) :: boolean()
  def nested_block_follows?(content, app_name) do
    masked = span_mask(content)

    case oban_block(masked, app_name) do
      {:ok, {_start, stop}} ->
        masked |> nested_block_ranges() |> Enum.any?(fn [{at, _} | _] -> at >= stop end)

      _ ->
        false
    end
  end

  # Text of every indented `config :x, Oban` block of the masked content. An
  # indented block runs while the following lines are indented deeper than its
  # own `config` line (or blank).
  defp nested_blocks(masked) do
    for [{start, len} | _] <- nested_block_ranges(masked), do: binary_part(masked, start, len)
  end

  defp nested_block_ranges(masked) do
    Regex.scan(
      ~r/^([ \t]+)config\s+:\w+,\s+Oban\b[^\n]*(?:\n(?:\1[ \t]+[^\n]*|[ \t]*(?=\n)))*/m,
      masked,
      return: :index
    )
  end

  # --- editing ------------------------------------------------------------

  # The line ending to write: CRLF when the list's own neighbourhood (the line
  # that opens it through the one that closes it) uses it, LF when that holds
  # an LF-only line; a one-line list falls back to whichever the whole file
  # uses more.
  defp line_ending(content, open, close) do
    from = line_start(content, open)
    span = binary_part(content, from, close - from + 1)

    case {count(span, "\r\n"), count(span, "\n")} do
      {0, 0} -> if count(content, "\r\n") * 2 > count(content, "\n"), do: "\r\n", else: "\n"
      {crlf, lf} -> if crlf * 2 > lf, do: "\r\n", else: "\n"
    end
  end

  defp count(text, pattern), do: length(:binary.matches(text, pattern))

  defp line_start(content, index) do
    head = binary_part(content, 0, index)

    case :binary.matches(head, "\n") do
      [] ->
        0

      matches ->
        {at, _} = List.last(matches)
        at + 1
    end
  end

  # `[` ... `]` holding nothing but blanks/comments.
  defp splice_empty(content, open, close, entries, nl) do
    base = line_indent(content, open)
    entry_indent = base <> unit(base)
    block = render(entries, entry_indent, nl)

    if newline_between?(content, open, close) do
      # Entries go right after the line that opens the list — before any
      # comment lines inside it, after a comment on the `[` line itself.
      split_insert(content, eol_index(content, open), nl <> block)
    else
      before = binary_part(content, 0, open + 1)
      after_ = binary_part(content, close, byte_size(content) - close)
      before <> nl <> block <> nl <> base <> after_
    end
  end

  defp splice_after(content, masked, open, close, first_code, last, entries, nl) do
    base = line_indent(content, open)

    entry_indent =
      if newline_between?(masked, open, first_code),
        do: line_indent(content, first_code),
        else: base <> unit(base)

    block = render(entries, entry_indent, nl)
    comma = if binary_part(masked, last, 1) == ",", do: "", else: ","

    if newline_between?(masked, last, close) do
      # The closing `]` is on a later line: new entries start on the line
      # after the last real token's line, so an end-of-line comment stays with
      # its own entry and comment lines below it stay below the new ones.
      eol = eol_index(content, last)

      binary_part(content, 0, last + 1) <>
        comma <>
        binary_part(content, last + 1, eol - last - 1) <>
        nl <> block <> binary_part(content, eol, byte_size(content) - eol)
    else
      # `[{a}, {b}]` on one line: break before the `]`.
      binary_part(content, 0, last + 1) <>
        comma <>
        nl <>
        block <> nl <> base <> binary_part(content, close, byte_size(content) - close)
    end
  end

  defp render(entries, entry_indent, nl) do
    Enum.map_join(entries, "," <> nl, fn entry ->
      entry
      |> String.split("\n")
      |> Enum.map_join(nl, &(entry_indent <> &1))
    end)
  end

  defp split_insert(content, at, text) do
    binary_part(content, 0, at) <> text <> binary_part(content, at, byte_size(content) - at)
  end

  # Where the line that holds `index` ends: the "\n", or the "\r" before it in
  # a CRLF file (the new text goes in front of the line ending, not between its
  # two bytes), or the end of the content.
  defp eol_index(content, index) do
    rest = binary_part(content, index, byte_size(content) - index)

    case :binary.match(rest, "\n") do
      {at, _} ->
        if at > 0 and :binary.at(rest, at - 1) == ?\r, do: index + at - 1, else: index + at

      :nomatch ->
        byte_size(content)
    end
  end

  defp newline_between?(text, from, to) do
    from < to and :binary.match(binary_part(text, from, to - from), "\n") != :nomatch
  end

  # Leading whitespace of the line that holds `index`.
  defp line_indent(content, index) do
    from = line_start(content, index)
    line = binary_part(content, from, index - from)
    [indent] = Regex.run(~r/^[ \t]*/, line)
    indent
  end

  defp unit(base), do: if(String.contains?(base, "\t"), do: "\t", else: "  ")

  # --- masking ------------------------------------------------------------
  #
  # One lexer, used twice: at the top level of the file, and inside `#{...}` of
  # a string (the code in an interpolation has comments, strings, character
  # literals and sigils of its own). `token/2` reads one lexical unit; the
  # callers decide what to emit for it.

  defp do_mask(<<>>, _strings?, _prev, acc), do: Enum.reverse(acc)

  defp do_mask(bin, strings?, prev, acc) do
    case token(bin, prev) do
      {:comment, text, rest} ->
        do_mask(rest, strings?, ?\n, [blank(text) | acc])

      {:quoted, open, body, close, rest} ->
        do_mask(rest, strings?, last_byte(close, open), [
          delim_out(close, strings?),
          body_out(body, strings?),
          delim_out(open, strings?) | acc
        ])

      {:char, head, char, rest} ->
        do_mask(rest, strings?, ?x, [body_out(char, strings?), delim_out(head, strings?) | acc])

      {:byte, b, rest} ->
        do_mask(rest, strings?, b, [<<b>> | acc])
    end
  end

  defp last_byte("", open), do: :binary.last(open)
  defp last_byte(close, _open), do: :binary.last(close)

  # `#` comment to the end of the line.
  defp token(<<"#", rest::binary>>, _prev) do
    {text, tail} = take_until_newline(rest)
    {:comment, "#" <> text, tail}
  end

  # Heredoc (`"""`, `'''`).
  defp token(<<q::binary-size(3), rest::binary>>, _prev) when q in ["\"\"\"", "'''"] do
    {body, tail, closed} = take_heredoc(rest, q)
    {:quoted, q, body, closed, tail}
  end

  defp token(<<"\"", rest::binary>>, _prev) do
    {body, tail, closed} = take_quoted(rest, ?", true)
    {:quoted, "\"", body, closed, tail}
  end

  defp token(<<"'", rest::binary>>, _prev) do
    {body, tail, closed} = take_quoted(rest, ?', true)
    {:quoted, "'", body, closed, tail}
  end

  # Sigils: `~w(...)`, `~r/.../`, `~s[...]`, `~S"""`, `~HTML(...)`. Lowercase
  # sigils interpolate, uppercase ones do not.
  defp token(<<"~", rest::binary>>, _prev) do
    case Regex.run(~r/\A([a-z]|[A-Z][A-Z0-9]*)("""|'''|[(\[{<\/|"'])/, rest) do
      [head, name, d] ->
        after_head = binary_part(rest, byte_size(head), byte_size(rest) - byte_size(head))
        interp? = name =~ ~r/\A[a-z]\z/

        {body, tail, closed} =
          if d in ["\"\"\"", "'''"],
            do: take_heredoc(after_head, d),
            else: take_quoted(after_head, closer(d), interp?)

        {:quoted, "~" <> name <> d, body, closed, tail}

      _ ->
        {:byte, ?~, rest}
    end
  end

  # `?x`, `?\x` — a character literal (`?}`, `?"`, `?#`, `?\"`), not a bracket,
  # a quote or a comment. A `?` that ends an identifier (`valid?(x)`) is not one.
  defp token(<<"?", rest::binary>>, prev) do
    cond do
      ident_byte?(prev) -> {:byte, ??, rest}
      match?(<<"\\", _, _::binary>>, rest) -> take_char(rest, 2)
      match?(<<c, _::binary>> when c not in [?\s, ?\t, ?\r, ?\n], rest) -> take_char(rest, 1)
      true -> {:byte, ??, rest}
    end
  end

  defp token(<<b, rest::binary>>, _prev), do: {:byte, b, rest}

  defp take_char(rest, n),
    do: {:char, "?", binary_part(rest, 0, n), binary_part(rest, n, byte_size(rest) - n)}

  # Bytes above 127 are the parts of a multi-byte (non-ASCII) identifier.
  defp ident_byte?(b), do: b in ?a..?z or b in ?A..?Z or b in ?0..?9 or b == ?_ or b > 127

  defp closer(<<?(>>), do: ")"
  defp closer(<<?[>>), do: "]"
  defp closer(<<?{>>), do: "}"
  defp closer(<<?<>>), do: ">"
  defp closer(c), do: c

  defp body_out(body, false), do: body
  defp body_out(body, _blank), do: blank(body)

  # Delimiters stay unless the mask is `strings: :all`.
  defp delim_out(delim, :all), do: blank(delim)
  defp delim_out(delim, _), do: delim

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

  # A heredoc ends at the marker that opens a line (after indentation) — the
  # same marker in the middle of a line is body text. Returns the closing
  # marker only when there was one, so an unterminated run keeps its length.
  defp take_heredoc(bin, marker) do
    case Regex.run(~r/\n[ \t]*#{Regex.escape(marker)}/, bin, return: :index) do
      [{at, len}] ->
        stop = at + len - byte_size(marker)
        {binary_part(bin, 0, stop), binary_part(bin, at + len, byte_size(bin) - at - len), marker}

      nil ->
        {bin, "", ""}
    end
  end

  # Body of a quoted run up to the unescaped `close` (a byte or a one-byte
  # string); returns {body, rest, closing_delimiter_or_""}. With `interp?`,
  # `#{ ... }` is scanned as code, so a quote or a `}` inside an interpolation
  # does not end the run.
  defp take_quoted(bin, close, interp?) when is_integer(close),
    do: take_quoted(bin, <<close>>, interp?, [])

  defp take_quoted(bin, close, interp?) when is_binary(close),
    do: take_quoted(bin, close, interp?, [])

  defp take_quoted(<<>>, _close, _i, acc), do: {join(acc), "", ""}

  defp take_quoted(<<"\\", c, rest::binary>>, close, i, acc),
    do: take_quoted(rest, close, i, [<<"\\", c>> | acc])

  defp take_quoted(<<"\#{", rest::binary>>, close, true, acc) do
    {code, tail} = take_interp(rest, 0, 0, [])
    take_quoted(tail, close, true, [code, "\#{" | acc])
  end

  defp take_quoted(<<c, rest::binary>>, <<c>> = close, _i, acc), do: {join(acc), rest, close}

  defp take_quoted(<<c, rest::binary>>, close, i, acc),
    do: take_quoted(rest, close, i, [<<c>> | acc])

  # Code inside `#{ ... }`, up to and including the matching `}`. It is read
  # with the same lexer, so a `"` in a character literal, a quote inside a
  # comment or a sigil does not confuse it.
  defp take_interp(<<>>, _depth, _prev, acc), do: {join(acc), ""}

  defp take_interp(bin, depth, prev, acc) do
    case token(bin, prev) do
      {:byte, ?}, rest} when depth == 0 ->
        {join(["}" | acc]), rest}

      {:byte, ?}, rest} ->
        take_interp(rest, depth - 1, ?}, ["}" | acc])

      {:byte, ?{, rest} ->
        take_interp(rest, depth + 1, ?{, ["{" | acc])

      {:byte, b, rest} ->
        take_interp(rest, depth, b, [<<b>> | acc])

      {:comment, text, rest} ->
        take_interp(rest, depth, ?\n, [text | acc])

      {:char, head, char, rest} ->
        take_interp(rest, depth, ?x, [char, head | acc])

      {:quoted, open, body, close, rest} ->
        take_interp(rest, depth, ?", [close, body, open | acc])
    end
  end

  defp join(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
end
