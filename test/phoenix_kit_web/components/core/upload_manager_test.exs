defmodule PhoenixKitWeb.Components.Core.UploadManagerTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.{Socket, UploadConfig, UploadEntry}
  alias PhoenixKitWeb.Components.Core.UploadManager

  defp config(entries \\ []) do
    %UploadConfig{
      name: :photos,
      ref: "phx-F123-ref",
      max_entries: 100,
      entries: entries,
      accept: :any,
      errors: []
    }
  end

  defp entry(attrs) do
    struct!(
      UploadEntry,
      Map.merge(
        %{
          ref: "0",
          upload_ref: "phx-F123-ref",
          client_name: "cat.png",
          client_size: 1234,
          client_last_modified: 99,
          progress: 40,
          done?: false,
          valid?: true
        },
        attrs
      )
    )
  end

  defp html(assigns) do
    assigns = Map.merge(%{id: "um", upload: config()}, assigns)
    rendered_to_string(~H"<UploadManager.upload_manager {assigns} />")
  end

  describe "markup" do
    test "a hook element the script can find everything on" do
      html = html(%{max_concurrent: 7})

      assert html =~ ~s(phx-hook="UploadManager")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ ~s(data-upload-ref="phx-F123-ref")
      assert html =~ ~s(data-upload-name="photos")
      assert html =~ ~s(data-max="7")
      assert html =~ ~s(data-entries="um-entries")
      assert html =~ ~s(data-cancel-event="pk_upload_cancel")
    end

    test "the cap is held between 1 and 20" do
      assert html(%{max_concurrent: 0}) =~ ~s(data-max="1")
      assert html(%{max_concurrent: 500}) =~ ~s(data-max="20")
      assert html(%{max_concurrent: nil}) =~ ~s(data-max="5")
    end

    test "each upload entry is a row with what the script reads" do
      e = entry(%{ref: "3", progress: 55, client_name: "a|b.png"})
      html = html(%{upload: config([e])})

      assert html =~ "data-pk-upload-entry"
      assert html =~ ~s(data-ref="3")
      assert html =~ ~s(data-key="a|b.png|1234|99")
      assert html =~ ~s(data-size="1234")
      assert html =~ ~s(data-progress="55")
      assert html =~ ~s(data-done="false")
    end

    test "a refused entry carries why" do
      e = entry(%{ref: "4", valid?: false})
      upload = %{config([e]) | errors: [{"4", :too_large}]}

      assert html(%{upload: upload}) =~ ~s(data-error="too_large")
    end

    test "a drop zone and the file input are there by default, and scope is its own" do
      html = html(%{})
      assert html =~ ~s(phx-drop-target="phx-F123-ref")
      assert html =~ ~s(data-scope="self")
    end

    test "dropzone={false} leaves the input to the page and listens on the parent" do
      html = html(%{dropzone: false})
      refute html =~ "phx-drop-target"
      assert html =~ ~s(data-scope="parent")
    end

    test "a component target is passed to the script" do
      html =
        html(%{cancel_event: "cancel_upload", cancel_target: %Phoenix.LiveComponent.CID{cid: 7}})

      assert html =~ ~s(data-cancel-event="cancel_upload")
      assert html =~ ~s(data-cancel-target="7")
    end

    test "layout" do
      assert html(%{}) =~ "fixed bottom-4 right-4"
      refute html(%{layout: :inline}) =~ "fixed bottom-4"
    end

    test "the labels the script shows are handed over, with their placeholders intact" do
      [labels] = Regex.run(~r/data-labels="([^"]*)"/, html(%{}), capture: :all_but_first)
      decoded = labels |> Phoenix.HTML.html_escape() |> then(fn _ -> labels end)
      assert decoded =~ "%{done}"
      assert decoded =~ "%{total}"
      assert decoded =~ "%{count}"
    end

    test "every control the script toggles is in the row template" do
      html = html(%{})

      for act <- ~w(prioritize pause resume skip restore retry cancel) do
        assert html =~ ~s(data-act="#{act}"), "no #{act} button"
      end

      for act <- ~w(pause-all resume-all cancel-all retry-failed clear collapse) do
        assert html =~ ~s(data-act="#{act}"), "no #{act} control"
      end
    end
  end

  describe "attach/1" do
    defp socket_with(uploads) do
      %Socket{assigns: %{__changed__: %{}, uploads: uploads}}
    end

    test "installs a hook for the cancel event" do
      socket =
        UploadManager.attach(%Socket{
          assigns: %{__changed__: %{}},
          private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
        })

      assert [%{id: :pk_upload_manager, stage: :handle_event}] =
               socket.private.lifecycle.handle_event
    end

    test "other events pass through" do
      socket = socket_with(%{})
      assert {:cont, ^socket} = UploadManager.__handle_cancel__("something_else", %{}, socket)
    end

    test "an upload name that is not configured is ignored, and no atom is made from it" do
      socket = socket_with(%{photos: config()})
      name = "no_such_upload_#{System.unique_integer([:positive])}"

      assert {:halt, ^socket} =
               UploadManager.__handle_cancel__(
                 "pk_upload_cancel",
                 %{"ref" => "1", "name" => name},
                 socket
               )

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "a cancel for an entry that is already gone does not crash the LiveView" do
      socket = socket_with(%{photos: config()})

      assert {:halt, ^socket} =
               UploadManager.__handle_cancel__(
                 "pk_upload_cancel",
                 %{"ref" => "99", "name" => "photos"},
                 socket
               )
    end

    test "a cancel for an entry whose upload channel just ended does not crash it either" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      e = entry(%{ref: "7"})
      conf = %{config([e]) | entry_refs_to_pids: %{"7" => dead}}
      socket = socket_with(%{photos: conf})

      assert {:halt, ^socket} =
               UploadManager.__handle_cancel__(
                 "pk_upload_cancel",
                 %{"ref" => "7", "name" => "photos"},
                 socket
               )
    end

    test "a malformed cancel is ignored" do
      socket = socket_with(%{photos: config()})

      assert {:cont, ^socket} =
               UploadManager.__handle_cancel__("pk_upload_cancel", %{"ref" => 1}, socket)
    end
  end
end
