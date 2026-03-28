"""Compliance: escrow lifecycle against a real server."""

from __future__ import annotations

import pytest

from .conftest import server_available


@pytest.mark.asyncio
@server_available
async def test_escrow_create_returns_funded_invoice(wallet_pair):
    """Escrow create returns a funded invoice with a valid ID."""
    from remitmd.models.common import EscrowStatus
    from remitmd.models.invoice import Invoice

    payer, payee, payee_addr = wallet_pair

    invoice = Invoice(to=payee_addr, amount=10.0, memo="compliance escrow test")
    print(f"[COMPLIANCE] escrow create: 10.0 USDC {payer.address} -> {payee_addr}")
    tx = await payer.pay(invoice)
    print(f"[COMPLIANCE] escrow create: id={tx.invoice_id} tx={tx.tx_hash}")

    assert tx.invoice_id is not None
    assert tx.tx_hash is not None

    # Retrieve escrow - must be in funded state immediately after creation
    escrow = await payer.get_escrow(tx.invoice_id)
    print(f"[COMPLIANCE] escrow get: id={escrow.invoice_id} status={escrow.status} amount={escrow.amount}")
    assert escrow.invoice_id == tx.invoice_id
    assert escrow.status == EscrowStatus.funded
    assert escrow.amount == pytest.approx(10.0, abs=0.01)


@pytest.mark.asyncio
@server_available
async def test_escrow_cancel_by_payer(wallet_pair):
    """Payer can cancel an escrow before it is claimed."""
    from remitmd.models.common import EscrowStatus
    from remitmd.models.invoice import Invoice

    payer, payee, payee_addr = wallet_pair

    invoice = Invoice(to=payee_addr, amount=10.0, memo="to be cancelled")
    print(f"[COMPLIANCE] escrow create (for cancel): 10.0 USDC {payer.address} -> {payee_addr}")
    tx = await payer.pay(invoice)
    print(f"[COMPLIANCE] escrow created: id={tx.invoice_id} tx={tx.tx_hash}")

    cancel_tx = await payer.cancel_escrow(tx.invoice_id)
    print(f"[COMPLIANCE] escrow cancel: id={tx.invoice_id} tx={cancel_tx.tx_hash}")
    assert cancel_tx.tx_hash is not None

    escrow = await payer.get_escrow(tx.invoice_id)
    print(f"[COMPLIANCE] escrow after cancel: id={escrow.invoice_id} status={escrow.status}")
    assert escrow.status == EscrowStatus.cancelled
