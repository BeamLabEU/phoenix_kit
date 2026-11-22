defmodule PhoenixKit.Notifications.Push.WebPushTest do
  @moduledoc """
  The Web Push protocol against the RFCs: RFC 8291's worked example, a VAPID
  JWT that verifies with the public key (RFC 8292), and the endpoint checks.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Notifications.Push.WebPush

  defp d(b64), do: Base.url_decode64!(b64, padding: false)

  # RFC 8291, Appendix A.
  @plaintext "When I grow up, I want to be a watermelon"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @ua_private "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @expected "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  test "encrypts RFC 8291's example to the RFC's bytes" do
    assert {:ok, body} =
             WebPush.encrypt(@plaintext, @ua_public, @auth,
               salt: d(@salt),
               server_key: {d(@as_public), d(@as_private)}
             )

    assert Base.url_encode64(body, padding: false) == @expected
  end

  test "a random message decrypts with the browser's key" do
    {:ok, body} = WebPush.encrypt("hello", @ua_public, @auth)

    <<salt::binary-16, 4096::32, 65::8, as_public::binary-65, rest::binary>> = body
    shared = :crypto.compute_key(:ecdh, as_public, d(@ua_private), :prime256v1)
    hmac = &:crypto.mac(:hmac, :sha256, &1, &2)
    prk_key = hmac.(d(@auth), shared)

    ikm =
      binary_part(
        hmac.(prk_key, "WebPush: info" <> <<0>> <> d(@ua_public) <> as_public <> <<1>>),
        0,
        32
      )

    prk = hmac.(salt, ikm)
    cek = binary_part(hmac.(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
    nonce = binary_part(hmac.(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)
    size = byte_size(rest) - 16
    <<ciphertext::binary-size(size), tag::binary-16>> = rest

    assert :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, "", tag, false) ==
             "hello" <> <<2>>
  end

  test "host request options cannot turn redirects or retries back on" do
    opts =
      WebPush.request_options(
        plug: :test_adapter,
        redirect: true,
        retry: :safe,
        receive_timeout: 1
      )

    assert opts[:redirect] == false
    assert opts[:retry] == false
    assert opts[:plug] == :test_adapter
    assert opts[:receive_timeout] == 1
    assert opts[:connect_options] == [timeout: 5_000]
  end

  test "a payload over one record, or a malformed key, is refused" do
    assert {:error, :payload_too_large} =
             WebPush.encrypt(
               String.duplicate("a", WebPush.max_plaintext() + 1),
               @ua_public,
               @auth
             )

    assert {:error, :bad_subscription_key} = WebPush.encrypt("x", "short", @auth)
  end

  test "the VAPID JWT verifies with the public key, for the endpoint's origin" do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)

    header =
      WebPush.authorization(
        "https://fcm.googleapis.com/fcm/send/abc",
        %{public: pub, private: priv},
        "mailto:ops@example.com"
      )

    [_, jwt, k] = Regex.run(~r/\Avapid t=([^,]+), k=(.+)\z/, header)
    assert d(k) == pub

    [h, c, s] = String.split(jwt, ".")
    assert %{"alg" => "ES256"} = Jason.decode!(d(h))

    assert %{"aud" => "https://fcm.googleapis.com", "sub" => "mailto:ops@example.com"} =
             Jason.decode!(d(c))

    <<r::binary-32, s_::binary-32>> = d(s)

    der =
      :public_key.der_encode(
        :"ECDSA-Sig-Value",
        {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s_)}
      )

    assert :crypto.verify(:ecdsa, :sha256, h <> "." <> c, der, [pub, :prime256v1])
  end

  test "only HTTPS hosts of known push services are endpoints" do
    for ok <- [
          "https://fcm.googleapis.com/fcm/send/abc",
          "https://updates.push.services.mozilla.com/wpush/v2/abc",
          "https://web.push.apple.com/QAbc",
          "https://db5p.notify.windows.com/w/?token=abc"
        ],
        do: assert(WebPush.endpoint_ok?(ok, resolve: false), ok)

    for bad <- [
          "http://fcm.googleapis.com/fcm/send/abc",
          "https://evil.example/fcm.googleapis.com",
          "https://fcm.googleapis.com.evil.example/x",
          "https://user@fcm.googleapis.com/x",
          "https://169.254.169.254/latest",
          "ftp://web.push.apple.com/x",
          nil
        ],
        do: refute(WebPush.endpoint_ok?(bad, resolve: false), inspect(bad))
  end
end
