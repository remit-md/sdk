defmodule RemitMdTest do
  use ExUnit.Case, async: false

  alias RemitMd.{MockRemit, Wallet}
  alias RemitMd.Models.{Balance, Escrow, Reputation, SpendingSummary, Transaction, TransactionList}
  alias RemitMd.Error

  @payer   "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @payee   "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @other   "0xcccccccccccccccccccccccccccccccccccccccc"

  setup do
    {:ok, mock} = MockRemit.start_link()
    MockRemit.set_balance(mock, @payer, "500.00")
    wallet = Wallet.new(mock: mock, address: @payer)
    %{mock: mock, wallet: wallet}
  end

  # ─── Wallet construction ──────────────────────────────────────────────────

  test "new/1 with mock creates wallet without keys", %{wallet: wallet} do
    assert wallet.address == @payer
    assert wallet.mock_pid != nil
  end

  test "from_env/0 raises when REMITMD_KEY not set" do
    System.delete_env("REMITMD_KEY")
    System.delete_env("REMITMD_PRIVATE_KEY")
    assert_raise RemitMd.Error, ~r/REMITMD_KEY/, fn ->
      Wallet.from_env()
    end
  end

  # ─── Balance ──────────────────────────────────────────────────────────────

  test "balance/1 returns current USDC balance", %{wallet: wallet} do
    {:ok, bal} = Wallet.balance(wallet)
    assert %Balance{} = bal
    assert bal.usdc == "500.00"
    assert bal.address == @payer
  end

  # ─── Pay (direct) ─────────────────────────────────────────────────────────

  test "pay/4 sends USDC and returns transaction", %{wallet: wallet} do
    {:ok, tx} = Wallet.pay(wallet, @payee, "25.00")
    assert %Transaction{} = tx
    assert tx.from == @payer
    assert tx.to == @payee
    assert tx.amount_usdc == "25.00"
    assert tx.status == "confirmed"
    assert String.starts_with?(tx.tx_hash, "0x")
  end

  test "pay/4 records the transaction in mock", %{mock: mock, wallet: wallet} do
    Wallet.pay(wallet, @payee, "10.00")
    assert MockRemit.was_paid?(mock, @payee)
    assert MockRemit.total_paid_to(mock, @payee) == "10.00"
    assert MockRemit.transaction_count(mock) == 1
  end

  test "pay/4 accumulates multiple payments", %{mock: mock, wallet: wallet} do
    Wallet.pay(wallet, @payee, "10.00")
    Wallet.pay(wallet, @payee, "5.00")
    assert MockRemit.total_paid_to(mock, @payee) == "15.00"
    assert MockRemit.transaction_count(mock) == 2
  end

  test "pay/4 rejects invalid recipient address", %{wallet: wallet} do
    {:error, err} = Wallet.pay(wallet, "not-an-address", "1.00")
    assert %Error{code: "INVALID_ADDRESS"} = err
  end

  test "pay/4 rejects zero amount", %{wallet: wallet} do
    {:error, err} = Wallet.pay(wallet, @payee, "0")
    assert %Error{code: "INVALID_AMOUNT"} = err
  end

  test "pay/4 rejects self-payment", %{wallet: wallet} do
    {:error, err} = Wallet.pay(wallet, @payer, "1.00")
    assert %Error{code: "SELF_PAYMENT"} = err
  end

  test "pay/4 rejects payment exceeding balance", %{wallet: wallet} do
    {:error, err} = Wallet.pay(wallet, @payee, "9999.00")
    assert %Error{code: "INSUFFICIENT_BALANCE"} = err
  end

  # ─── History ──────────────────────────────────────────────────────────────

  test "history/2 returns paginated transaction list", %{wallet: wallet} do
    Wallet.pay(wallet, @payee, "1.00")
    Wallet.pay(wallet, @other, "2.00")

    {:ok, list} = Wallet.history(wallet)
    assert %TransactionList{} = list
    assert list.total == 2
  end

  # ─── Reputation ───────────────────────────────────────────────────────────

  test "reputation/2 returns reputation for an address", %{wallet: wallet} do
    {:ok, rep} = Wallet.reputation(wallet, @payee)
    assert %Reputation{} = rep
    assert rep.address == @payee
    assert rep.score >= 0 and rep.score <= 100
  end

  test "reputation/2 defaults to wallet address", %{wallet: wallet} do
    {:ok, rep} = Wallet.reputation(wallet)
    assert rep.address == @payer
  end

  # ─── Escrow ───────────────────────────────────────────────────────────────

  test "create_escrow/4 creates an escrow", %{wallet: wallet} do
    {:ok, esc} = Wallet.create_escrow(wallet, @payee, "50.00",
      milestones: ["design", "code", "deploy"])

    assert %Escrow{} = esc
    assert esc.from == @payer
    assert esc.to == @payee
    assert esc.amount_usdc == "50.00"
    assert esc.status == "pending"
    assert length(esc.milestones) == 3
  end

  test "pay_milestone/3 releases a milestone", %{wallet: wallet} do
    {:ok, esc} = Wallet.create_escrow(wallet, @payee, "30.00",
      milestones: ["step_1", "step_2"])

    {:ok, updated} = Wallet.pay_milestone(wallet, esc.escrow_id, "step_1")
    assert updated.status == "partial"
    released = Enum.find(updated.milestones, fn m -> m["id"] == "step_1" end)
    assert released["status"] == "released"
  end

  test "pay_milestone/3 marks escrow complete when all milestones released", %{wallet: wallet} do
    {:ok, esc} = Wallet.create_escrow(wallet, @payee, "10.00",
      milestones: ["only"])

    {:ok, done} = Wallet.pay_milestone(wallet, esc.escrow_id, "only")
    assert done.status == "complete"
  end

  test "cancel_escrow/2 cancels a pending escrow", %{wallet: wallet} do
    {:ok, esc} = Wallet.create_escrow(wallet, @payee, "20.00")
    {:ok, cancelled} = Wallet.cancel_escrow(wallet, esc.escrow_id)
    assert cancelled.status == "cancelled"
  end

  # ─── Spending analytics ───────────────────────────────────────────────────

  test "spending/2 returns spending summary", %{wallet: wallet} do
    Wallet.pay(wallet, @payee, "5.00")
    Wallet.pay(wallet, @other, "3.00")

    {:ok, summary} = Wallet.spending(wallet)
    assert %SpendingSummary{} = summary
    assert summary.address == @payer
    assert summary.transaction_count == 2
  end

  # ─── Reset ────────────────────────────────────────────────────────────────

  test "MockRemit.reset/1 clears all state", %{mock: mock, wallet: wallet} do
    Wallet.pay(wallet, @payee, "1.00")
    assert MockRemit.transaction_count(mock) == 1

    MockRemit.reset(mock)
    assert MockRemit.transaction_count(mock) == 0
    assert not MockRemit.was_paid?(mock, @payee)
  end

  # ─── Keccak256 known-answer tests ─────────────────────────────────────────

  test "Keccak.hex/1 empty string" do
    # keccak256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    assert RemitMd.Keccak.hex("") ==
             "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  end

  test "Keccak.hex/1 known string" do
    # keccak256("abc") = 4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45
    assert RemitMd.Keccak.hex("abc") ==
             "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
  end

  test "Keccak.hex/1 differs from SHA3-256" do
    # SHA3-256("abc") = 3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532
    # Keccak-256("abc") is different — confirms we implement the Ethereum variant
    sha3 = :crypto.hash(:sha3_256, "abc") |> Base.encode16(case: :lower)
    keccak = RemitMd.Keccak.hex("abc")
    assert sha3 != keccak
  end
end
