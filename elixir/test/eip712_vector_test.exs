defmodule RemitMd.EIP712VectorTest do
  use ExUnit.Case, async: true

  @private_key "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  setup_all do
    vectors_path =
      Path.join([__DIR__, "..", "..", "test-vectors", "eip712.json"])
      |> Path.expand()

    json = File.read!(vectors_path) |> Jason.decode!()
    %{vectors: json["vectors"]}
  end

  describe "EIP-712 golden vectors" do
    test "hash matches for all vectors", %{vectors: vectors} do
      assert length(vectors) > 0, "No vectors loaded"

      for v <- vectors do
        domain = v["domain"]
        msg = v["message"]

        nonce_hex = String.trim_leading(msg["nonce"], "0x")
        nonce_bytes = Base.decode16!(nonce_hex, case: :mixed)

        # Parse timestamp safely (handles u64::MAX which exceeds float precision)
        timestamp =
          case msg["timestamp"] do
            ts when is_integer(ts) -> ts
            ts when is_float(ts) -> trunc(ts)
          end

        hash =
          RemitMd.Http.eip712_hash(
            domain["chain_id"],
            domain["verifying_contract"],
            msg["method"],
            msg["path"],
            timestamp,
            nonce_bytes
          )

        got = "0x" <> Base.encode16(hash, case: :lower)
        assert got == v["expected_hash"], "Hash mismatch for: #{v["description"]}"
      end
    end

    test "signature is valid for all vectors", %{vectors: vectors} do
      signer = RemitMd.PrivateKeySigner.new(@private_key)
      assert String.downcase(signer.address) == "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

      for v <- vectors do
        domain = v["domain"]
        msg = v["message"]

        nonce_hex = String.trim_leading(msg["nonce"], "0x")
        nonce_bytes = Base.decode16!(nonce_hex, case: :mixed)

        timestamp =
          case msg["timestamp"] do
            ts when is_integer(ts) -> ts
            ts when is_float(ts) -> trunc(ts)
          end

        digest =
          RemitMd.Http.eip712_hash(
            domain["chain_id"],
            domain["verifying_contract"],
            msg["method"],
            msg["path"],
            timestamp,
            nonce_bytes
          )

        # OTP's ECDSA uses different RFC 6979 k derivation than Rust's k256,
        # so exact signatures differ. Verify structure and validity instead.
        # sign/2 internally recovers v via ecrecover — raises if the signature
        # doesn't match the signer's address, so a successful return = valid.
        sig = RemitMd.PrivateKeySigner.sign(signer, digest)
        sig_hex = String.trim_leading(sig, "0x")
        sig_bytes = Base.decode16!(sig_hex, case: :mixed)
        assert byte_size(sig_bytes) == 65, "Sig must be 65 bytes for: #{v["description"]}"
        v_byte = :binary.at(sig_bytes, 64)
        assert v_byte in [27, 28], "v must be 27 or 28 for: #{v["description"]}"
      end
    end
  end
end
