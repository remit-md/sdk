# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Remitmd MockRemit" do
  RECIPIENT = "0x0000000000000000000000000000000000000001"
  PAYEE     = "0x0000000000000000000000000000000000000002"

  let(:mock)   { Remitmd::MockRemit.new }
  let(:wallet) { mock.wallet }

  after { mock.reset }

  # ─── Balance & basic payment ──────────────────────────────────────────────

  describe "#balance" do
    it "returns the starting balance of 10000 USDC" do
      bal = wallet.balance
      expect(bal).to be_a(Remitmd::Balance)
      expect(bal.usdc).to eq(BigDecimal("10000"))
    end
  end

  describe "#pay" do
    it "deducts the amount from the mock balance" do
      wallet.pay(RECIPIENT, 5.00)
      expect(mock.balance).to eq(BigDecimal("9995"))
    end

    it "records the transaction" do
      tx = wallet.pay(RECIPIENT, 1.50)
      expect(tx).to be_a(Remitmd::Transaction)
      expect(tx.to).to eq(RECIPIENT)
      expect(tx.amount).to eq(BigDecimal("1.5"))
    end

    it "sets was_paid? to true after payment" do
      wallet.pay(RECIPIENT, 2.00)
      expect(mock.was_paid?(RECIPIENT, 2.00)).to be true
    end

    it "rejects an invalid address" do
      expect { wallet.pay("not-an-address", 1.00) }
        .to raise_error(Remitmd::RemitError) do |e|
          expect(e.code).to eq(Remitmd::RemitError::INVALID_ADDRESS)
          expect(e.message).to include("0x-prefixed")
        end
    end

    it "rejects an amount below minimum" do
      expect { wallet.pay(RECIPIENT, 0.0000001) }
        .to raise_error(Remitmd::RemitError) do |e|
          expect(e.code).to eq(Remitmd::RemitError::INVALID_AMOUNT)
          expect(e.message).to include("minimum")
        end
    end

    it "raises INSUFFICIENT_FUNDS when balance is too low" do
      mock.set_balance(0.50)
      expect { wallet.pay(RECIPIENT, 1.00) }
        .to raise_error(Remitmd::RemitError) do |e|
          expect(e.code).to eq(Remitmd::RemitError::INSUFFICIENT_FUNDS)
        end
    end
  end

  describe "#total_paid_to" do
    it "sums multiple payments to the same recipient" do
      wallet.pay(RECIPIENT, 1.00)
      wallet.pay(RECIPIENT, 2.50)
      wallet.pay(PAYEE,     10.00)

      expect(mock.total_paid_to(RECIPIENT)).to eq(BigDecimal("3.5"))
      expect(mock.total_paid_to(PAYEE)).to eq(BigDecimal("10"))
      expect(mock.transaction_count).to eq(3)
    end
  end

  # ─── Escrow ───────────────────────────────────────────────────────────────

  describe "escrow lifecycle" do
    it "creates an escrow and deducts the amount" do
      escrow = wallet.create_escrow(PAYEE, 100.00)
      expect(escrow).to be_a(Remitmd::Escrow)
      expect(escrow.status).to eq(Remitmd::EscrowStatus::FUNDED)
      expect(mock.balance).to eq(BigDecimal("9900"))
    end

    it "releases an escrow and records the settlement transaction" do
      escrow = wallet.create_escrow(PAYEE, 50.00)
      tx = wallet.release_escrow(escrow.id)
      expect(tx.to).to eq(PAYEE)
      expect(tx.amount).to eq(BigDecimal("50"))
    end

    it "cancels an escrow and refunds the payer" do
      escrow = wallet.create_escrow(PAYEE, 50.00)
      expect(mock.balance).to eq(BigDecimal("9950"))

      wallet.cancel_escrow(escrow.id)
      expect(mock.balance).to eq(BigDecimal("10000"))
    end

    it "fetches escrow details" do
      escrow = wallet.create_escrow(PAYEE, 75.00)
      fetched = wallet.get_escrow(escrow.id)
      expect(fetched.id).to eq(escrow.id)
      expect(fetched.amount).to eq(BigDecimal("75"))
    end
  end

  # ─── Tabs ──────────────────────────────────────────────────────────────────

  describe "tab lifecycle" do
    it "opens a tab and charges via EIP-712" do
      tab = wallet.create_tab(PAYEE, 10.00, 0.10)
      expect(tab.status).to eq(Remitmd::TabStatus::OPEN)

      charge = wallet.charge_tab(tab.id, 0.10, 0.10, 1, "0xfakesig")
      expect(charge).to be_a(Remitmd::TabDebit)
      expect(charge.tab_id).to eq(tab.id)

      closed = wallet.close_tab(tab.id, final_amount: 0.10, provider_sig: "0xfakesig")
      expect(closed).to be_a(Remitmd::Tab)
      expect(closed.status).to eq(Remitmd::TabStatus::SETTLED)
    end
  end

  # ─── Streams ──────────────────────────────────────────────────────────────

  describe "#create_stream" do
    it "creates a stream and deducts the deposit" do
      stream = wallet.create_stream(RECIPIENT, 0.001, 100.00)
      expect(stream).to be_a(Remitmd::Stream)
      expect(stream.status).to eq(Remitmd::StreamStatus::ACTIVE)
      expect(mock.balance).to eq(BigDecimal("9900"))
    end
  end

  # ─── Bounties ─────────────────────────────────────────────────────────────

  describe "bounty lifecycle" do
    it "posts, submits, and awards a bounty" do
      deadline = Time.now.to_i + 3600
      bounty = wallet.create_bounty(5.00, "find the cheapest API route", deadline)
      expect(bounty.status).to eq(Remitmd::BountyStatus::OPEN)

      sub = wallet.submit_bounty(bounty.id, "0xdeadbeef")
      expect(sub).to be_a(Remitmd::BountySubmission)
      expect(sub.bounty_id).to eq(bounty.id)

      awarded = wallet.award_bounty(bounty.id, sub.id)
      expect(awarded).to be_a(Remitmd::Bounty)
      expect(awarded.status).to eq(Remitmd::BountyStatus::AWARDED)
    end
  end

  # ─── Deposits ─────────────────────────────────────────────────────────────

  describe "deposit lifecycle" do
    it "places a security deposit and returns it" do
      dep = wallet.place_deposit(PAYEE, 20.00)
      expect(dep).to be_a(Remitmd::Deposit)
      expect(dep.status).to eq(Remitmd::DepositStatus::LOCKED)
      expect(mock.balance).to eq(BigDecimal("9980"))

      tx = wallet.return_deposit(dep.id)
      expect(tx).to be_a(Remitmd::Transaction)
      expect(mock.balance).to eq(BigDecimal("10000"))
    end

    it "backward-compat lock_deposit still works" do
      dep = wallet.lock_deposit(PAYEE, 20.00, 86400)
      expect(dep).to be_a(Remitmd::Deposit)
      expect(dep.status).to eq(Remitmd::DepositStatus::LOCKED)
    end
  end

  # ─── Analytics ────────────────────────────────────────────────────────────

  describe "#reputation" do
    it "returns mock reputation data" do
      rep = wallet.reputation(RECIPIENT)
      expect(rep).to be_a(Remitmd::Reputation)
      expect(rep.score).to eq(750)
    end
  end

  describe "#spending_summary" do
    it "returns a spending summary" do
      wallet.pay(RECIPIENT, 1.00)
      summary = wallet.spending_summary
      expect(summary).to be_a(Remitmd::SpendingSummary)
      expect(summary.tx_count).to eq(1)
      expect(summary.total_spent).to eq(BigDecimal("1"))
    end
  end

  # ─── History ──────────────────────────────────────────────────────────────

  describe "#history" do
    it "returns all transactions" do
      wallet.pay(RECIPIENT, 1.00)
      wallet.pay(PAYEE, 2.00)
      list = wallet.history
      expect(list).to be_a(Remitmd::TransactionList)
      expect(list.items.length).to eq(2)
    end
  end

  # ─── Reset ────────────────────────────────────────────────────────────────

  describe "#reset" do
    it "clears all state including transactions and balance" do
      wallet.pay(RECIPIENT, 100.00)
      expect(mock.transaction_count).to eq(1)

      mock.reset
      expect(mock.transaction_count).to eq(0)
      expect(mock.balance).to eq(BigDecimal("10000"))
    end
  end
end
