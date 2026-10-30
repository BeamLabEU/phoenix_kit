defmodule PhoenixKit.Migrations.Repair.CheckExpression do
  @moduledoc """
  Structural equality of two CHECK (or exclusion) definitions, as
  `pg_get_constraintdef` renders them.

  A CHECK keeps the parse tree of the SQL that created it, and
  `pg_get_constraintdef` prints that tree, so one condition can print in more
  than one way. `a BETWEEN 1 AND 5 AND b BETWEEN 1 AND 5` is stored as
  `AND(AND(a >= 1, a <= 5), AND(b ...))`. Hand that printed text back to the
  parser (a `pg_dump` restore does, as does an `ALTER TABLE .. ADD CONSTRAINT`
  written from it) and the stored tree is `AND(a >= 1, a <= 5, AND(b ...))`,
  because the parser folds a chain whose first operand is itself an `AND` into
  one. The text of the two differs only in where the parentheses sit, and
  comparing it would call a healthy database `wrong_shape`.

  `equivalent?/2` compares the *meaning* of the boolean structure instead:

    * `AND` / `OR` chains are flattened, because both are associative. An
      operand that is itself a chain of the same connective is spliced into its
      parent: `((a AND b) AND c)` equals `(a AND b AND c)`.
    * Parentheses that wrap one whole expression are redundant and dropped:
      `((x > 0))` equals `(x > 0)`, `(a) AND (b)` equals `a AND b`.
    * Whitespace between tokens is irrelevant.

  Nothing else is touched. The order of the operands matters, parentheses
  around an operand of an arithmetic operator stay (they can change the value),
  parentheses around a comma list stay (a row is not a list of arguments), and
  `AND` / `OR` are never mixed up: `(a OR b) AND c` and `a OR (b AND c)` stay
  different. The tokens themselves — names, numbers, literals, operators, casts —
  are compared exactly, string literals and quoted identifiers as one token each;
  only the keywords `AND`, `OR` and `BETWEEN` are matched without regard to case.
  Text this module cannot parse (unbalanced parentheses, an unterminated literal,
  an empty operand, an `E'..'` string with backslash escapes) is equivalent only
  to identical text.
  """

  @type tree ::
          {:and, [tree()]}
          | {:or, [tree()]}
          | {:seq, [String.t() | {:paren, tree()}]}

  # Characters that make up an operator token (`>=`, `<>`, `||`, `->>`, ...).
  @operator_chars ~c"<>=!+-*/%^|&~#@?`"

  # Characters that end a bare word. A word is a name, a keyword or a number.
  @word_delimiters [?\s, ?\t, ?\n, ?\r, ?(, ?), ?,, ?[, ?], ?', ?", ?:] ++ @operator_chars

  @doc """
  True when `left` and `right` are the same condition up to the parenthesisation
  and spacing described in the moduledoc.
  """
  @spec equivalent?(String.t(), String.t()) :: boolean()
  def equivalent?(left, right) when is_binary(left) and is_binary(right) do
    left == right or
      case {canonical(left), canonical(right)} do
        {{:ok, tree}, {:ok, tree}} -> true
        _ -> false
      end
  end

  @doc """
  The canonical tree of `text`, or `:error` when it cannot be parsed.

  Two texts are equivalent exactly when their canonical trees are equal.
  """
  @spec canonical(String.t()) :: {:ok, tree()} | :error
  def canonical(text) when is_binary(text) do
    with {:ok, tokens} <- tokenize(text, []),
         {:ok, [_ | _] = nodes, []} <- group(tokens, [], 0) do
      {:ok, canon(nodes)}
    else
      _ -> :error
    end
  catch
    :throw, :empty_operand -> :error
  end

  # -- tokenizer ---------------------------------------------------------------

  defp tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest, acc)

  defp tokenize(<<?(, rest::binary>>, acc), do: tokenize(rest, [:open | acc])
  defp tokenize(<<?), rest::binary>>, acc), do: tokenize(rest, [:close | acc])

  defp tokenize(<<c, rest::binary>>, acc) when c in [?,, ?[, ?]],
    do: tokenize(rest, [<<c>> | acc])

  defp tokenize(<<quote_char, rest::binary>>, acc) when quote_char in [?', ?"] do
    case quoted(rest, quote_char, <<quote_char>>) do
      {:ok, literal, rest} -> tokenize(rest, [literal | acc])
      :error -> :error
    end
  end

  defp tokenize(<<?:, ?:, rest::binary>>, acc), do: tokenize(rest, ["::" | acc])
  defp tokenize(<<?:, rest::binary>>, acc), do: tokenize(rest, [":" | acc])

  defp tokenize(<<c, _::binary>> = text, acc) when c in @operator_chars do
    {operator, rest} = take(text, @operator_chars, "")
    tokenize(rest, [operator | acc])
  end

  defp tokenize(text, acc) do
    case take_word(text, "") do
      # `E'..'` reads backslash escapes, which this tokenizer does not.
      {word, <<?', _::binary>>} when word in ["E", "e"] -> :error
      {word, rest} -> tokenize(rest, [word | acc])
    end
  end

  defp take(<<c, rest::binary>>, chars, acc) do
    if c in chars, do: take(rest, chars, <<acc::binary, c>>), else: {acc, <<c, rest::binary>>}
  end

  defp take(<<>>, _chars, acc), do: {acc, <<>>}

  defp take_word(<<c, rest::binary>>, acc) when c not in @word_delimiters,
    do: take_word(rest, <<acc::binary, c>>)

  defp take_word(rest, acc), do: {acc, rest}

  # A quoted run, with the doubled quote character as its escape (`'it''s'`).
  defp quoted(<<c, d, rest::binary>>, quote_char, acc) when c == quote_char and d == quote_char,
    do: quoted(rest, quote_char, <<acc::binary, c, d>>)

  defp quoted(<<c, rest::binary>>, quote_char, acc) when c == quote_char,
    do: {:ok, <<acc::binary, c>>, rest}

  defp quoted(<<c, rest::binary>>, quote_char, acc),
    do: quoted(rest, quote_char, <<acc::binary, c>>)

  defp quoted(<<>>, _quote_char, _acc), do: :error

  # -- parenthesis tree --------------------------------------------------------

  # Returns {:ok, nodes, rest}; `rest` is what follows the closing parenthesis
  # of a group and is always [] at depth 0.
  defp group([], acc, 0), do: {:ok, Enum.reverse(acc), []}
  defp group([], _acc, _depth), do: :error
  defp group([:close | rest], acc, depth) when depth > 0, do: {:ok, Enum.reverse(acc), rest}
  defp group([:close | _], _acc, 0), do: :error

  defp group([:open | rest], acc, depth) do
    with {:ok, inner, rest} <- group(rest, [], depth + 1) do
      group(rest, [{:group, inner} | acc], depth)
    end
  end

  defp group([token | rest], acc, depth), do: group(rest, [token | acc], depth)

  # -- canonical form ----------------------------------------------------------

  defp canon(nodes) do
    case split(nodes, "OR") do
      [_, _ | _] = parts -> {:or, flatten(:or, parts |> operands!() |> Enum.map(&canon/1))}
      _ -> canon_and(nodes)
    end
  end

  defp canon_and(nodes) do
    case split(nodes, "AND") do
      [_, _ | _] = parts -> {:and, flatten(:and, parts |> operands!() |> Enum.map(&canon/1))}
      _ -> canon_operand(nodes)
    end
  end

  # `a AND` and `AND a` are not conditions.
  defp operands!(parts) do
    if Enum.any?(parts, &(&1 == [])), do: throw(:empty_operand), else: parts
  end

  # One whole expression in parentheses is the expression, unless the
  # parentheses hold a comma list: `f((a, b))` is one row argument, `f(a, b)`
  # two arguments, and `x IN ((1, 2))` compares a row.
  defp canon_operand([{:group, inner}] = nodes) do
    if inner != [] and not top_level_comma?(inner), do: canon(inner), else: seq(nodes)
  end

  defp canon_operand(nodes), do: seq(nodes)

  defp seq(nodes), do: {:seq, Enum.map(nodes, &canon_item/1)}

  # A comma outside any `[..]`; commas inside a group are that group's.
  defp top_level_comma?(nodes) do
    comma? =
      Enum.reduce_while(nodes, 0, fn
        "[", depth -> {:cont, depth + 1}
        "]", depth -> {:cont, max(depth - 1, 0)}
        ",", 0 -> {:halt, :comma}
        _node, depth -> {:cont, depth}
      end)

    comma? == :comma
  end

  defp canon_item({:group, inner}), do: {:paren, canon(inner)}
  defp canon_item(token), do: token

  defp flatten(connective, trees) do
    Enum.flat_map(trees, fn
      {^connective, operands} -> operands
      tree -> [tree]
    end)
  end

  # Splits the top level of `nodes` at the keyword `connective` (`"AND"` or
  # `"OR"`). The `AND` that belongs to a `BETWEEN` is not a connective.
  defp split(nodes, connective) do
    {parts, current, _between?} =
      Enum.reduce(nodes, {[], [], false}, fn
        token, {parts, current, between?} when is_binary(token) ->
          split_token(String.upcase(token), token, connective, {parts, current, between?})

        node, {parts, current, between?} ->
          {parts, [node | current], between?}
      end)

    Enum.reverse([Enum.reverse(current) | parts])
  end

  defp split_token("BETWEEN", token, "AND", {parts, current, _between?}),
    do: {parts, [token | current], true}

  defp split_token("AND", token, "AND", {parts, current, true}),
    do: {parts, [token | current], false}

  defp split_token(keyword, _token, keyword, {parts, current, _between?}),
    do: {[Enum.reverse(current) | parts], [], false}

  defp split_token(_upper, token, _connective, {parts, current, between?}),
    do: {parts, [token | current], between?}
end
