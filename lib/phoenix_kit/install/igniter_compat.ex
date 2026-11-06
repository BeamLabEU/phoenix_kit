defmodule PhoenixKit.Install.IgniterCompat do
  @moduledoc false

  @igniter_modules [
    Igniter,
    Igniter.Libs.Ecto,
    Igniter.Libs.Phoenix,
    Igniter.Project.Application,
    Igniter.Project.Config,
    Igniter.Project.Deps,
    Igniter.Project.Module,
    Igniter.Project.MixProject,
    Igniter.Code.Common,
    Igniter.Code.Function,
    Igniter.Code.List
  ]

  @rewrite_modules [
    Rewrite,
    Rewrite.Source
  ]

  @modules @igniter_modules ++ @rewrite_modules

  defmacro __using__(_opts) do
    quote do
      @compile {:no_warn_undefined, unquote(@modules)}
    end
  end

  # Whether igniter was available the last time this app was compiled. A dozen
  # modules and four mix tasks are now defined behind `Code.ensure_loaded?`
  # checks, and a capability guard baked at compile time goes stale silently:
  # a user who hits "task could not be found", adds `{:igniter, ...}` and runs
  # `mix deps.get` gets NO recompile of phoenix_kit — its own lock entry never
  # changed — so the task is still missing and the obvious next step (running
  # the task again) reproduces the same error.
  #
  # Mix calls `__mix_recompile__?/0` on every module that exports it, so this
  # module (which is always compiled, igniter or not) is where the check
  # belongs. Same technique the router uses for discovered module routes.
  @igniter_available Code.ensure_loaded?(Igniter.Mix.Task)

  @doc false
  def __mix_recompile__? do
    Code.ensure_loaded?(Igniter.Mix.Task) != @igniter_available
  end
end
