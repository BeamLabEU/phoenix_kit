defmodule Mix.Tasks.PhoenixKit.MigrateBlogVersions do
  @shortdoc "Legacy task — filesystem storage has been removed"
  @moduledoc """
  This task previously migrated blog posts from flat to versioned folder structure.

  Filesystem storage has been removed — all content is now in the database.
  This task is no longer needed and is kept only as a no-op stub.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("""
    This task migrated legacy filesystem blog posts to versioned folder structure.
    Filesystem storage has been removed — all content is now in the database.
    This task is no longer needed.
    """)
  end
end
