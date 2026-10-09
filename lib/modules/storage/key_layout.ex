defmodule PhoenixKit.Modules.Storage.KeyLayout do
  @moduledoc """
  How deep a storage profile fans its keys out (`StorageProfile.key_levels`, V216).

  A file's folder is `<prefix>/<md5>`, with `levels` two-character hash folders
  between them:

      0   lib-1a2b3c/22e8b90781bab72967f9d5410b4299f9/…
      1   lib-1a2b3c/22/22e8b90781bab72967f9d5410b4299f9/…        (the layout so far)
      2   lib-1a2b3c/22/e8/22e8b90781bab72967f9d5410b4299f9/…
      3   lib-1a2b3c/22/e8/b9/22e8b90781bab72967f9d5410b4299f9/…

  Each hash folder has 256 possible names, and MD5 spreads files evenly over
  them, so `n` files leave about `n / 256^levels` file folders in each folder at
  the deepest level. That number is what a local disk feels (listing, backups,
  `rsync`); an object store has no folders and does not care. The layout applies
  to new uploads: a file's folder is stored on its row, so nothing already
  uploaded moves.
  """

  @levels [0, 1, 2, 3]
  @default 1
  @fanout 256

  # Folders per directory up to which listing and backing up stay quick, and up
  # to which a disk still copes. Judgement calls, in one place.
  @comfortable 5_000
  @tolerable 50_000

  @doc "The layouts a profile may choose: the number of hash folders."
  @spec levels() :: [0..3]
  def levels, do: @levels

  @doc "The layout every profile had before it could be chosen (V216)."
  @spec default() :: 1
  def default, do: @default

  @doc "Whether `levels` is a layout."
  @spec valid?(term()) :: boolean()
  def valid?(levels), do: levels in @levels

  @doc """
  The folder of a file: `prefix`, `levels` hash folders, then the MD5.

      iex> PhoenixKit.Modules.Storage.KeyLayout.path("lib-1a2b", "22e8b907", 0)
      "lib-1a2b/22e8b907"
      iex> PhoenixKit.Modules.Storage.KeyLayout.path("lib-1a2b", "22e8b907", 1)
      "lib-1a2b/22/22e8b907"
      iex> PhoenixKit.Modules.Storage.KeyLayout.path("lib-1a2b", "22e8b907", 2)
      "lib-1a2b/22/e8/22e8b907"
  """
  @spec path(String.t(), String.t(), non_neg_integer()) :: String.t()
  def path(prefix, md5, levels) when levels in @levels do
    folders = for i <- 0..(levels - 1)//1, do: String.slice(md5, i * 2, 2)
    Enum.join([prefix | folders] ++ [md5], "/")
  end

  def path(prefix, md5, _levels), do: path(prefix, md5, @default)

  @doc """
  About how many file folders the busiest folder holds once a library has `files`
  files, under `levels`.

      iex> PhoenixKit.Modules.Storage.KeyLayout.per_folder(1_000_000, 1)
      3907
      iex> PhoenixKit.Modules.Storage.KeyLayout.per_folder(1_000_000, 0)
      1000000
  """
  @spec per_folder(non_neg_integer(), 0..3) :: non_neg_integer()
  def per_folder(files, levels), do: ceil(files / Integer.pow(@fanout, levels))

  @doc "How a folder of `per_folder` entries fares: `:comfortable`, `:slow` or `:too_many`."
  @spec rating(non_neg_integer()) :: :comfortable | :slow | :too_many
  def rating(per_folder) when per_folder <= @comfortable, do: :comfortable
  def rating(per_folder) when per_folder <= @tolerable, do: :slow
  def rating(_per_folder), do: :too_many

  @doc "The library sizes the Storage profiles tab compares."
  @spec sizes() :: [pos_integer()]
  def sizes, do: [10_000, 100_000, 1_000_000, 10_000_000, 100_000_000]

  @doc """
  One row per library size: `{files, per_folder, rating}` under `levels`.
  """
  @spec table(0..3) :: [{pos_integer(), non_neg_integer(), atom()}]
  def table(levels) do
    for files <- sizes() do
      per = per_folder(files, levels)
      {files, per, rating(per)}
    end
  end

  @doc "The number of files at which `levels` stops being comfortable."
  @spec comfortable_up_to(0..3) :: pos_integer()
  def comfortable_up_to(levels), do: @comfortable * Integer.pow(@fanout, levels)
end
