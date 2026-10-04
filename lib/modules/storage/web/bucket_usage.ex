defmodule PhoenixKitWeb.Live.Modules.Storage.BucketUsage do
  @moduledoc """
  How the Storage settings show which storage profiles use a bucket
  (`PhoenixKit.Modules.Storage.Profiles.bucket_usage/1`): the "Used by" cell
  of the Buckets list, the panel on the bucket's edit page, and the wording of
  the refusal when a bucket that is in use is deleted or disabled.

  A user's own storage profile and their libraries are private to them: they
  are counted here, never named.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc """
  What the admin is told when `action` (`:delete` or `:disable`) on `bucket`
  is refused because the profiles in `usage` list it.
  """
  @spec refusal_message(:delete | :disable, struct(), [map()]) :: String.t()
  def refusal_message(action, bucket, usage) do
    used_by = used_by_text(usage)

    case action do
      :delete ->
        gettext(
          "\"%{bucket}\" cannot be deleted: it is used by %{used_by}. Take it out of those storage profiles first (Storage profiles tab), then delete it.",
          bucket: bucket.name,
          used_by: used_by
        )

      :disable ->
        gettext(
          "\"%{bucket}\" cannot be disabled: it is used by %{used_by}. A disabled bucket is neither written nor read, so the libraries on those profiles would lose it. Take it out of those storage profiles first (Storage profiles tab).",
          bucket: bucket.name,
          used_by: used_by
        )
    end
  end

  @doc """
  The profiles in `usage` in words: the site's by name and how the bucket is
  used there, then a count of personal ones, then how many libraries that
  reaches.
  """
  @spec used_by_text([map()]) :: String.t()
  def used_by_text(usage) do
    {personal, site} = Enum.split_with(usage, &is_binary(&1.owner_uuid))

    parts =
      Enum.map(site, fn row ->
        gettext("the \"%{profile}\" profile (%{use})",
          profile: row.name,
          use: use_text(row)
        )
      end) ++
        if personal == [],
          do: [],
          else: [
            ngettext(
              "%{count} personal storage profile",
              "%{count} personal storage profiles",
              length(personal)
            )
          ]

    libraries = usage |> Enum.map(& &1.libraries) |> Enum.sum()

    base = Enum.join(parts, ", ")

    if libraries > 0,
      do:
        base <>
          " " <>
          ngettext(
            "(%{count} library in all)",
            "(%{count} libraries in all)",
            libraries
          ),
      else: base
  end

  # "primary", or "backup, draining" when it is not active.
  defp use_text(%{role: role, status: "active"}), do: role_label(role)

  defp use_text(%{role: role, status: status}),
    do: role_label(role) <> ", " <> status_label(status)

  defp role_label("primary"), do: gettext("primary")
  defp role_label("replica"), do: gettext("replica")
  defp role_label("backup"), do: gettext("backup")
  defp role_label(other), do: to_string(other)

  defp status_label("read_only"), do: gettext("read only")
  defp status_label("draining"), do: gettext("draining")
  defp status_label(other), do: to_string(other)

  attr :usage, :list, required: true, doc: "the bucket's entry of `Profiles.bucket_usage/1`"

  @doc "The Buckets list's \"Used by\" cell: a chip per site profile, one for personal ones."
  def usage_cell(assigns) do
    {personal, site} = Enum.split_with(assigns.usage, &is_binary(&1.owner_uuid))

    assigns =
      assigns
      |> assign(:site, site)
      |> assign(:personal, length(personal))

    ~H"""
    <%= if @usage == [] do %>
      <span class="text-xs text-base-content/50">{gettext("Not used")}</span>
    <% else %>
      <div class="flex flex-wrap gap-1">
        <span
          :for={row <- @site}
          class="badge badge-outline badge-sm h-auto gap-1"
          title={
            ngettext("%{count} library", "%{count} libraries", row.libraries) <>
              " · " <> use_text(row)
          }
        >
          {row.name}
          <span class="text-base-content/60">{use_text(row)}</span>
        </span>
        <span :if={@personal > 0} class="badge badge-ghost badge-sm h-auto">
          {ngettext("%{count} personal profile", "%{count} personal profiles", @personal)}
        </span>
      </div>
    <% end %>
    """
  end
end
