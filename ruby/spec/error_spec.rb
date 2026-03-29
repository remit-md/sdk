# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Remitmd Error classes" do
  describe "RemitError" do
    it "has code, message, and context" do
      err = Remitmd::RemitError.new("TEST_CODE", "test message")
      expect(err.code).to eq("TEST_CODE")
      expect(err.message).to include("TEST_CODE")
      expect(err.message).to include("test message")
    end

    it "is a subclass of StandardError" do
      err = Remitmd::RemitError.new("TEST", "msg")
      expect(err).to be_a(StandardError)
    end
  end

  describe "Error codes" do
    it "INVALID_ADDRESS is raised for bad addresses" do
      mock = Remitmd::MockRemit.new
      wallet = mock.wallet
      expect { wallet.pay("not-an-address", 1.0) }.to raise_error(Remitmd::RemitError) do |err|
        expect(err.code).to eq("INVALID_ADDRESS")
      end
    end

    it "INSUFFICIENT_BALANCE is raised when balance too low" do
      mock = Remitmd::MockRemit.new(balance: 0.5)
      wallet = mock.wallet
      expect { wallet.pay("0x0000000000000000000000000000000000000001", 1.0) }.to raise_error(Remitmd::RemitError) do |err|
        expect(err.code).to eq("INSUFFICIENT_BALANCE")
      end
    end

    it "INVALID_AMOUNT is raised for tiny amounts" do
      mock = Remitmd::MockRemit.new
      wallet = mock.wallet
      expect { wallet.pay("0x0000000000000000000000000000000000000001", 0.0000001) }.to raise_error(Remitmd::RemitError) do |err|
        expect(err.code).to eq("INVALID_AMOUNT")
      end
    end
  end
end
