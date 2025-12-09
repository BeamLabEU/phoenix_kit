defmodule PhoenixKit.Pages.FileOperations do
  @moduledoc """
  Filesystem operations for Pages module.

  Handles reading, writing, listing files and folders.
  """

  alias PhoenixKit.Pages.Paths

  @doc """
  Lists all files and folders in a directory.

  Returns a list of maps with name, type (:file or :folder), and path.

  ## Examples

      iex> FileOperations.list_directory("/")
      {:ok, [
        %{name: "blog", type: :folder, path: "/blog"},
        %{name: "hello.md", type: :file, path: "/hello.md"}
      ]}
  """
  def list_directory(relative_path \\ "/") do
    full_path = Paths.build_full_path(relative_path)

    # Debug logging
    require Logger
    Logger.debug("Pages list_directory: full_path=#{inspect(full_path)}")

    case File.ls(full_path) do
      {:ok, entries} ->
        Logger.debug(
          "Pages list_directory: found #{length(entries)} entries: #{inspect(entries)}"
        )

        items =
          entries
          |> Enum.map(fn entry ->
            entry_path = Path.join(full_path, entry)
            relative = Path.join(relative_path, entry)

            type =
              case File.dir?(entry_path) do
                true -> :folder
                false -> :file
              end

            %{
              name: entry,
              type: type,
              path: relative,
              full_path: entry_path
            }
          end)
          |> Enum.sort_by(fn item ->
            # Folders first, then files, alphabetically
            {item.type != :folder, String.downcase(item.name)}
          end)

        {:ok, items}

      {:error, reason} ->
        Logger.debug("Pages list_directory: error #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Reads file content.

  ## Examples

      iex> FileOperations.read_file("/hello.md")
      {:ok, "# Hello World"}
  """
  def read_file(relative_path) do
    full_path = Paths.build_full_path(relative_path)
    File.read(full_path)
  end

  @doc """
  Returns the absolute filesystem path for a relative page path.
  """
  def absolute_path(relative_path) do
    Paths.build_full_path(relative_path)
  end

  @doc """
  Writes content to a file.

  Creates parent directories if they don't exist.

  ## Examples

      iex> FileOperations.write_file("/hello.md", "# Hello World")
      :ok
  """
  def write_file(relative_path, content) do
    full_path = Paths.build_full_path(relative_path)

    # Ensure parent directory exists
    full_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write(full_path, content)
  end

  @doc """
  Creates a new directory.

  ## Examples

      iex> FileOperations.create_directory("/blog")
      :ok
  """
  def create_directory(relative_path) do
    full_path = Paths.build_full_path(relative_path)
    File.mkdir_p(full_path)
  end

  @doc """
  Checks if a path exists (file or folder).

  ## Examples

      iex> FileOperations.exists?("/hello.md")
      true
  """
  def exists?(relative_path) do
    full_path = Paths.build_full_path(relative_path)
    File.exists?(full_path)
  end

  @doc """
  Checks if a file (not folder) exists at the path.

  ## Examples

      iex> FileOperations.file_exists?("/hello.md")
      true

      iex> FileOperations.file_exists?("/blog")
      false
  """
  def file_exists?(relative_path) do
    full_path = Paths.build_full_path(relative_path)
    File.exists?(full_path) and not File.dir?(full_path)
  end

  @doc """
  Checks if a directory exists at the path.

  ## Examples

      iex> FileOperations.directory_exists?("/blog")
      true

      iex> FileOperations.directory_exists?("/hello.md")
      false
  """
  def directory_exists?(relative_path) do
    full_path = Paths.build_full_path(relative_path)
    File.dir?(full_path)
  end

  @doc """
  Gets file info (size, modified time, etc).

  ## Examples

      iex> FileOperations.file_info("/hello.md")
      {:ok, %{size: 1024, mtime: ~U[2025-01-01 00:00:00Z]}}
  """
  def file_info(relative_path) do
    full_path = Paths.build_full_path(relative_path)

    case File.stat(full_path) do
      {:ok, stat} ->
        {:ok,
         %{
           size: stat.size,
           mtime: stat.mtime,
           type: stat.type
         }}

      error ->
        error
    end
  end

  @doc """
  Deletes a file or directory.

  Directories are deleted recursively.

  ## Examples

      iex> FileOperations.delete("/hello.md")
      :ok

      iex> FileOperations.delete("/blog")
      :ok
  """
  def delete(relative_path) do
    full_path = Paths.build_full_path(relative_path)

    cond do
      File.dir?(full_path) ->
        File.rm_rf(full_path)

      File.exists?(full_path) ->
        File.rm(full_path)

      true ->
        {:error, :enoent}
    end
  end

  @doc """
  Copies a file to a new location.

  Creates parent directories if they don't exist.

  ## Examples

      iex> FileOperations.copy("/hello.md", "/blog/hello.md")
      :ok
  """
  def copy(source_path, dest_path) do
    source_full = Paths.build_full_path(source_path)
    dest_full = Paths.build_full_path(dest_path)

    # Only allow copying files, not directories
    if File.dir?(source_full) do
      {:error, :eisdir}
    else
      # Ensure destination parent directory exists
      dest_full
      |> Path.dirname()
      |> File.mkdir_p!()

      File.copy(source_full, dest_full)
    end
  end

  @doc """
  Moves a file or directory to a new location.

  Creates parent directories if they don't exist.

  ## Examples

      iex> FileOperations.move("/hello.md", "/blog/hello.md")
      :ok
  """
  def move(source_path, dest_path) do
    source_full = Paths.build_full_path(source_path)
    dest_full = Paths.build_full_path(dest_path)

    # Ensure destination parent directory exists
    dest_full
    |> Path.dirname()
    |> File.mkdir_p!()

    File.rename(source_full, dest_full)
  end

  @doc """
  Counts files and folders inside a directory recursively.

  Returns a map with :files and :folders counts.

  ## Examples

      iex> FileOperations.count_contents("/blog")
      %{files: 5, folders: 2}
  """
  def count_contents(relative_path) do
    full_path = Paths.build_full_path(relative_path)

    if File.dir?(full_path) do
      do_count_contents(full_path)
    else
      %{files: 0, folders: 0}
    end
  end

  defp do_count_contents(dir_path) do
    case File.ls(dir_path) do
      {:ok, entries} ->
        Enum.reduce(entries, %{files: 0, folders: 0}, fn entry, acc ->
          entry_path = Path.join(dir_path, entry)

          if File.dir?(entry_path) do
            # It's a folder, count it and recurse
            subfolder_counts = do_count_contents(entry_path)

            %{
              files: acc.files + subfolder_counts.files,
              folders: acc.folders + 1 + subfolder_counts.folders
            }
          else
            # It's a file, count it
            %{acc | files: acc.files + 1}
          end
        end)

      {:error, _reason} ->
        %{files: 0, folders: 0}
    end
  end

  @doc """
  Generates a unique filename by adding a number suffix if needed.

  ## Examples

      iex> FileOperations.generate_unique_name("/hello.md")
      "/hello-2.md"  # if /hello.md exists

      iex> FileOperations.generate_unique_name("/blog")
      "/blog-2"  # if /blog exists
  """
  def generate_unique_name(relative_path) do
    if exists?(relative_path) do
      do_generate_unique_name(relative_path, 2)
    else
      relative_path
    end
  end

  defp do_generate_unique_name(relative_path, counter) do
    # Handle both files and directories
    {base, ext} =
      if Path.extname(relative_path) != "" do
        # File with extension
        {Path.rootname(relative_path), Path.extname(relative_path)}
      else
        # Directory or file without extension
        {relative_path, ""}
      end

    new_path = "#{base}-#{counter}#{ext}"

    if exists?(new_path) do
      do_generate_unique_name(relative_path, counter + 1)
    else
      new_path
    end
  end
end
