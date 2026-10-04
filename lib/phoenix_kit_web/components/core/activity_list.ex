defmodule PhoenixKitWeb.Components.Core.ActivityList do
  @moduledoc """
  A list of activity entries — when, who, what, and what moved — for any screen
  that shows a slice of the Activity log (Settings → Media → History is the first;
  the full feed at `/admin/activity` keeps its own richer table and shares this
  module's `summarize_details/1`).

      <.activity_list entries={@entries} empty={gettext("Nothing yet.")} />

  Entries need their `:actor` preloaded (`Activity.list/1` does by default). Each row
  links to the entry's page (`/admin/activity/:uuid`), which shows it in full.
  Pass `detail_links: false` when the viewer cannot access the Activity page.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Activity
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  attr :entries, :list, required: true
  attr :empty, :string, default: nil
  attr :id, :string, default: nil
  attr :detail_links, :boolean, default: true

  def activity_list(assigns) do
    ~H"""
    <div class="overflow-x-auto" id={@id}>
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{gettext("When")}</th>
            <th>{gettext("Who")}</th>
            <th>{gettext("What")}</th>
            <th>{gettext("Subject")}</th>
            <th>{gettext("Details")}</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@entries == []}>
            <td colspan="6" class="text-center text-base-content/50 py-8">
              {@empty || gettext("Nothing recorded yet.")}
            </td>
          </tr>
          <tr :for={entry <- @entries} id={@id && "#{@id}-#{entry.uuid}"} class="hover">
            <td class="whitespace-nowrap text-xs">
              <div>{UtilsDate.format_date_with_user_format(entry.inserted_at)}</div>
              <div class="text-base-content/50">
                {UtilsDate.format_time_with_user_format(entry.inserted_at)}
              </div>
            </td>
            <td class="text-sm">
              <%= if entry.actor do %>
                <span class="font-medium">{entry.actor.email}</span>
              <% else %>
                <span class="text-base-content/50">
                  <%= if entry.actor_uuid do %>
                    {gettext("User")} {String.slice(entry.actor_uuid, 0, 8)}
                  <% else %>
                    {gettext("System")}
                  <% end %>
                </span>
              <% end %>
              <span
                :if={entry.mode in ~w(auto cron script)}
                class={"badge badge-xs ml-1 #{Activity.mode_badge_color(entry.mode)}"}
              >
                {entry.mode}
              </span>
            </td>
            <td>
              <span class={"badge badge-sm #{Activity.action_badge_color(entry.action)}"}>
                {entry.action}
              </span>
            </td>
            <td class="text-sm">{subject(entry)}</td>
            <td class="text-xs text-base-content/70">
              {summarize_details(entry.metadata) || "—"}
              <details :if={fields(entry.metadata) != []} id={@id && "#{@id}-#{entry.uuid}-fields"}>
                <summary class="cursor-pointer text-primary">{gettext("Show every field")}</summary>
                <dl class="mt-1 space-y-0.5">
                  <div :for={{label, value} <- fields(entry.metadata)} class="flex gap-2">
                    <dt class="font-medium shrink-0">{label}</dt>
                    <dd class="break-all">{value}</dd>
                  </div>
                </dl>
              </details>
            </td>
            <td>
              <.link
                :if={@detail_links}
                navigate={Routes.path("/admin/activity/#{entry.uuid}")}
                class="btn btn-ghost btn-xs btn-square"
                title={gettext("View details")}
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
              </.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # Every field an entry recorded, one line each: what changed (from → to) first, then
  # the rest of what it names. It is the whole entry, so a viewer who cannot open the
  # Activity page (which `media.manage` does not imply) loses nothing to the one-line
  # summary's cut-off.
  @hidden_keys ~w(method actor_role)

  defp fields(metadata) do
    {changes, rest} = Activity.split_changes(metadata || %{})

    changed =
      changes
      |> Enum.sort()
      |> Enum.map(fn {field, change} ->
        {Activity.humanize_metadata_key(field), Activity.humanize_metadata_value(change)}
      end)

    named =
      rest
      |> Map.drop(@hidden_keys)
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.sort()
      |> Enum.map(fn {key, value} ->
        {Activity.humanize_metadata_key(key), Activity.humanize_metadata_value(value)}
      end)

    changed ++ named
  end

  defp subject(entry) do
    metadata = entry.metadata || %{}

    case metadata do
      %{"profile" => profile, "bucket" => bucket} ->
        Enum.map_join([profile, bucket], " / ", &Activity.humanize_metadata_value/1)

      %{"variant_set" => set, "size" => size} ->
        Enum.map_join([set, size], " / ", &Activity.humanize_metadata_value/1)

      _ ->
        (metadata["name"] || metadata["library"] || metadata["profile"] ||
           metadata["variant_set"] || metadata["title"] || metadata["key"] ||
           entry.resource_uuid || "—")
        |> Activity.humanize_metadata_value()
    end
  end

  # The Details column is where a reader first meets the event, and it should
  # say what MOVED — the owner started on this list, saw only the row's name,
  # clicked through, and found no answer (boss via Max, 2026-09-20). A change
  # therefore leads; identity and operational keys are the fallback for rows
  # that record none.
  @summary_change_limit 3

  @doc """
  The one-line summary of what an entry moved: its changes first ("Name Old → New · +2"),
  else its identity and operational keys. `nil` when there is nothing to say.
  """
  @spec summarize_details(map() | nil) :: String.t() | nil
  def summarize_details(metadata) do
    case Activity.split_changes(metadata || %{}) do
      {changes, rest} when map_size(changes) > 0 -> summarize_changes(changes, rest)
      {_none, rest} -> summarize_plain(rest)
    end
  end

  defp summarize_changes(changes, rest) do
    shown = changes |> Enum.sort() |> Enum.take(@summary_change_limit)
    hidden = map_size(changes) - length(shown)

    summary =
      Enum.map_join(shown, ", ", fn {field, change} ->
        "#{Activity.humanize_metadata_key(field)} #{summarize_change(change)}"
      end)

    # Only the change. The row's identity is already the Subject column —
    # a titled deep link since the resource templates landed — so repeating
    # it here just pushes the answer off the end of the line.
    _ = rest

    [summary, more_label(hidden)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # The flag shape carries no value, only the word — translated here for the
  # same reason the detail page does it: `Activity` has no Gettext backend,
  # and its own "changed" would reach every locale in English.
  defp summarize_change(%{"changed" => true}), do: gettext("changed")
  defp summarize_change(change), do: Activity.humanize_metadata_value(change)

  defp more_label(count) when count > 0, do: "+#{count}"
  defp more_label(_count), do: nil

  defp summarize_plain(meta) do
    if meta["added"] || meta["removed"] do
      # For role updates, show added/removed summary
      parts = []

      parts =
        if meta["added"],
          do: parts ++ ["added: #{Activity.humanize_metadata_value(meta["added"])}"],
          else: parts

      parts =
        if meta["removed"],
          do: parts ++ ["removed: #{Activity.humanize_metadata_value(meta["removed"])}"],
          else: parts

      Enum.join(parts, ", ")
    else
      # For profile updates, extract field names from _from/_to pairs
      changed_fields =
        meta
        |> Map.keys()
        |> Enum.filter(&String.ends_with?(&1, "_to"))
        |> Enum.map(&String.trim_trailing(&1, "_to"))
        |> Enum.reject(&(&1 == ""))

      if changed_fields != [] do
        fields = Enum.map_join(changed_fields, ", ", &String.replace(&1, "_", " "))
        "#{fields} updated"
      else
        summarize_remaining_meta(meta)
      end
    end
  end

  defp summarize_remaining_meta(meta) do
    meta
    |> Map.drop(["method", "actor_role"])
    |> Enum.reject(fn {_k, v} -> v == nil or v == "" end)
    |> case do
      [] ->
        nil

      entries ->
        # Values may be nested maps (e.g. a `%{"from" => _, "to" => _}` field
        # diff) — Activity.humanize_metadata_value/1 renders those as "1 → 2"
        # rather than raising String.Chars on a Map (the crash this fixes).
        Enum.map_join(entries, ", ", fn {k, v} ->
          "#{k}: #{Activity.humanize_metadata_value(v)}"
        end)
    end
  end
end
