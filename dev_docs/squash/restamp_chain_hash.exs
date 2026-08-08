# Recomputes ExpectedSchema.chain_hash/0 over the v*.ex set actually shipped by
# this checkout and patches the manifest in place.
#
# Why this is a separate step: the baseline (v135.ex) is generated from a
# PRE-SQUASH checkout (the only run that can see pre-floor bimodal drift), so the
# generator cannot know the post-promotion file set — its own emitted baseline
# joins that set only after promotion. Anything that edits a chain file
# afterwards (e.g. extending a delta) also moves the hash. Run this last, after
# `mix format`, or release_check reports a stale manifest.
#
#   mix run dev_docs/squash/restamp_chain_hash.exs           # report only
#   mix run dev_docs/squash/restamp_chain_hash.exs --restamp # write
#
# WHAT THIS CANNOT CHECK, and why writing is opt-in: `chain_hash` covers the
# v*.ex files only, never the manifest BODY. Restamping therefore makes
# `release_check` pass over whatever `objects/1` currently says — so if the
# v*.ex change altered the schema the chain produces, this script would hide
# exactly the drift the hash exists to detect (Opus review 2026-08-07). It is
# the right tool ONLY when the change cannot move the schema: a comment, a
# warning message, repair logic that acts on an already-declared object. When
# the change adds, drops or reshapes anything, regenerate the manifest from a
# pre-squash checkout instead (see README, "Manifest + reference policy") and do
# not use this script. The behavioural backstop either way is
# `verify.exs --scenario s7,s8` — a stale manifest makes them fail.

write? = "--restamp" in System.argv()
manifest = "lib/phoenix_kit/migrations/expected_schema.ex"

{hash, count} = Mix.Tasks.PhoenixKit.ReleaseCheck.compute_chain_hash()
source = File.read!(manifest)

[_, current] = Regex.run(~r/@chain_hash "([0-9a-f]{64})"/, source)

changed_chain_files =
  case System.cmd("git", ["status", "--porcelain", "lib/phoenix_kit/migrations/postgres"],
         stderr_to_stdout: true
       ) do
    {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
    _ -> []
  end

cond do
  current == hash ->
    IO.puts("chain_hash up to date (#{count} files): #{hash}")

  not write? ->
    IO.puts(:stderr, """
    STALE: the manifest records #{current}
           the #{count} shipped v*.ex files hash to #{hash}

    Uncommitted files under lib/phoenix_kit/migrations/postgres:
    #{if changed_chain_files == [], do: "  (none — the drift is against committed files)", else: Enum.map_join(changed_chain_files, "\n", &"  #{&1}")}

    If ANY of those changes add, drop or reshape a database object, do NOT restamp:
    regenerate the manifest from a pre-squash checkout (README, "Manifest +
    reference policy"). Restamp only when the change cannot move the schema, then
    re-run `verify.exs --scenario s7,s8` to prove the manifest still describes
    what the chain builds:

        mix run #{Path.relative_to_cwd(__ENV__.file)} --restamp
    """)

    System.halt(1)

  true ->
    patched = String.replace(source, ~s(@chain_hash "#{current}"), ~s(@chain_hash "#{hash}"))
    File.write!(manifest, patched)

    IO.puts("""
    restamped chain_hash over #{count} files
      was: #{current}
      now: #{hash}

    This asserted nothing about the manifest BODY. Run
    `verify.exs --scenario s7,s8` before trusting release_check's PASS.
    """)
end
