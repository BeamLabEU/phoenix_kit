defmodule PhoenixKit.Users.ReferralsValidationTest do
  @moduledoc """
  Covers `Referrals.validate_for_signup/2` — the shared validator every signup
  surface funnels through.

  These run without the `phoenix_kit_referrals` package installed, so
  `get_code_by_string/1` always resolves to `nil` and any typed code is rejected.
  That is exactly the shape the security properties need: the assertions here are
  about *what the form reveals* and *when it complains*, not about which codes
  happen to be valid.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Referrals

  @enabled [enabled?: true, required?: true]

  describe "a typed code is not checked while the user is still typing" do
    test "the :change context never rejects, however wrong the code" do
      # This REVERSES an earlier decision that a touched field was fair to
      # complain about. Two reasons pointing the same way: checking per keystroke
      # hands an attacker a much faster oracle than the submit button does, and
      # it spends a rate-limit token per character — so a real person typing an
      # eight-character code and fixing a typo can exhaust their own budget and
      # be told "too many attempts" while holding a good code.
      assert {:ok, nil} =
               Referrals.validate_for_signup(
                 "DEFINITELY-NOT-A-CODE",
                 @enabled ++ [context: :change]
               )
    end

    test "the same code IS rejected on submit" do
      assert {:error, _} =
               Referrals.validate_for_signup(
                 "DEFINITELY-NOT-A-CODE",
                 @enabled ++ [context: :submit]
               )
    end
  end

  describe "context: when a blank required code is an error" do
    test "typing elsewhere in the form does not trigger the required nag" do
      # The regression: validation runs on every phx-change, so treating
      # blank-and-required as invalid made "Referral code is required" appear
      # while the user was still typing their email — before they had reached
      # the field at all.
      assert {:ok, nil} = Referrals.validate_for_signup("", @enabled ++ [context: :change])
      assert {:ok, nil} = Referrals.validate_for_signup(nil, @enabled ++ [context: :change])
    end

    test "submitting without one still fails" do
      assert {:error, "Referral code is required"} =
               Referrals.validate_for_signup("", @enabled ++ [context: :submit])
    end

    test "whitespace counts as blank, not as a typed code" do
      assert {:ok, nil} = Referrals.validate_for_signup("   ", @enabled ++ [context: :change])

      assert {:error, "Referral code is required"} =
               Referrals.validate_for_signup("   ", @enabled ++ [context: :submit])
    end
  end

  describe "rejections are indistinguishable" do
    test "a rejection never says why" do
      # Distinct strings ("Invalid" vs "expired" vs "usage limit") confirmed
      # whether a guessed code EXISTS, turning the form into an enumeration
      # oracle. Operators still get the reason via Logger.debug.
      {:error, message} = Referrals.validate_for_signup("ZZZZZ", @enabled ++ [context: :submit])

      refute message =~ ~r/invalid|expired|active|limit/i,
             "rejection message leaks which failure occurred: #{inspect(message)}"
    end

    test "every rejected code returns the same message" do
      messages =
        for code <- ~w(AAAAA BBBBB CCCCC 22222) do
          {:error, m} = Referrals.validate_for_signup(code, @enabled ++ [context: :submit])
          m
        end

      assert length(Enum.uniq(messages)) == 1,
             "codes produced distinguishable messages: #{inspect(Enum.uniq(messages))}"
    end
  end

  describe "rejections are translated where they are produced" do
    # The registration and magic-link forms print the returned string as it is,
    # so the translation has to happen here. Before, all three messages came back
    # as English literals and a Russian-language site showed them in English.
    @locales_with_required ~w(de es et fr it pl ru uk zh)

    defp in_locale(locale, fun), do: Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fun)

    test "a blank required code" do
      assert {:error, "Реферальный код обязателен"} =
               in_locale("ru", fn ->
                 Referrals.validate_for_signup("", @enabled ++ [context: :submit])
               end)

      assert {:error, "Referral code is required"} =
               in_locale("en", fn ->
                 Referrals.validate_for_signup("", @enabled ++ [context: :submit])
               end)
    end

    test "a rejected code" do
      assert {:error, "Этот код нельзя использовать"} =
               in_locale("ru", fn ->
                 Referrals.validate_for_signup("ZZZZZ", @enabled ++ [context: :submit])
               end)
    end

    test "the rate-limit refusal" do
      ip = "203.0.113.#{:erlang.unique_integer([:positive]) |> rem(250)}"
      opts = @enabled ++ [context: :submit, ip_address: ip]

      messages =
        capture_log(fn ->
          in_locale("ru", fn ->
            send(self(), {:m, for(_ <- 1..40, do: Referrals.validate_for_signup("NOPE1", opts))})
          end)
        end)
        |> then(fn _ ->
          receive do
            {:m, r} -> for {:error, m} <- r, do: m
          end
        end)

      assert "Слишком много попыток. Повторите чуть позже." in messages
      refute "Too many attempts. Please try again shortly." in messages
    end

    test "the required-code message is in the catalogue of every shipped locale" do
      root = Path.expand("../../..", __DIR__)

      {:ok, pot} = Expo.PO.parse_file(Path.join(root, "priv/gettext/default.pot"))

      assert Enum.any?(
               pot.messages,
               &(IO.iodata_to_binary(&1.msgid) == "Referral code is required")
             )

      for locale <- @locales_with_required do
        {:ok, po} =
          Expo.PO.parse_file(Path.join(root, "priv/gettext/#{locale}/LC_MESSAGES/default.po"))

        msg =
          Enum.find(po.messages, &(IO.iodata_to_binary(&1.msgid) == "Referral code is required"))

        assert msg, "#{locale}: msgid missing"
        assert IO.iodata_to_binary(msg.msgstr) != "", "#{locale}: not translated"
      end
    end
  end

  describe "disabled system" do
    test "nothing is required or checked when referrals are off" do
      opts = [enabled?: false, required?: true, context: :submit]
      assert {:ok, nil} = Referrals.validate_for_signup("", opts)
      assert {:ok, nil} = Referrals.validate_for_signup("ANYTHING", opts)
    end
  end

  describe "optional codes" do
    test "blank passes, but a typed code is still checked" do
      opts = [enabled?: true, required?: false, context: :submit]
      assert {:ok, nil} = Referrals.validate_for_signup("", opts)
      assert {:error, _} = Referrals.validate_for_signup("NOPE1", opts)
    end
  end

  describe "rate limiting" do
    test "repeated code checking from one IP is eventually refused" do
      ip = "203.0.113.#{:erlang.unique_integer([:positive]) |> rem(250)}"
      opts = @enabled ++ [context: :submit, ip_address: ip]

      # The limiter guards code *checking*, which is what makes guessing cheap:
      # Auth.register_user/2's own limiter sits behind referral validation, so a
      # wrong code short-circuits before ever reaching it.
      # Captured because tripping the limit is the point, and it logs a warning
      # per refusal.
      results =
        capture_log(fn ->
          send(
            self(),
            {:results, for(_ <- 1..40, do: Referrals.validate_for_signup("NOPE1", opts))}
          )
        end)
        |> then(fn _ ->
          receive do
            {:results, r} -> r
          end
        end)

      assert Enum.any?(results, fn
               {:error, m} -> m =~ ~r/too many/i
               _ -> false
             end),
             "40 consecutive code checks from one IP were never rate-limited"
    end

    test "a blank code is not charged against the limit" do
      # Only typed codes are checks worth throttling; blanks are just an empty
      # field on a form the user is still filling in.
      ip = "203.0.113.#{:erlang.unique_integer([:positive]) |> rem(250)}"
      opts = @enabled ++ [context: :change, ip_address: ip]

      for _ <- 1..50, do: assert({:ok, nil} = Referrals.validate_for_signup("", opts))
    end

    test "works without an IP rather than locking registration out" do
      # Embedded mounts and hosts that do not thread peer data have no IP. The
      # submit path still runs register_user/2's own limiter.
      assert {:error, _} =
               Referrals.validate_for_signup("NOPE1", @enabled ++ [context: :submit])
    end
  end
end
