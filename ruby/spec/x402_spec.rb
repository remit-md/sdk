# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Remitmd X402" do
  describe "AllowanceExceededError" do
    it "includes amounts in message" do
      err = Remitmd::AllowanceExceededError.new(1.5, 0.1)
      expect(err.message).to include("1.5")
      expect(err.message).to include("0.1")
    end

    it "exposes amount and limit" do
      err = Remitmd::AllowanceExceededError.new(2.0, 0.5)
      expect(err.amount_usdc).to eq(2.0)
      expect(err.limit_usdc).to eq(0.5)
    end
  end

  describe "X402Paywall" do
    it "can be created" do
      paywall = Remitmd::X402Paywall.new(amount: 0.01, payee: "0x0000000000000000000000000000000000000001")
      expect(paywall).not_to be_nil
    end
  end
end
