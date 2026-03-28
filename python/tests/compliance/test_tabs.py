"""Compliance: tab open/close lifecycle against a real server."""

from __future__ import annotations

import pytest

from .conftest import server_available


@pytest.mark.asyncio
@server_available
async def test_tab_open_returns_open_tab(wallet_pair):
    """open_tab creates a tab and returns it in open state."""
    from remitmd.models.common import TabStatus

    payer, payee, payee_addr = wallet_pair

    print(f"[COMPLIANCE] tab open: limit=20.0 per_unit=0.10 {payer.address} -> {payee_addr}")
    tab = await payer.open_tab(payee_addr, limit=20.0, per_unit=0.10)
    print(f"[COMPLIANCE] tab open: id={tab.id} status={tab.status} limit={tab.limit_amount}")

    assert tab.id is not None
    assert tab.status == TabStatus.open or tab.status == "open"
    assert tab.limit_amount == pytest.approx(20.0, abs=0.01)


@pytest.mark.asyncio
@server_available
async def test_tab_close_settles(wallet_pair):
    """Closing a tab returns a transaction and the tab is no longer open."""
    from remitmd.models.common import TabStatus

    payer, payee, payee_addr = wallet_pair

    print(f"[COMPLIANCE] tab open (for close): limit=50.0"
          f" per_unit=1.0 {payer.address} -> {payee_addr}")
    tab = await payer.open_tab(payee_addr, limit=50.0, per_unit=1.0)
    print(f"[COMPLIANCE] tab opened: id={tab.id} status={tab.status}")

    close_tx = await payer.close_tab(tab.id)
    print(f"[COMPLIANCE] tab close: id={tab.id} tx={close_tx.tx_hash}")

    assert close_tx.tx_hash is not None

    # Tab must no longer be in open state after close
    closed_tab = await payer.get_tab(tab.id)
    print(f"[COMPLIANCE] tab after close: id={closed_tab.id} status={closed_tab.status}")
    assert closed_tab.status != TabStatus.open
