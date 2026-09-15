defmodule PhoenixKit.Modules.Storage.Reorganizer.Action do
  @moduledoc """
  The one action shape `PhoenixKit.Modules.Storage.Reorganizer` understands.

  A `Source` returns plain maps (so a module can build them without
  compiling against this module — see `Source`'s moduledoc). `new!/1`
  validates the shape and fills defaults for anything the source left out;
  the engine works with the normalized result from here on.
  """

  alias PhoenixKit.Modules.Storage.Folder

  require Logger

  @type op :: :move | :trash | :report
  @type on_conflict :: :suffix | :report

  @type t :: %{
          required(:source) => String.t(),
          required(:kind) => atom(),
          required(:label) => String.t(),
          required(:op) => op(),
          optional(:folder) => %Folder{} | nil,
          optional(:parent_uuid) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:counts) => {non_neg_integer(), non_neg_integer()} | nil,
          optional(:on_conflict) => on_conflict(),
          optional(:after_move) => (-> :ok | {:error, term()}) | nil,
          optional(:reason) => String.t() | nil,
          optional(:outcome) => atom(),
          optional(:error) => term()
        }

  @required_keys [:source, :kind, :label, :op]
  @valid_ops [:move, :trash, :report]
  @valid_on_conflict [:suffix, :report]

  @defaults %{
    folder: nil,
    parent_uuid: nil,
    name: nil,
    counts: nil,
    on_conflict: :report,
    after_move: nil,
    reason: nil
  }

  @known_keys @required_keys ++ Map.keys(@defaults) ++ [:outcome, :error]

  # Matches an accepted `"name (N)"` variant of a base name, e.g. "Item (2)".
  @suffix_regex ~r/^(?<base>.+) \((?<n>\d+)\)$/

  @doc """
  Validates a plain map from a `Source`, raising `ArgumentError` naming the
  offending key on any problem, and fills defaults for keys the source
  didn't set.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    Enum.each(@required_keys, fn key ->
      if not Map.has_key?(attrs, key) do
        raise ArgumentError, "Reorganizer.Action missing required key #{inspect(key)}"
      end
    end)

    validate_field_type!(attrs, :source, &is_binary/1, "a String.t()")
    validate_field_type!(attrs, :kind, &is_atom/1, "an atom")
    validate_field_type!(attrs, :label, &is_binary/1, "a String.t()")

    attrs = drop_unknown_keys(attrs)

    validate_after_move!(attrs)

    op = Map.fetch!(attrs, :op)

    if op not in @valid_ops do
      raise ArgumentError,
            "Reorganizer.Action invalid :op #{inspect(op)} (expected one of #{inspect(@valid_ops)})"
    end

    on_conflict = Map.get(attrs, :on_conflict, :report)

    if on_conflict not in @valid_on_conflict do
      raise ArgumentError,
            "Reorganizer.Action invalid :on_conflict #{inspect(on_conflict)} " <>
              "(expected one of #{inspect(@valid_on_conflict)})"
    end

    @defaults
    |> Map.merge(attrs)
    |> Map.put(:on_conflict, on_conflict)
  end

  # An `after_move` that isn't a 0-arity function (or `nil`) can never be
  # called by `run_after_move/1` — without this check it silently falls
  # through `noop?/1`'s folder-position check instead (a mis-shaped
  # `after_move` on an already-in-place folder was dropped as a noop and
  # never reported at all).
  defp validate_after_move!(attrs) do
    case Map.get(attrs, :after_move) do
      nil ->
        :ok

      fun when is_function(fun, 0) ->
        :ok

      other ->
        raise ArgumentError,
              "Reorganizer.Action :after_move must be nil or a 0-arity function, got: " <>
                inspect(other)
    end
  end

  defp validate_field_type!(attrs, key, predicate, expected) do
    value = Map.fetch!(attrs, key)

    unless predicate.(value) do
      raise ArgumentError,
            "Reorganizer.Action #{inspect(key)} must be #{expected}, got: #{inspect(value)}"
    end
  end

  # Unknown keys are dropped (with a warning), never raised on — a Source
  # from a newer module release may carry a key this (older) core doesn't
  # know about yet; raising here would break the decoupling the plain-map
  # action shape exists for (forward compatibility).
  defp drop_unknown_keys(attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @known_keys)) do
      [] ->
        attrs

      unknown_keys ->
        Logger.warning(
          "[Reorganizer] dropping unknown Action key(s) #{inspect(unknown_keys)} " <>
            "from source #{inspect(Map.get(attrs, :source))}"
        )

        Map.drop(attrs, unknown_keys)
    end
  end

  @doc """
  A `:move` action is a no-op when the folder it targets already sits at the
  wanted `parent_uuid` with the wanted `name` (or an accepted `"name (N)"`
  variant of it — matches the previous run's own suffix-on-collision output,
  so re-running `plan/2` doesn't propose renaming it back and forth). A `nil`
  `name` means "keep the current name", so it always matches.

  An action carrying `after_move` is never a noop, even when the folder is
  already in place: the folder position matching doesn't mean the pointer
  back-fill it exists to run has happened — the engine still needs to apply
  it (see `PhoenixKit.Modules.Storage.Reorganizer`'s move path, which skips
  `update_folder` but still runs `after_move` in that case).

  A trashed folder is never a noop either, even when its parent/name already
  match: restoring it is itself a change the engine must apply (outcome
  `:restored` when nothing else about it changes).
  """
  @spec noop?(t()) :: boolean()
  def noop?(%{op: :move, after_move: fun}) when is_function(fun, 0), do: false

  def noop?(%{op: :move, folder: %Folder{trashed_at: trashed_at}}) when not is_nil(trashed_at),
    do: false

  def noop?(%{op: :move, folder: %Folder{} = folder} = action) do
    parent_uuid = Map.get(action, :parent_uuid)
    name = Map.get(action, :name)

    folder.parent_uuid == parent_uuid and matches_name?(folder.name, name)
  end

  def noop?(_action), do: false

  @doc false
  # Shared with the engine, which uses the same rule to decide whether a
  # folder's current name already satisfies the wanted name (skip renaming)
  # or needs updating.
  @spec matches_name?(String.t(), String.t() | nil) :: boolean()
  def matches_name?(_current, nil), do: true
  def matches_name?(current, current), do: true

  def matches_name?(current, wanted) do
    case Regex.named_captures(@suffix_regex, current) do
      %{"base" => ^wanted} -> true
      _ -> false
    end
  end
end
