defmodule PhoenixKit.Migrations.Postgres.V220Test do
  @moduledoc """
  V220's confirmation and idempotency tables, run as the real SQL: defaults and
  round trips, every constraint, the two foreign keys, a re-run and a round trip
  of the migration, and that the manifest (`ExpectedSchema`) declares exactly what
  the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.Fixtures, only: [user_fixture: 0]

  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Idempotency.Record
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V220
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe

  setup do
    KeyTestSupport.start_key_cache!()
    {user, _role} = KeyTestSupport.user_with(["settings"])

    {key, _token} =
      KeyTestSupport.create_key!(user, KeyTestSupport.scope_of(user), %{name: "v220", scopes: []})

    %{user: user, key: key}
  end

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp future, do: DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)

  defp confirmation(overrides) do
    n = System.unique_integer([:positive])

    struct(
      Confirmation,
      Map.merge(
        %{
          kind: "token",
          tool: "testkit.write_item",
          input_hash: String.pad_leading(Integer.to_string(n, 16), 64, "0"),
          fingerprint: String.duplicate("a", 64),
          status: "unused",
          expires_at: future()
        },
        Map.new(overrides)
      )
    )
  end

  defp record(overrides) do
    n = System.unique_integer([:positive])

    struct(
      Record,
      Map.merge(
        %{
          scope_ref: "scope-#{n}",
          key: "key-#{n}-aaaaaaaaaaaaaaaa",
          request_hash: String.duplicate("b", 64),
          state: "in_progress",
          locked_at: DateTime.utc_now(),
          expires_at: future()
        },
        Map.new(overrides)
      )
    )
  end

  describe "phoenix_kit_api_confirmations" do
    test "the chain is at 220 or later" do
      assert String.to_integer(marker()) >= 220
    end

    test "stores a code row with the defaults of a plain one", %{key: key} do
      row = Repo.insert!(confirmation(actor_key_uuid: key.uuid))
      row = Repo.get!(Confirmation, row.uuid)

      assert row.kind == "token"
      assert row.input == nil
      assert row.context == %{}
      assert row.preview == %{}
      assert row.used_at == nil
      assert row.decided_by_uuid == nil
      assert row.result == nil
      assert row.notified_at == nil
      assert row.inserted_at && row.updated_at
    end

    test "round-trips an approval with its input, preview and result", %{key: key} do
      row =
        Repo.insert!(
          confirmation(
            kind: "approval",
            status: "pending",
            actor_key_uuid: key.uuid,
            input: %{"ids" => ["a", "b"]},
            context: %{"language" => "en", "base_url" => "https://shop.example"},
            preview: %{"rows" => [%{"ref" => "a"}], "totals" => %{"delete" => 2}},
            result: %{"partial" => %{"done" => 1}}
          )
        )

      row = Repo.get!(Confirmation, row.uuid)

      assert row.input == %{"ids" => ["a", "b"]}
      assert row.context["base_url"] == "https://shop.example"
      assert row.preview["totals"] == %{"delete" => 2}
      assert row.result == %{"partial" => %{"done" => 1}}
    end

    test "a row with neither a key nor a cart token is refused" do
      assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_confirmations_actor_check/, fn ->
        Repo.insert!(confirmation(%{}))
      end
    end

    test "a public code is bound to a client token hash, stored in the cart_token_hash column" do
      hash = String.duplicate("c", 43)
      assert %Confirmation{} = row = Repo.insert!(confirmation(client_token_hash: hash))

      assert [[^hash]] =
               query(
                 "SELECT cart_token_hash FROM phoenix_kit_api_confirmations WHERE uuid = $1",
                 [
                   Ecto.UUID.dump!(row.uuid)
                 ]
               )
    end

    test "kind and status are closed lists", %{key: key} do
      assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_confirmations_kind_check/, fn ->
        Repo.insert!(confirmation(kind: "other", actor_key_uuid: key.uuid))
      end

      for bad <- ["", "pending_approval", "UNUSED", "done"] do
        assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_confirmations_status_check/, fn ->
          Repo.insert!(confirmation(status: bad, actor_key_uuid: key.uuid))
        end
      end

      for good <-
            ~w(unused used expired pending approved executing executed failed rejected stale) do
        assert %Confirmation{} =
                 Repo.insert!(confirmation(status: good, actor_key_uuid: key.uuid))
      end
    end

    test "deleting the key deletes its rows", %{key: key} do
      row = Repo.insert!(confirmation(actor_key_uuid: key.uuid))
      Repo.delete!(key)
      assert Repo.get(Confirmation, row.uuid) == nil
    end

    test "deleting the person who decided keeps the row, with no decider", %{key: key} do
      decider = user_fixture()

      row =
        Repo.insert!(
          confirmation(
            kind: "approval",
            status: "rejected",
            actor_key_uuid: key.uuid,
            decided_by_uuid: decider.uuid
          )
        )

      Repo.delete!(decider)
      assert %Confirmation{decided_by_uuid: nil} = Repo.get!(Confirmation, row.uuid)
    end
  end

  describe "the stuck-operation sweep index" do
    test "indexes updated_at for the running statuses" do
      assert [["updated_at", predicate]] =
               query("""
               SELECT pg_get_indexdef(indexrelid, 1, true), pg_get_expr(indpred, indrelid)
               FROM pg_index
               WHERE indexrelid = 'public.phoenix_kit_api_confirmations_active_updated_at_index'::regclass
                 AND indrelid = 'public.phoenix_kit_api_confirmations'::regclass
                 AND indisvalid AND indisready AND indnkeyatts = 1
               """)

      statuses = ~w(unused used expired pending approved executing executed failed rejected stale)

      assert [["approved"], ["executing"]] =
               query(
                 "SELECT status FROM unnest($1::text[]) AS states(status) WHERE #{predicate} ORDER BY status",
                 [statuses]
               )
    end
  end

  describe "phoenix_kit_api_idempotency" do
    test "stores a record with the defaults" do
      row = Repo.insert!(record(%{}))
      row = Repo.get!(Record, row.uuid)

      assert row.state == "in_progress"
      assert row.response == nil
      assert row.inserted_at
      assert %DateTime{microsecond: {_, 6}} = row.locked_at
    end

    test "a scope and key pair is unique, the same key in another scope is not" do
      Repo.insert!(record(scope_ref: "s1", key: "k-aaaaaaaaaaaaaaaaaa"))

      assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_idempotency_scope_key_index/, fn ->
        Repo.insert!(record(scope_ref: "s1", key: "k-aaaaaaaaaaaaaaaaaa"))
      end

      assert %Record{} = Repo.insert!(record(scope_ref: "s2", key: "k-aaaaaaaaaaaaaaaaaa"))
    end

    test "state is in_progress or done" do
      assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_idempotency_state_check/, fn ->
        Repo.insert!(record(state: "failed"))
      end

      assert %Record{} = Repo.insert!(record(state: "done", response: ~s({"ok":true})))
    end
  end

  describe "the migration" do
    test "running it again changes nothing", %{key: key} do
      row = Repo.insert!(confirmation(actor_key_uuid: key.uuid))
      rec = Repo.insert!(record(%{}))

      run(V220.up_statements("public"))
      run(V220.up_statements("public"))

      assert %Confirmation{} = Repo.get!(Confirmation, row.uuid)
      assert %Record{} = Repo.get!(Record, rec.uuid)
      assert String.to_integer(marker()) >= 220
    end

    test "rolls back and forward again" do
      run(V220.down_statements("public"))

      assert [[nil]] = query("SELECT to_regclass('public.phoenix_kit_api_confirmations')::text")
      assert [[nil]] = query("SELECT to_regclass('public.phoenix_kit_api_idempotency')::text")
      assert [[_]] = query("SELECT to_regclass('public.phoenix_kit_api_keys')::text")
      assert marker() == "219"

      run(V220.up_statements("public"))

      assert [["phoenix_kit_api_confirmations"]] =
               query("SELECT to_regclass('public.phoenix_kit_api_confirmations')::text")

      assert marker() == "220"
    end
  end

  describe "the manifest" do
    defp declared_by_v220 do
      for %{since: 220} = object <- ExpectedSchema.objects("public"), do: object
    end

    defp newest_shape(%{revisions: revisions}) do
      {_version, shape} = Enum.max_by(revisions, fn {version, _} -> version end)
      shape
    end

    defp problem(_object, nil), do: :missing

    defp problem(object, observed) do
      case Differ.compare(object.class, newest_shape(object), observed) do
        :match ->
          nil

        {:mismatch, _} = mismatch ->
          if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
      end
    end

    test "declares 2 tables, 28 columns, 8 constraints and 6 indexes" do
      objects = declared_by_v220()

      assert %{table: 2, column: 28, constraint: 8, index: 6} =
               Enum.frequencies_by(objects, & &1.class)

      assert length(objects) == 44
    end

    test "every object it declares matches what the chain built" do
      assert declared_by_v220() != []
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v220(),
            problem = problem(object, Probe.lookup(snapshot, object.check)),
            do: {object.id, problem}

      assert problems == []
    end

    # By V220 or a later version (V222 adds `actor_user_uuid`).
    test "every column of the two tables is declared, and nothing else is" do
      for table <- ["phoenix_kit_api_confirmations", "phoenix_kit_api_idempotency"] do
        declared =
          for %{class: :column, since: since, id: "column:" <> rest} <-
                ExpectedSchema.objects("public"),
              since >= 220,
              [^table, name] <- [String.split(rest, ".")],
              do: name

        actual =
          for [name] <-
                query(
                  "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1",
                  [table]
                ),
              do: name

        assert Enum.sort(declared) == Enum.sort(actual), table
      end
    end
  end
end
