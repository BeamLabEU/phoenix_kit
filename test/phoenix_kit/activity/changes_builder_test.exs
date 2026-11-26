defmodule PhoenixKit.Activity.ChangesBuilderTest do
  @moduledoc """
  `PhoenixKit.Activity.changes/2,3` — the builder of the `"changes"` map — and
  the `changes:` option of `log/3` up to the point where it lands in the entry
  changeset (no database).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Activity

  defmodule Widget do
    use Ecto.Schema

    @primary_key {:uuid, :binary_id, autogenerate: false}
    embedded_schema do
      field(:name, :string)
      field(:price, :decimal)
      field(:released_on, :date)
      field(:seen_at, :utc_datetime)
      field(:kind, Ecto.Enum, values: [:goods, :service])
      field(:tags, {:array, :string})
      field(:settings, :map)
      field(:active, :boolean)
      field(:password, :string, virtual: true)
      field(:hashed_password, :string)
      field(:api_key, :string)
      field(:reset_token, :string)
      field(:body, :string)
      timestamps(type: :utc_datetime)
    end
  end

  defmodule Plain do
    defstruct [:a]
  end

  defp widget(attrs \\ []) do
    struct(
      %Widget{
        uuid: "019a0000-0000-7000-8000-000000000001",
        name: "Old",
        price: Decimal.new("1.50"),
        released_on: ~D[2026-01-01],
        kind: :goods,
        tags: ["a"],
        settings: %{"theme" => "dark"},
        active: true
      },
      attrs
    )
  end

  defp change(attrs), do: Ecto.Changeset.change(widget(), attrs)

  describe "changes/2 with a changeset" do
    test "records from/to for each changed field, in the Catalogue shape" do
      assert Activity.changes(change(name: "New")) ==
               %{"name" => %{"from" => "Old", "to" => "New"}}
    end

    test "nothing moved is an empty map" do
      assert Activity.changes(change(%{})) == %{}
      # `change/2` drops a value equal to the data's own.
      assert Activity.changes(change(name: "Old")) == %{}
    end

    test "values are JSON-safe" do
      cs =
        change(
          price: Decimal.new("2.00"),
          released_on: ~D[2026-11-26],
          seen_at: ~U[2026-11-26 10:00:00Z],
          kind: :service,
          tags: ["a", "b"],
          settings: %{"theme" => "light", nested: %{deep: [1, 2]}}
        )

      changes = Activity.changes(cs)

      assert changes["price"] == %{"from" => "1.50", "to" => "2.00"}
      assert changes["released_on"] == %{"from" => "2026-01-01", "to" => "2026-11-26"}
      assert changes["seen_at"] == %{"from" => nil, "to" => "2026-11-26T10:00:00Z"}
      assert changes["kind"] == %{"from" => "goods", "to" => "service"}
      assert changes["tags"] == %{"from" => ["a"], "to" => ["a", "b"]}
      assert changes["settings"]["from"] == ~s({"theme":"dark"})

      assert Jason.decode!(changes["settings"]["to"]) == %{
               "theme" => "light",
               "nested" => %{"deep" => [1, 2]}
             }

      # The whole map round-trips through JSON unchanged.
      assert changes |> Jason.encode!() |> Jason.decode!() == changes
    end

    test "secret fields are flagged, never stored" do
      cs =
        change(
          password: "hunter2-secret",
          hashed_password: "$2b$12$abc",
          api_key: "pk_live_123",
          reset_token: "tok"
        )

      changes = Activity.changes(cs)

      for field <- ~w(password hashed_password api_key reset_token) do
        assert changes[field] == %{"changed" => true}, field
      end

      json = Jason.encode!(changes)
      refute json =~ "hunter2"
      refute json =~ "abc"
      refute json =~ "pk_live"
    end

    test "more secret-looking names are flagged, whole words only for the short ones" do
      secret =
        ~w(passphrase encryption_key otp otp_code pin signature key ssh_key cookie
           session_id authorization)

      plain = ~w(pinned key_name footprint monkey spinner)
      before = Map.new(secret ++ plain, &{&1, "old"})
      later = Map.new(secret ++ plain, &{&1, "hunter2"})

      changes = Activity.changes(before, later)

      for field <- secret, do: assert(changes[field] == %{"changed" => true}, field)

      for field <- plain,
          do: assert(changes[field] == %{"from" => "old", "to" => "hunter2"}, field)

      nested = Activity.changes(%{cfg: %{}}, %{cfg: %{"passphrase" => "hunter2"}})
      refute Jason.encode!(nested) =~ "hunter2"
    end

    test "secret keys inside a map value are filtered" do
      changes = Activity.changes(change(settings: %{"theme" => "x", "smtp_password" => "pw"}))
      refute changes["settings"]["to"] =~ "pw\""
      assert changes["settings"]["to"] =~ "[FILTERED]"
    end

    test ":only, :except and :redact" do
      cs = change(name: "New", active: false, body: "text")

      assert Map.keys(Activity.changes(cs, only: [:name])) == ["name"]
      assert Map.keys(Activity.changes(cs, only: ["name"])) == ["name"]
      assert Map.keys(Activity.changes(cs, except: [:name, :body])) == ["active"]
      assert Activity.changes(cs, redact: [:body])["body"] == %{"changed" => true}
    end

    test ":only cannot bring a secret back" do
      assert Activity.changes(change(api_key: "k"), only: [:api_key]) ==
               %{"api_key" => %{"changed" => true}}
    end

    test "long strings are cut with a marker" do
      long = String.duplicate("x", 600)
      %{"body" => %{"from" => nil, "to" => to}} = Activity.changes(change(body: long))

      assert String.length(to) == 501
      assert String.ends_with?(to, "…")

      %{"body" => %{"to" => short}} = Activity.changes(change(body: long), max_length: 10)
      assert short == String.duplicate("x", 10) <> "…"
    end

    test "two long values that cut to the same text are flagged" do
      a = String.duplicate("x", 600) <> "a"
      b = String.duplicate("x", 600) <> "b"
      cs = Ecto.Changeset.change(widget(body: a), body: b)

      assert Activity.changes(cs) == %{"body" => %{"changed" => true}}
    end

    test "long lists are capped" do
      tags = Enum.map(1..80, &"t#{&1}")
      %{"tags" => %{"to" => to}} = Activity.changes(change(tags: tags))

      assert length(to) == 51
      assert List.last(to) == "…"
    end

    test ":max_fields keeps the first fields alphabetically" do
      cs = change(name: "New", active: false, body: "b")
      assert Map.keys(Activity.changes(cs, max_fields: 2)) == ["active", "body"]
    end

    test "timestamps are never reported" do
      cs = change(updated_at: ~U[2026-11-26 10:00:00Z], name: "New")
      assert Map.keys(Activity.changes(cs)) == ["name"]
    end

    test "timestamps are never reported from string-keyed maps either" do
      before = %{"updated_at" => 1, "inserted_at" => 1, "name" => "a"}
      later = %{"updated_at" => 2, "inserted_at" => 2, "name" => "b"}

      assert Map.keys(Activity.changes(before, later)) == ["name"]
      assert Map.keys(Activity.changes(before, later, only: ["updated_at", "name"])) == ["name"]
    end
  end

  describe "changes/2,3 with before and after" do
    test "a schema struct compares its schema fields" do
      assert Activity.changes(widget(), widget(name: "New", active: false)) == %{
               "active" => %{"from" => true, "to" => false},
               "name" => %{"from" => "Old", "to" => "New"}
             }
    end

    test "decimals equal in value are not a change" do
      assert Activity.changes(widget(), widget(price: Decimal.new("1.5"))) == %{}
    end

    test "plain maps, with :only" do
      assert Activity.changes(%{roles: ["User"]}, %{roles: ["Admin", "User"]}) ==
               %{"roles" => %{"from" => ["User"], "to" => ["Admin", "User"]}}

      assert Activity.changes(%{a: 1, b: 1}, %{a: 2, b: 2}, only: [:b]) ==
               %{"b" => %{"from" => 1, "to" => 2}}
    end

    test "a struct with no String.Chars is named, not dumped" do
      assert Activity.changes(%{v: nil}, %{v: %Plain{a: "secret stuff"}}) ==
               %{
                 "v" => %{
                   "from" => nil,
                   "to" => "%PhoenixKit.Activity.ChangesBuilderTest.Plain{}"
                 }
               }
    end

    test "invalid UTF-8 and raw UUIDs" do
      raw = Ecto.UUID.dump!("019a0000-0000-7000-8000-000000000002")

      assert Activity.changes(%{u: nil}, %{u: raw})["u"]["to"] ==
               "019a0000-0000-7000-8000-000000000002"

      assert Activity.changes(%{b: nil}, %{b: <<255, 0, 1>>})["b"]["to"] =~ "binary"
    end

    test "an association that was not loaded is skipped" do
      before = %{owner: %Ecto.Association.NotLoaded{}, name: "a"}
      later = %{owner: %{name: "x"}, name: "b"}
      assert Map.keys(Activity.changes(before, later)) == ["name"]
    end
  end

  describe "the changes: option" do
    defp metadata(attrs),
      do: Activity.entry_changeset(attrs) |> Ecto.Changeset.get_field(:metadata)

    test "a changeset lands under the reserved key, beside the caller's metadata" do
      md =
        metadata(%{
          action: "widget.updated",
          metadata: %{"name" => "New"},
          changes: change(name: "New")
        })

      assert md == %{"name" => "New", "changes" => %{"name" => %{"from" => "Old", "to" => "New"}}}
    end

    test "a {before, after, opts} tuple and a ready map are taken" do
      md = metadata(%{action: "x.y", changes: {%{a: 1, b: 1}, %{a: 2, b: 2}, only: [:a]}})
      assert md["changes"] == %{"a" => %{"from" => 1, "to" => 2}}

      md = metadata(%{action: "x.y", changes: %{name: %{from: ~D[2026-01-01], to: nil}}})
      assert md["changes"] == %{"name" => %{"from" => "2026-01-01", "to" => nil}}
    end

    test "a ready map is sanitized too" do
      md = metadata(%{action: "x.y", changes: %{"password" => %{"from" => "a", "to" => "b"}}})
      assert md["changes"] == %{"password" => %{"changed" => true}}
    end

    test "nothing moved writes no changes key" do
      md = metadata(%{action: "x.y", metadata: %{"k" => "v"}, changes: change(%{})})
      assert md == %{"k" => "v"}
    end

    test "the option wins over a changes key in the metadata" do
      md =
        metadata(%{
          action: "x.y",
          metadata: %{"changes" => "forged"},
          changes: change(name: "New")
        })

      assert md["changes"] == %{"name" => %{"from" => "Old", "to" => "New"}}
    end

    test "a stored diff normalized again is unchanged" do
      built = Activity.changes(change(body: String.duplicate("y", 900), name: "New"))
      md = metadata(%{action: "x.y", changes: built})
      assert md["changes"] == built
    end
  end
end
