defmodule PhoenixKit.Users.AvatarShape do
  @moduledoc """
  The shape every avatar on the site is drawn in: one choice per site, made on
  Settings → Users → Avatars (setting `avatar_shape`, default `"circle"`).

  `PhoenixKitWeb.Components.Core.UserInfo.user_avatar/1` draws its frame in the
  site's shape, and the crop editor (`PhoenixKitWeb.Live.Components.AvatarEditor`)
  previews and limits the zoom with it, so a picture is framed in the shape it
  will be seen in.

  The shapes other than the plain ones are daisyUI's masks (`mask mask-squircle`
  and so on). The host's Tailwind build scans this file (`@source
  "../../deps/phoenix_kit"`), which is what generates their classes.

  ## Fit

  `fit/1` is the radius of the largest circle centred in the shape, as a
  fraction of half the frame: `1.0` for a circle, less for a shape that is
  narrower somewhere (a diamond, a star) or not centred (a pentagon, a heart).
  `PhoenixKit.Users.AvatarCrop.min_zoom/2` scales its floor by it, so a picture
  zoomed all the way out fits inside the shape whole. The values for the masks
  were measured by rendering daisyUI 5.7's SVGs at 400px, contain-fitted as
  `mask-size: contain` draws them, rounded down.
  """
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings

  @setting "avatar_shape"
  @default "circle"

  @doc "The setting key the site's shape is stored under."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting

  @doc "The shape a site has before anyone chooses: the circle."
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  Every shape, in the order the settings page shows them: `key`, translated
  `label`, the frame's `class` and its `fit`.
  """
  @spec all() :: [%{key: String.t(), label: String.t(), class: String.t(), fit: float()}]
  def all do
    Enum.map(definitions(), fn shape ->
      %{shape | label: Gettext.gettext(PhoenixKitWeb.Gettext, shape.label)}
    end)
  end

  defp definitions do
    [
      %{key: "circle", label: gettext_noop("Circle"), class: "rounded-full", fit: 1.0},
      %{key: "squircle", label: gettext_noop("Squircle"), class: "mask mask-squircle", fit: 1.0},
      %{key: "rounded", label: gettext_noop("Rounded square"), class: "rounded-[22%]", fit: 1.0},
      %{key: "square", label: gettext_noop("Square"), class: "rounded-none", fit: 1.0},
      %{key: "hexagon", label: gettext_noop("Hexagon"), class: "mask mask-hexagon", fit: 0.89},
      %{
        key: "hexagon_flat",
        label: gettext_noop("Flat hexagon"),
        class: "mask mask-hexagon-2",
        fit: 0.90
      },
      %{key: "decagon", label: gettext_noop("Decagon"), class: "mask mask-decagon", fit: 0.95},
      %{key: "pentagon", label: gettext_noop("Pentagon"), class: "mask mask-pentagon", fit: 0.76},
      %{key: "diamond", label: gettext_noop("Diamond"), class: "mask mask-diamond", fit: 0.70},
      %{key: "heart", label: gettext_noop("Heart"), class: "mask mask-heart", fit: 0.69},
      %{key: "star", label: gettext_noop("Star"), class: "mask mask-star-2", fit: 0.49}
    ]
  end

  @doc "Whether `key` names a shape."
  @spec known?(term()) :: boolean()
  def known?(key), do: Enum.any?(definitions(), &(&1.key == key))

  @doc """
  The site's shape. Unset, unknown, or unreadable (no database) is the circle,
  so a page never fails over how its avatars are drawn.
  """
  @spec current() :: String.t()
  def current do
    key = Settings.get_setting_cached(@setting, @default)
    if known?(key), do: key, else: @default
  rescue
    _ -> @default
  catch
    :exit, _ -> @default
  end

  @doc "Saves the site's shape. `opts` go to `Settings.update_setting/3` (`actor_uuid:`, `source:`)."
  @spec put(String.t(), keyword()) :: :ok | {:error, term()}
  def put(key, opts \\ []) do
    if known?(key) do
      case Settings.update_setting(@setting, key, opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unknown_shape}
    end
  end

  @doc "The frame's class for a shape (the circle's for an unknown key)."
  @spec class(String.t()) :: String.t()
  def class(key), do: find(key).class

  @doc "The shape's fit: the largest centred circle inside it, against half the frame."
  @spec fit(String.t()) :: float()
  def fit(key), do: find(key).fit

  @doc "The smallest fit of any shape: the lowest zoom a stored crop may have."
  @spec lowest_fit() :: float()
  def lowest_fit, do: definitions() |> Enum.map(& &1.fit) |> Enum.min()

  @doc """
  Whether the shape is drawn by a mask. A border or ring on a masked frame is
  masked away along the curves, so callers leave it off.
  """
  @spec masked?(String.t()) :: boolean()
  def masked?(key), do: String.starts_with?(class(key), "mask ")

  defp find(key), do: Enum.find(definitions(), &(&1.key == key)) || hd(definitions())
end
