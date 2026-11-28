defmodule PhoenixKit.Activity.ChangesTest do
  @moduledoc """
  The "What changed" contract the Activity detail page reads.

  The owner opened an event and could not tell what had changed: the metadata
  named the row rather than the change (boss via Max, 2026-09-20). These pin
  the split, the legacy folding that makes it work on rows already in the
  table, and the value shapes a module may record.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Activity

  describe "split_changes/1" do
    test "lifts the reserved key out of the metadata" do
      metadata = %{
        "name" => "T-Joint 22mm",
        "changes" => %{"sku" => %{"from" => "T-21", "to" => "T-22"}}
      }

      assert {changes, rest} = Activity.split_changes(metadata)
      assert changes == %{"sku" => %{"from" => "T-21", "to" => "T-22"}}
      assert rest == %{"name" => "T-Joint 22mm"}
    end

    test "identity survives a change to the same field name" do
      # The collision that started this: a rename must not turn the entry's
      # own `name` into a map, because the deep-link title calls to_string/1.
      metadata = %{
        "name" => "T-Joint 25mm",
        "changes" => %{"name" => %{"from" => "T-Joint 22mm", "to" => "T-Joint 25mm"}}
      }

      assert {changes, rest} = Activity.split_changes(metadata)
      assert rest["name"] == "T-Joint 25mm"
      assert to_string(rest["name"]) == "T-Joint 25mm"
      assert changes["name"]["from"] == "T-Joint 22mm"
    end

    # A row whose "changes" is not a diff keeps it as ordinary metadata
    # instead of having it deleted on the way past (codex + zai, 2026-09-20).
    test "a non-map changes value stays in the metadata" do
      metadata = %{"changes" => "manual note", "name" => "x"}

      assert Activity.split_changes(metadata) == {%{}, metadata}
    end

    test "a struct is not mistaken for metadata" do
      assert Activity.split_changes(~D[2026-09-20]) == {%{}, %{}}
    end

    test "no diff means no changes section" do
      assert Activity.split_changes(%{"name" => "x"}) == {%{}, %{"name" => "x"}}
      assert Activity.split_changes(%{"changes" => %{}}) == {%{}, %{}}
      assert Activity.split_changes(nil) == {%{}, %{}}
    end

    # Most of the 34k rows already in the table were written this way, as is
    # everything `log_user_change/4` still writes.
    test "folds legacy flat field_from / field_to pairs into the same shape" do
      metadata = %{"email_from" => "a@x.ee", "email_to" => "b@x.ee", "actor_role" => "admin"}

      assert {changes, rest} = Activity.split_changes(metadata)
      assert changes == %{"email" => %{"from" => "a@x.ee", "to" => "b@x.ee"}}
      assert rest == %{"actor_role" => "admin"}, "the pair is consumed, the context stays"
    end

    # The old `log_user_change/4` wrote every changed field as a flat pair,
    # bcrypt hashes included; the "What changed" table showed them.
    test "a secret-looking field is shown as changed, never with its values" do
      metadata = %{
        "hashed_password_from" => "$2b$12$old",
        "hashed_password_to" => "$2b$12$new",
        "changes" => %{"api_key" => %{"from" => "pk_1", "to" => "pk_2"}}
      }

      assert {changes, rest} = Activity.split_changes(metadata)

      assert changes == %{
               "hashed_password" => %{"changed" => true},
               "api_key" => %{"changed" => true}
             }

      assert rest == %{}
    end

    test "a boolean change under a secret-looking name is shown with its values" do
      metadata = %{"changes" => %{"encryption_enabled" => %{"from" => false, "to" => true}}}

      assert {%{"encryption_enabled" => %{"from" => false, "to" => true}}, %{}} =
               Activity.split_changes(metadata)
    end

    test "a half pair is left alone rather than guessed at" do
      metadata = %{"email_from" => "a@x.ee", "note" => "n"}

      assert {changes, rest} = Activity.split_changes(metadata)
      assert changes == %{}
      assert rest == metadata
    end

    test "reserved and legacy can coexist" do
      metadata = %{
        "email_from" => "a@x.ee",
        "email_to" => "b@x.ee",
        "changes" => %{"sku" => %{"from" => "T-21", "to" => "T-22"}}
      }

      assert {changes, _rest} = Activity.split_changes(metadata)
      assert Map.keys(changes) |> Enum.sort() == ["email", "sku"]
    end
  end

  describe "change_side/2" do
    test "reads both ends of a scalar change" do
      change = %{"from" => "T-21", "to" => "T-22"}
      assert Activity.change_side(change, :from) == "T-21"
      assert Activity.change_side(change, :to) == "T-22"
    end

    test "a reference shows the label it was snapshotted with, never the uuid" do
      change = %{
        "from" => %{"uuid" => "019da71b-c29c", "label" => "Hardware"},
        "to" => %{"uuid" => "019da71b-c274", "label" => "Frames"}
      }

      assert Activity.change_side(change, :from) == "Hardware"
      assert Activity.change_side(change, :to) == "Frames"
    end

    # The atom, not a word: this module has no Gettext backend, and a bare
    # English "changed" rendered untranslated on every locale (zai). The
    # template turns it into a translated word.
    test "a long value answers with the atom the template translates" do
      assert Activity.change_side(%{"changed" => true}, :to) == :changed
      assert Activity.change_side(%{"changed" => true}, :from) == "…"
    end
  end

  describe "humanize_metadata_value/1" do
    test "renders a reference as its label" do
      assert Activity.humanize_metadata_value(%{"uuid" => "abc", "label" => "Hardware"}) ==
               "Hardware"
    end

    test "still renders a from/to pair as an arrow" do
      assert Activity.humanize_metadata_value(%{"from" => "1", "to" => "2"}) == "1 → 2"
    end

    test "renders a reference pair as label → label" do
      value = %{
        "from" => %{"uuid" => "a", "label" => "Hardware"},
        "to" => %{"uuid" => "b", "label" => "Frames"}
      }

      assert Activity.humanize_metadata_value(value) == "Hardware → Frames"
    end

    test "never raises on an arbitrary map" do
      assert is_binary(Activity.humanize_metadata_value(%{"a" => 1, "b" => %{"c" => 2}}))
    end
  end

  describe "humanize_metadata_key/1" do
    test "reads a snake_case field as a person would" do
      assert Activity.humanize_metadata_key("base_price") == "Base price"
      assert Activity.humanize_metadata_key(:unit_cost) == "Unit cost"
      assert Activity.humanize_metadata_key("sku") == "Sku"
      assert Activity.humanize_metadata_key("") == ""
    end
  end
end
