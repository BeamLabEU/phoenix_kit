defmodule PhoenixKit.Install.DaisyUI do
  @moduledoc """
  Advisory check of the host's daisyUI version.

  PhoenixKit's UI is styled by daisyUI, which lives in the HOST app and is
  loaded from the host's `app.css`, in one of two shapes:

  - **vendored** — `assets/vendor/daisyui.js` + `daisyui-theme.js`, which
    `mix phx.new` scaffolded before 1.8;
  - **a git dependency** — phx.new 1.8 declares `{:daisyui, github:
    "saadeghi/daisyui", tag: "v…", sparse: "packages/bundle", …}` in
    `mix.exs`, and `app.css` loads `deps/daisyui/packages/bundle/daisyui`.
    The sparse checkout has no `package.json`, but the bundle carries the same
    `version = "…"` marker as the vendored file.

  The vendored file wins when both exist. The host owns either — PhoenixKit
  does not manage or replace it; it only **checks** it.
  `mix phoenix_kit.install`, `mix phoenix_kit.update`, and
  `mix phoenix_kit.doctor` warn when the host's copy is older than
  `minimum_version/0`, with upgrade instructions.

  Why the minimum matters: daisyUI < 5.1 reserves the modal scrollbar gutter
  UNCONDITIONALLY while a modal/drawer is open, which either leaves a phantom
  right-edge strip on non-scrolling pages or (when countered) makes content
  reflow ~15px around every modal open/close on scrolling pages. daisyUI
  ≥ 5.1 reserves the gutter only when the page really has a scrollbar
  (`rootscrollgutter.css`), and 5.6.0 finished the job for modals
  (`scrollbar-gutter: auto`), so PhoenixKit ships **no** scrollbar-gutter
  compensations of its own (removed 2026-07-12) and relies on a modern
  daisyUI instead.

  ## Two warning bands

  Those are two different situations, and `outdated_warning/1` says so
  (`severity/1` picks the copy):

  - `:broken` — below `gutter_fix_version/0` (5.1.0). Modals genuinely
    misbehave; upgrading is the fix.
  - `:behind` — at/above 5.1.0 but below `minimum_version/0`. Modals render
    correctly; the host is simply short of the version core is verified
    against. Purely a heads-up — notably, `mix phx.new` currently vendors
    5.5.19, so a *freshly scaffolded* app lands in this band and must not be
    told it has a rendering bug.
  """

  # The oldest daisyUI whose modal scrollbar-gutter handling PhoenixKit's
  # modals rely on. The upstream fix matured across 5.1.0 → 5.6.x; PhoenixKit
  # is verified against 5.6.17, and 5.6.0 is the floor we recommend.
  #
  # Raise this ONLY for a daisyUI behavior core actually depends on — not to
  # track the newest release. Every bump widens the gap against what
  # `mix phx.new` vendors, and a warning that fires on a clean install is a
  # warning hosts learn to ignore.
  @minimum_version "5.6.0"

  # Where daisyUI made the modal scrollbar gutter conditional
  # (`rootscrollgutter.css`) — the boundary between "modals are visibly
  # broken" and "merely older than we test against".
  @gutter_fix_version "5.1.0"

  @vendored_path ["assets", "vendor", "daisyui.js"]
  @dep_path ["deps", "daisyui", "packages", "bundle", "daisyui.js"]

  @dep_upgrade_steps """
  Bump the `tag:` of the :daisyui dependency in mix.exs, then:

      mix deps.update daisyui
      mix assets.build

  Changelog: https://daisyui.com/docs/changelog/
  """

  @upgrade_steps """
  Update the two files in assets/vendor/ and rebuild assets:

      cd assets/vendor
      curl -sLO https://github.com/saadeghi/daisyui/releases/latest/download/daisyui.js
      curl -sLO https://github.com/saadeghi/daisyui/releases/latest/download/daisyui-theme.js

  Changelog: https://daisyui.com/docs/changelog/
  """

  @doc "The minimum daisyUI version PhoenixKit's UI is designed against."
  @spec minimum_version() :: String.t()
  def minimum_version, do: @minimum_version

  @doc """
  The daisyUI version that made the modal scrollbar gutter conditional.

  Below this, modals visibly misbehave; at or above it they render correctly
  even when the copy is older than `minimum_version/0`.
  """
  @spec gutter_fix_version() :: String.t()
  def gutter_fix_version, do: @gutter_fix_version

  @doc """
  The host-side path of the daisyUI plugin the check reads: the vendored file
  when it exists, else the git dependency's bundle when that exists, else the
  vendored path (which then reports `:missing`).
  """
  @spec host_path(Path.t()) :: Path.t()
  def host_path(root \\ File.cwd!()) do
    vendored = Path.join([root | @vendored_path])
    dep = Path.join([root | @dep_path])

    cond do
      File.exists?(vendored) -> vendored
      File.exists?(dep) -> dep
      true -> vendored
    end
  end

  @doc "Whether `path` is the git dependency's bundle (`:dep`) or a vendored copy."
  @spec source(Path.t()) :: :dep | :vendored
  def source(path) do
    if String.ends_with?(path, Path.join(@dep_path)), do: :dep, else: :vendored
  end

  @doc """
  Parse the daisyUI version out of a plugin bundle, or `nil` when the file is
  missing or carries no `version = "x.y.z"` marker.
  """
  @spec installed_version(Path.t()) :: String.t() | nil
  def installed_version(path) do
    with {:ok, content} <- File.read(path),
         [_, version] <- Regex.run(~r/version = "([\d.]+)"/, content) do
      version
    else
      _ -> nil
    end
  end

  @doc """
  Check the host's vendored daisyUI against `minimum_version/0`.

  - `:ok` — present and at/above the minimum
  - `{:outdated, version}` — present but older than the minimum
  - `:unversioned` — present but carries no parseable version marker
  - `:missing` — neither `assets/vendor/daisyui.js` nor the git dependency's
    bundle (npm or custom setup)

  `root` is the host project directory (default: the current directory).
  """
  @spec check(Path.t()) :: :ok | {:outdated, String.t()} | :unversioned | :missing
  def check(root \\ File.cwd!()) do
    path = host_path(root)

    cond do
      not File.exists?(path) ->
        :missing

      version = installed_version(path) ->
        if outdated?(version), do: {:outdated, version}, else: :ok

      true ->
        :unversioned
    end
  end

  @doc "Whether a daisyUI version string is below `minimum_version/0`."
  @spec outdated?(String.t()) :: boolean()
  def outdated?(version) when is_binary(version) do
    case {Version.parse(version), Version.parse(@minimum_version)} do
      {{:ok, installed}, {:ok, minimum}} -> Version.compare(installed, minimum) == :lt
      # Unparseable → don't claim it's outdated; check/0 reports :unversioned.
      _ -> false
    end
  end

  @doc """
  How bad an outdated version actually is.

  - `:broken` — below `gutter_fix_version/0`; modals mishandle the gutter.
  - `:behind` — older than `minimum_version/0` but rendering correctly.

  Unparseable versions get the benign verdict — never accuse a host of a
  rendering bug we could not confirm.
  """
  @spec severity(String.t()) :: :broken | :behind
  def severity(version) when is_binary(version) do
    case {Version.parse(version), Version.parse(@gutter_fix_version)} do
      {{:ok, installed}, {:ok, gutter_fix}} ->
        if Version.compare(installed, gutter_fix) == :lt, do: :broken, else: :behind

      _ ->
        :behind
    end
  end

  @doc """
  Human warning for an outdated vendored daisyUI, with upgrade steps.

  The copy follows `severity/1`: a real bug report below
  `gutter_fix_version/0`, an advisory heads-up above it.
  """
  @spec outdated_warning(String.t(), Path.t()) :: String.t()
  def outdated_warning(version, path \\ host_path()) when is_binary(version) do
    source = source(path)
    warning(severity(version), version, label(source), steps(source))
  end

  @doc "How the daisyUI copy is named in messages, by `source/1`."
  @spec label(:dep | :vendored) :: String.t()
  def label(:dep), do: "daisyUI dependency (deps/daisyui)"
  def label(:vendored), do: "vendored daisyUI"

  @doc "The one-line upgrade hint for the copy's source, for the doctor."
  @spec upgrade_hint(:dep | :vendored) :: String.t()
  def upgrade_hint(:dep),
    do: "Bump the :daisyui dependency's tag in mix.exs, run `mix deps.update daisyui`"

  def upgrade_hint(:vendored),
    do:
      "Update assets/vendor/daisyui.js + daisyui-theme.js from " <>
        "https://github.com/saadeghi/daisyui/releases"

  defp steps(:dep), do: @dep_upgrade_steps
  defp steps(:vendored), do: @upgrade_steps

  defp warning(:broken, version, label, steps) do
    """
    ⚠️  Your #{label} is #{version}; PhoenixKit is designed against #{@minimum_version}+.
    On daisyUI < #{@gutter_fix_version}, opening any modal/drawer mishandles the scrollbar
    gutter (a phantom right-edge strip, or content shifting ~15px on scrolling
    pages). Upgrading is the fix.

    #{steps}
    """
  end

  defp warning(:behind, version, label, steps) do
    """
    ⚠️  Your #{label} is #{version}; PhoenixKit is verified against #{@minimum_version}+.
    Your copy already handles the modal scrollbar gutter correctly (daisyUI
    #{@gutter_fix_version}+), so this is a heads-up, not a bug report — nothing is broken.
    Upgrade when convenient to match the version core is tested against.

    #{steps}
    """
  end
end
