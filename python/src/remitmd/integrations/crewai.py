"""CrewAI integration — remit.md payment tools as CrewAI BaseTool subclasses.

Usage:
    from crewai import Agent, Task, Crew
    from remitmd.integrations.crewai import (
        RemitPayDirectTool, RemitOpenTabTool, RemitCheckBalanceTool
    )
    from remitmd import Wallet

    wallet = Wallet.from_env()
    agent = Agent(
        role="Payment Agent",
        tools=[RemitPayDirectTool(wallet), RemitCheckBalanceTool(wallet)],
    )

Requires: pip install remitmd[crewai]
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Any

try:
    from crewai.tools import BaseTool
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "CrewAI integration requires crewai. "
        "Install with: pip install remitmd[crewai]"
    ) from exc

if TYPE_CHECKING:
    pass


class RemitPayDirectTool(BaseTool):
    name: str = "Remit Pay Direct"
    description: str = (
        "Send a direct USDC payment to a wallet address. "
        "Input: JSON with fields 'to' (address), 'amount' (float USD), 'memo' (optional str)."
    )
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, amount: float, memo: str = "") -> str:
        result = asyncio.run(self.wallet.pay_direct(to, amount, memo))
        return f"Payment of ${amount:.2f} sent to {to}. tx_hash={result.tx_hash}"


class RemitOpenTabTool(BaseTool):
    name: str = "Remit Open Tab"
    description: str = (
        "Open a metered payment tab for pay-per-use billing. "
        "Input: JSON with 'to' (address), 'limit' (float), 'per_unit' (float)."
    )
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, limit: float, per_unit: float, expires: int = 86400) -> str:
        tab = asyncio.run(self.wallet.open_tab(to, limit, per_unit, expires))
        return f"Tab {tab.id} opened. Limit: ${limit:.2f}, per_unit: ${per_unit:.4f}"


class RemitCloseTabTool(BaseTool):
    name: str = "Remit Close Tab"
    description: str = "Close a metered payment tab. Input: JSON with 'tab_id' (str)."
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, tab_id: str) -> str:
        asyncio.run(self.wallet.close_tab(tab_id))
        return f"Tab {tab_id} closed and settled."


class RemitCheckBalanceTool(BaseTool):
    name: str = "Remit Check Balance"
    description: str = "Check your current USDC wallet balance. No input required."
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self) -> str:
        bal = asyncio.run(self.wallet.balance())
        return f"Current USDC balance: ${bal:.2f}"


class RemitCreateEscrowTool(BaseTool):
    name: str = "Remit Create Escrow"
    description: str = (
        "Lock funds in escrow for a task. "
        "Input: JSON with 'to', 'amount', 'task' (description), 'timeout' (seconds)."
    )
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, amount: float, task: str, timeout: int = 86400) -> str:
        from remitmd.models.invoice import Invoice
        invoice = Invoice(to=to, amount=amount, memo=task, timeout=timeout)
        result = asyncio.run(self.wallet.pay(invoice))
        return f"Escrow created. invoice_id={result.invoice_id}"


class RemitReleaseEscrowTool(BaseTool):
    name: str = "Remit Release Escrow"
    description: str = "Release escrow funds to payee. Input: JSON with 'invoice_id' (str)."
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, invoice_id: str) -> str:
        asyncio.run(self.wallet.release_escrow(invoice_id))
        return f"Escrow {invoice_id} released to payee."
