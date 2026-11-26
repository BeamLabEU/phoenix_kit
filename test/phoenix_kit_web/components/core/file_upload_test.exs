defmodule PhoenixKitWeb.Components.Core.FileUploadTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.FileUpload

  defp render(template), do: rendered_to_string(template)

  defp entry(overrides \\ %{}) do
    Map.merge(
      %Phoenix.LiveView.UploadEntry{
        ref: "0",
        upload_ref: "phx-upload-1",
        client_name: "photo.jpg",
        client_size: 12_400_000,
        client_type: "image/jpeg",
        progress: 45
      },
      overrides
    )
  end

  # The UploadStats hook contract: the server renders the element with the
  # entry's size and patches only data-progress; everything else (speed, ETA,
  # the ticking "Processing on server…" phase) is computed in the browser.
  # These pins keep the markup the hook depends on from drifting.
  # The UploadGuard hook contract: the component root carries the hook and
  # a data-active flag the server patches — "true" while any entry is in
  # flight, so the browser's beforeunload dialog blocks an accidental
  # refresh/close that would kill the transfer.
  test "file_upload arms the UploadGuard while entries are in flight" do
    upload = %Phoenix.LiveView.UploadConfig{ref: "phx-upload-1", entries: [entry()]}
    assigns = %{upload: upload}

    html =
      render(~H"""
      <.file_upload upload={@upload} />
      """)

    assert html =~ ~s(phx-hook="UploadGuard")
    assert html =~ ~s(id="pk-upload-guard-phx-upload-1")
    assert html =~ ~s(data-active="true")
  end

  test "file_upload disarms the UploadGuard with no entries" do
    upload = %Phoenix.LiveView.UploadConfig{ref: "phx-upload-1", entries: []}
    assigns = %{upload: upload}

    html =
      render(~H"""
      <.file_upload upload={@upload} />
      """)

    assert html =~ ~s(data-active="false")
  end

  test "upload_entry_stats renders the UploadStats hook contract" do
    assigns = %{entry: entry()}

    html =
      render(~H"""
      <.upload_entry_stats entry={@entry} />
      """)

    assert html =~ ~s(phx-hook="UploadStats")
    assert html =~ ~s(id="pk-upload-stats-phx-upload-1-0")
    assert html =~ ~s(data-progress="45")
    assert html =~ ~s(data-size="12400000")
    assert html =~ ~s(data-label-processing=)
    assert html =~ ~s(data-label-left=)
    # Pre-mount fallback content: the file size (decimal units, like the
    # media listings).
    assert html =~ "12.4 MB"
  end

  test "upload_entry_stats ids stay unique across uploads and entries" do
    assigns = %{a: entry(), b: entry(%{ref: "1", upload_ref: "phx-upload-2"})}

    html =
      render(~H"""
      <.upload_entry_stats entry={@a} />
      <.upload_entry_stats entry={@b} />
      """)

    assert html =~ ~s(id="pk-upload-stats-phx-upload-1-0")
    assert html =~ ~s(id="pk-upload-stats-phx-upload-2-1")
  end

  test "both file_upload variants render stats for active entries" do
    upload = %Phoenix.LiveView.UploadConfig{
      ref: "phx-upload-1",
      name: :media_files,
      entries: [entry()],
      max_entries: 10
    }

    for variant <- ["full", "button"] do
      assigns = %{upload: upload, variant: variant}

      html =
        render(~H"""
        <.file_upload upload={@upload} variant={@variant} />
        """)

      assert html =~ ~s(phx-hook="UploadStats"), "variant #{variant} lost the stats hook"
      assert html =~ "12.4 MB"
    end
  end

  describe "edit_images" do
    test "off by default: no editor, no hook around the input" do
      upload = %Phoenix.LiveView.UploadConfig{ref: "phx-upload-1", name: :photos, entries: []}
      assigns = %{upload: upload}

      for variant <- ["full", "button"] do
        assigns = Map.put(assigns, :variant, variant)
        html = render(~H|<.file_upload upload={@upload} variant={@variant} />|)
        refute html =~ "PkUploadEdit"
        refute html =~ "data-pk-edit-dialog"
      end
    end

    test "wraps the drop zone and the input in the PkUploadEdit hook with its dialog" do
      upload = %Phoenix.LiveView.UploadConfig{ref: "phx-upload-1", name: :photos, entries: []}
      assigns = %{upload: upload}

      html = render(~H|<.file_upload upload={@upload} edit_images />|)

      assert html =~ ~s(id="pk-upload-edit-phx-upload-1")
      assert html =~ ~s(phx-hook="PkUploadEdit")
      assert html =~ ~s(data-upload-name="photos")
      assert html =~ ~s(<dialog id="pk-upload-edit-phx-upload-1-dialog")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ "Edit photo before upload"
      assert html =~ ~s(data-pk-edit-rotate="90")
      assert html =~ ~s(data-pk-edit-rotate="-90")
      assert html =~ ~s(data-pk-edit-flip)
      assert html =~ ~s(data-pk-edit-aspect="16/9")
      assert html =~ ~s(data-pk-edit-apply)
      assert html =~ ~s(data-pk-edit-original)
      assert html =~ ~s(data-pk-edit-skip)

      # The hook element holds both the drop target and the file input.
      [_, inside] = String.split(html, ~s(phx-hook="PkUploadEdit"), parts: 2)
      [before_dialog, _] = String.split(inside, "<dialog", parts: 2)
      assert before_dialog =~ ~s(phx-drop-target="phx-upload-1")
      assert before_dialog =~ ~s(type="file")

      # Buttons only inside the upload's form: a field would ride its phx-change.
      [_, dialog] = String.split(html, "<dialog", parts: 2)
      refute dialog =~ "<input"
      refute dialog =~ "<select"
    end

    test "the button variant wraps its input too" do
      upload = %Phoenix.LiveView.UploadConfig{ref: "phx-upload-1", name: :photos, entries: []}
      assigns = %{upload: upload}

      html = render(~H|<.file_upload upload={@upload} variant="button" edit_images />|)

      [_, inside] = String.split(html, ~s(phx-hook="PkUploadEdit"), parts: 2)
      assert inside =~ ~s(type="file")
    end
  end
end
