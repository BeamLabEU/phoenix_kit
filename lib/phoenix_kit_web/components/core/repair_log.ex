defmodule PhoenixKitWeb.Components.Core.RepairLog do
  @moduledoc """
  The rows of `PhoenixKit.Modules.Storage.RepairLog` as a table in which every
  file, library and bucket is a link: the one view of "what went wrong with the
  storage and what was done about it", on the History tab, on a file's storage page
  and on a bucket's page.

  `hide` drops the columns the page already says (`:file` on a file's page,
  `:bucket` on a bucket's page, `:library` on either).
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :hide, :list, default: []
  attr :empty, :string, default: nil

  def repair_log(assigns) do
    ~H"""
    <div id={@id} class="overflow-x-auto">
      <p :if={@rows == []} class="text-sm text-base-content/60">
        {@empty || gettext("Nothing has gone wrong, and nothing has been repaired.")}
      </p>

      <table :if={@rows != []} class="table table-sm">
        <thead>
          <tr>
            <th>{gettext("When")}</th>
            <th>{gettext("What")}</th>
            <th :if={:file not in @hide}>{gettext("File")}</th>
            <th :if={:library not in @hide}>{gettext("Library")}</th>
            <th :if={:bucket not in @hide}>{gettext("Bucket")}</th>
            <th>{gettext("Details")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} id={"#{@id}-#{row.uuid}"}>
            <td class="text-xs whitespace-nowrap">
              {UtilsDate.format_datetime_with_user_format(row.at)}
            </td>
            <td>
              <span class={["badge badge-sm whitespace-nowrap", badge(row)]}>{label(row)}</span>
            </td>
            <td :if={:file not in @hide} class="text-sm">
              <.file_link file={row.file} />
            </td>
            <td :if={:library not in @hide} class="text-sm">
              <.library_link library={row.library} />
            </td>
            <td :if={:bucket not in @hide} class="text-sm">
              <.bucket_links row={row} />
            </td>
            <td class="text-xs">
              <.details row={row} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :file, :map, required: true

  defp file_link(%{file: %{uuid: nil}} = assigns), do: ~H"–"

  defp file_link(%{file: %{exists?: false}} = assigns) do
    ~H"""
    <span class="text-base-content/60" title={gettext("This file no longer exists.")}>
      {@file.name || @file.uuid}
    </span>
    """
  end

  defp file_link(assigns) do
    ~H"""
    <.link
      navigate={Routes.path("/admin/media/#{@file.uuid}/storage")}
      class="link link-hover break-all"
    >
      {@file.name || @file.uuid}
    </.link>
    """
  end

  attr :library, :any, required: true

  defp library_link(%{library: nil} = assigns), do: ~H"–"

  defp library_link(%{library: %{site?: true}} = assigns) do
    ~H"""
    <.link
      navigate={Routes.path("/admin/settings/media/libraries/#{@library.uuid}")}
      class="link link-hover"
    >
      {@library.name}
    </.link>
    """
  end

  defp library_link(assigns) do
    ~H"""
    {@library.name || gettext("A user library")}
    """
  end

  attr :row, :map, required: true

  # A damaged copy is in one bucket; a repair touched the buckets its actions name.
  defp bucket_links(assigns) do
    assigns = assign(assigns, :buckets, buckets(assigns.row))

    ~H"""
    <div class="flex flex-col gap-0.5">
      <span :for={bucket <- @buckets}>
        <.link
          :if={bucket.exists?}
          navigate={Routes.path("/admin/settings/media/buckets/#{bucket.uuid}")}
          class="link link-hover"
        >
          {bucket.name}
        </.link>
        <span :if={!bucket.exists?} class="text-base-content/60">{bucket.name}</span>
      </span>
      <span :if={@buckets == []}>–</span>
    </div>
    """
  end

  defp buckets(%{kind: :damaged, bucket: nil}), do: []
  defp buckets(%{kind: :damaged, bucket: bucket}), do: [bucket]

  defp buckets(%{kind: :repaired, actions: actions}) do
    actions
    |> Enum.filter(& &1.bucket_uuid)
    |> Enum.uniq_by(& &1.bucket_uuid)
    |> Enum.map(&%{uuid: &1.bucket_uuid, name: &1.bucket, exists?: &1.bucket_exists?})
  end

  attr :row, :map, required: true

  defp details(%{row: %{kind: :damaged}} = assigns) do
    ~H"""
    <div>
      <span class="font-medium">{@row.rendition}</span> · {problem_text(@row.problem)}
    </div>
    <div class="text-base-content/60">
      {found_by_text(@row.found_by)}<span :if={@row.actor}> · {@row.actor.email}</span>
    </div>
    """
  end

  defp details(%{row: %{kind: :repaired}} = assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={action <- @row.actions}>
        <span class="font-medium">{action.rendition}</span> · {action_text(action)}
      </li>
    </ul>
    <div :if={@row.actor} class="text-base-content/60">{@row.actor.email}</div>
    <div :if={@row.problems_left && @row.problems_left > 0} class="text-warning">
      {ngettext(
        "%{count} problem was left.",
        "%{count} problems were left.",
        @row.problems_left
      )}
    </div>
    """
  end

  defp label(%{kind: :damaged}), do: gettext("Damaged copy")
  defp label(%{kind: :repaired}), do: gettext("Repaired")

  defp badge(%{kind: :damaged}), do: "badge-error"

  defp badge(%{kind: :repaired, problems_left: left}) when is_integer(left) and left > 0,
    do: "badge-warning"

  defp badge(%{kind: :repaired}), do: "badge-success"

  defp problem_text("missing"), do: gettext("Missing from the bucket")
  defp problem_text("checksum_mismatch"), do: gettext("Bytes differ from the checksum")
  defp problem_text(other), do: other

  defp found_by_text("repair"), do: gettext("Found while fixing")
  defp found_by_text("verify"), do: gettext("Found by verification")
  defp found_by_text(_), do: nil

  defp action_text(%{kind: "restored", bucket: bucket, from: from}),
    do: gettext("Copied back into %{bucket} from %{from}.", bucket: bucket, from: from)

  defp action_text(%{kind: "regenerated"}), do: gettext("Made again from the original.")
  defp action_text(%{kind: "made"}), do: gettext("Made from the original.")

  defp action_text(%{kind: "copied", bucket: bucket}),
    do: gettext("Copied into %{bucket}.", bucket: bucket)

  defp action_text(%{kind: "removed", bucket: bucket}),
    do: gettext("Removed from %{bucket}, which the profile no longer uses.", bucket: bucket)

  defp action_text(%{kind: "recorded", bucket: bucket}),
    do: gettext("Found in %{bucket} and recorded.", bucket: bucket)

  defp action_text(%{kind: "unrecoverable"}),
    do: gettext("No good copy exists anywhere, and it cannot be made again.")

  defp action_text(%{kind: "unreadable", bucket: bucket}),
    do: gettext("Could not be read from %{bucket}; left as it is.", bucket: bucket)

  defp action_text(%{kind: "skipped"}), do: gettext("Not made again: the original is damaged.")

  defp action_text(%{kind: "failed", bucket: bucket}) when is_binary(bucket),
    do: gettext("Could not be fixed in %{bucket}.", bucket: bucket)

  defp action_text(%{kind: "failed"}), do: gettext("Could not be made again.")
  defp action_text(%{kind: kind}), do: kind
end
