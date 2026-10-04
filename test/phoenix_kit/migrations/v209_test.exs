defmodule PhoenixKit.Migrations.Postgres.V209Test do
  @moduledoc """
  V209's local and cloud copy counts, run as the real SQL: the columns and their
  check (the total stays `copies_originals`), the backfill that splits an old
  count by the buckets a profile has (local first), that a re-run leaves a
  chosen split alone, and a round trip.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V209
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp violation?(fun, code) do
    fun.()
    false
  rescue
    error in Postgrex.Error -> error.postgres.code == code
  end

  defp bucket!(provider, opts \\ []) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_buckets
          (name, provider, access_type, enabled, priority, inserted_at, updated_at)
        VALUES ($1, $2, 'public', $3, 0, now(), now()) RETURNING uuid::text
        """,
        [
          "v209-#{System.unique_integer([:positive])}",
          provider,
          Keyword.get(opts, :enabled, true)
        ]
      )

    uuid
  end

  defp profile!(copies, buckets) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_storage_profiles
          (name, copies_originals, copies_variants, copies_local, copies_cloud)
        VALUES ($1, $2, $2, $2, 0) RETURNING uuid::text
        """,
        ["v209-#{System.unique_integer([:positive])}", copies]
      )

    for {bucket, status} <- buckets do
      query(
        """
        INSERT INTO public.phoenix_kit_storage_profile_buckets
          (profile_uuid, bucket_uuid, status, inserted_at, updated_at)
        VALUES ($1::text::uuid, $2::text::uuid, $3, now(), now())
        """,
        [uuid, bucket, status]
      )
    end

    uuid
  end

  defp counts(uuid) do
    [[local, cloud]] =
      query(
        "SELECT copies_local, copies_cloud FROM public.phoenix_kit_storage_profiles WHERE uuid = $1::text::uuid",
        [uuid]
      )

    {local, cloud}
  end

  # The columns come back through the migration, which is what splits the rows.
  defp migrate_again do
    run(V209.down_statements("public"))
    run(V209.up_statements("public"))
  end

  test "the chain is at 209 or later, with the columns and their defaults" do
    assert String.to_integer(marker()) >= 209

    assert [["copies_cloud", "0"], ["copies_local", "1"]] =
             query("""
             SELECT column_name, column_default FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_profiles'
               AND column_name IN ('copies_local', 'copies_cloud')
             ORDER BY column_name
             """)
  end

  describe "the check" do
    test "the two counts add up to the total" do
      uuid = profile!(1, [])

      assert violation?(
               fn ->
                 query(
                   "UPDATE public.phoenix_kit_storage_profiles SET copies_local = 2 WHERE uuid = $1::text::uuid",
                   [uuid]
                 )
               end,
               :check_violation
             )
    end

    test "each count stays within 0..5" do
      uuid = profile!(1, [])

      assert violation?(
               fn ->
                 query(
                   "UPDATE public.phoenix_kit_storage_profiles SET copies_local = -1, copies_cloud = 2 WHERE uuid = $1::text::uuid",
                   [uuid]
                 )
               end,
               :check_violation
             )
    end

    test "a cloud-only profile is allowed" do
      uuid = profile!(1, [])

      query(
        "UPDATE public.phoenix_kit_storage_profiles SET copies_local = 0, copies_cloud = 1 WHERE uuid = $1::text::uuid",
        [uuid]
      )

      assert counts(uuid) == {0, 1}
    end
  end

  describe "the backfill splits an old count by the buckets, local first" do
    test "one local and two cloud buckets" do
      [local, cloud1, cloud2] = [bucket!("local"), bucket!("r2"), bucket!("b2")]
      one = profile!(1, [{local, "active"}, {cloud1, "active"}, {cloud2, "active"}])
      two = profile!(2, [{local, "active"}, {cloud1, "active"}, {cloud2, "active"}])
      three = profile!(3, [{local, "active"}, {cloud1, "active"}, {cloud2, "active"}])

      migrate_again()

      assert counts(one) == {1, 0}
      assert counts(two) == {1, 1}
      assert counts(three) == {1, 2}
    end

    test "only cloud buckets: all cloud" do
      uuid = profile!(1, [{bucket!("r2"), "active"}])
      migrate_again()
      assert counts(uuid) == {0, 1}
    end

    test "no bucket yet: all local" do
      uuid = profile!(2, [])
      migrate_again()
      assert counts(uuid) == {2, 0}
    end

    test "a bucket that cannot take files does not count" do
      uuid = profile!(2, [{bucket!("local"), "active"}, {bucket!("r2"), "read_only"}])
      migrate_again()
      assert counts(uuid) == {2, 0}

      disabled = profile!(1, [{bucket!("r2", enabled: false), "active"}])
      migrate_again()
      assert counts(disabled) == {1, 0}
    end

    test "the total never changes" do
      uuid = profile!(5, [{bucket!("local"), "active"}, {bucket!("r2"), "active"}])
      migrate_again()
      {local, cloud} = counts(uuid)
      assert local + cloud == 5
    end
  end

  test "a re-run leaves a chosen split alone" do
    uuid = profile!(2, [{bucket!("local"), "active"}, {bucket!("r2"), "active"}])
    migrate_again()
    assert counts(uuid) == {1, 1}

    query(
      "UPDATE public.phoenix_kit_storage_profiles SET copies_local = 2, copies_cloud = 0 WHERE uuid = $1::text::uuid",
      [uuid]
    )

    run(V209.up_statements("public"))

    assert counts(uuid) == {2, 0}
    assert String.to_integer(marker()) >= 209
  end

  test "a round trip removes the columns and the check, and puts them back" do
    run(V209.down_statements("public"))

    assert [] ==
             query("""
             SELECT column_name FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'phoenix_kit_storage_profiles'
               AND column_name IN ('copies_local', 'copies_cloud')
             """)

    assert marker() == "208"

    run(V209.up_statements("public"))

    assert marker() == "209"

    assert [["phoenix_kit_storage_profiles_local_cloud_check"]] =
             query("""
             SELECT conname FROM pg_constraint
             WHERE conrelid = 'public.phoenix_kit_storage_profiles'::regclass
               AND conname = 'phoenix_kit_storage_profiles_local_cloud_check'
             """)
  end
end
