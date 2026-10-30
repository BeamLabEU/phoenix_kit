defmodule PhoenixKitWeb.Components.MediaBrowser.RemovalModal do
  @moduledoc false
  # The media browser's removal dialog (see `PhoenixKit.Modules.Storage.RemovalGuard`):
  # the confirmation of a removal, or the list of places that keep files from
  # being removed. A server dialog — the browser holds the pending action in
  # its assigns — drawn in the top layer (`popover`) so that it sits above an
  # open viewer, and closed by Escape (the `RemovalModal` hook) without
  # closing what is under it.
  use PhoenixKitWeb, :html

  attr :id, :string, required: true
  attr :myself, :any, required: true
  attr :pending, :map, default: nil

  def removal_modal(%{pending: nil} = assigns), do: ~H""

  def removal_modal(assigns) do
    assigns =
      assigns
      |> assign(:state, state(assigns.pending))
      |> assign(:free_count, length(assigns.pending.free))
      |> assign(:blocked_count, blocked_count(assigns.pending))

    ~H"""
    <div
      id={"#{@id}-removal-modal"}
      class="modal modal-open"
      popover="manual"
      role="alertdialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-removal-title"}
      phx-hook="RemovalModal"
      phx-target={@myself}
      data-removal-state={@state}
      data-token={@pending.token}
    >
      <div class="modal-box max-w-lg">
        <h3 id={"#{@id}-removal-title"} class="font-bold text-lg">
          {title(@state, @pending, @free_count, @blocked_count)}
        </h3>

        <p :if={@state == :failed} class="py-3 text-sm">
          {gettext("The files could not be checked, so nothing was removed. Try again later.")}
        </p>

        <p
          :if={@state != :failed and @pending.error != nil}
          id={"#{@id}-removal-error"}
          role="alert"
          class="alert alert-error text-sm mt-3"
        >
          {error_text(@pending.error)}
        </p>

        <p :if={@state == :confirm and @pending.kind == :delete} class="py-3 text-sm">
          {gettext("This cannot be undone.")}
        </p>

        <ul
          :if={@state == :confirm and @pending.free_names != []}
          id={"#{@id}-removal-files"}
          class="my-3 max-h-40 overflow-y-auto text-sm list-disc pl-5"
        >
          <li :for={name <- @pending.free_names} class="truncate">{name}</li>
          <li :if={@pending.free_hidden > 0} class="list-none -ml-5 text-base-content/60">
            {ngettext("and %{count} more file", "and %{count} more files", @pending.free_hidden)}
          </li>
        </ul>

        <div :if={@pending.places != []} class="mt-3">
          <p :if={@state == :confirm} class="text-sm font-medium">
            {ngettext(
              "%{count} file is in use and stays in the trash:",
              "%{count} files are in use and stay in the trash:",
              @blocked_count
            )}
          </p>
          <ul id={"#{@id}-removal-places"} class="my-2 max-h-60 overflow-y-auto text-sm space-y-1">
            <li :for={place <- @pending.places} class="rounded bg-base-200 px-2 py-1">
              <span class="font-medium">{Map.get(@pending.names, place.file_uuid)}</span>
              <%= if place.label do %>
                <span class="text-base-content/60"> — </span>
                <a
                  :if={place.href}
                  href={place.href}
                  target="_blank"
                  rel="noopener"
                  class="link link-primary"
                >
                  {place.label}
                </a>
                <span :if={!place.href}>{place.label}</span>
                <span :if={place.detail} class="block text-xs text-base-content/60">
                  {place.detail}
                </span>
              <% else %>
                <span class="text-base-content/60"> — {gettext("Not available to you")}</span>
              <% end %>
            </li>
          </ul>
        </div>

        <div class="modal-action">
          <button
            type="button"
            id={"#{@id}-removal-cancel"}
            phx-click="removal_cancel"
            phx-target={@myself}
            phx-value-token={@pending.token}
            class="btn btn-ghost"
          >
            {if @state == :confirm, do: gettext("Cancel"), else: gettext("Close")}
          </button>
          <button
            :if={@pending.release_label}
            type="button"
            id={"#{@id}-removal-release"}
            phx-click="removal_release"
            phx-target={@myself}
            phx-value-token={@pending.token}
            phx-disable-with={@pending.release_label}
            class="btn btn-warning"
          >
            {@pending.release_label}
          </button>
          <button
            :if={@state == :confirm}
            type="button"
            id={"#{@id}-removal-confirm"}
            phx-click="removal_confirm"
            phx-target={@myself}
            phx-value-token={@pending.token}
            phx-disable-with={gettext("Please wait…")}
            class="btn btn-error"
          >
            {if @pending.kind == :delete,
              do: gettext("Delete forever"),
              else: gettext("Move to trash")}
          </button>
        </div>
      </div>
      <div
        class="modal-backdrop"
        phx-click="removal_cancel"
        phx-target={@myself}
        phx-value-token={@pending.token}
      >
      </div>
    </div>
    """
  end

  # :failed (the guard could not be asked), :blocked (nothing can go),
  # :confirm (something can: all of it, or what is free of use).
  defp state(%{failed?: true}), do: :failed
  defp state(%{free: [], places: [_ | _]}), do: :blocked
  defp state(%{places: [_ | _], skip?: false}), do: :blocked
  defp state(_pending), do: :confirm

  defp blocked_count(%{places: places}),
    do: places |> Enum.map(& &1.file_uuid) |> Enum.uniq() |> length()

  defp title(:failed, _pending, _free, _blocked), do: gettext("Could not check the files")

  defp title(:blocked, _pending, _free, blocked) do
    ngettext(
      "Cannot delete: the file is in use",
      "Cannot delete: %{count} files are in use",
      blocked
    )
  end

  defp title(:confirm, %{kind: :trash, folders: folders}, _free, _blocked) when folders > 0 do
    ngettext(
      "Move %{count} folder and its contents to trash?",
      "Move %{count} folders and their contents to trash?",
      folders
    )
  end

  defp title(:confirm, %{kind: :delete, folders: folders}, _free, _blocked) when folders > 0 do
    ngettext(
      "Delete %{count} folder and its contents for good?",
      "Delete %{count} folders and their contents for good?",
      folders
    )
  end

  defp title(:confirm, %{kind: :trash}, free, _blocked) do
    ngettext("Move %{count} file to trash?", "Move %{count} files to trash?", free)
  end

  defp title(:confirm, %{kind: :delete}, free, _blocked) do
    ngettext("Delete %{count} file for good?", "Delete %{count} files for good?", free)
  end

  defp error_text(message) when is_binary(message), do: message
  defp error_text(_), do: gettext("The files could not be freed. Nothing was removed.")
end
