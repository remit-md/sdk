"""LangChain integration — RemitToolkit providing payment tools as BaseTool instances.

Usage:
    from langchain_openai import ChatOpenAI
    from langchain.agents import AgentExecutor, create_tool_calling_agent
    from remitmd.integrations.langchain import RemitToolkit
    from remitmd import Wallet

    wallet = Wallet.from_env()
    tools = RemitToolkit(wallet).get_tools()
    agent = create_tool_calling_agent(ChatOpenAI(), tools, prompt)
    executor = AgentExecutor(agent=agent, tools=tools)

Requires: pip install remitmd[langchain]
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Any

try:
    from langchain_core.tools import BaseTool, BaseToolkit
    from pydantic import BaseModel, Field
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "LangChain integration requires langchain-core. "
        "Install with: pip install remitmd[langchain]"
    ) from exc

if TYPE_CHECKING:
    pass


class RemitToolkit(BaseToolkit):
    """LangChain toolkit providing remit.md payment tools."""

    wallet: Any  # Wallet — can't annotate directly to avoid circular import

    class Config:
        arbitrary_types_allowed = True

    def get_tools(self) -> list[BaseTool]:
        return [
            RemitPayDirectTool(wallet=self.wallet),
            RemitCreateEscrowTool(wallet=self.wallet),
            RemitReleaseEscrowTool(wallet=self.wallet),
            RemitOpenTabTool(wallet=self.wallet),
            RemitCloseTabTool(wallet=self.wallet),
            RemitOpenStreamTool(wallet=self.wallet),
            RemitCheckBalanceTool(wallet=self.wallet),
            RemitGetReputationTool(wallet=self.wallet),
            RemitFileDisputeTool(wallet=self.wallet),
        ]


# ─── Tool schemas ─────────────────────────────────────────────────────────────

class _PayDirectInput(BaseModel):
    to: str = Field(description="Recipient wallet address (0x...)")
    amount: float = Field(description="Amount in USD (e.g. 5.00)")
    memo: str = Field(default="", description="Optional payment memo")


class _CreateEscrowInput(BaseModel):
    to: str = Field(description="Payee wallet address")
    amount: float = Field(description="Escrow amount in USD")
    task: str = Field(description="Task description")
    timeout: int = Field(default=86400, description="Timeout in seconds")


class _InvoiceIdInput(BaseModel):
    invoice_id: str = Field(description="Invoice or escrow ID")


class _OpenTabInput(BaseModel):
    to: str = Field(description="Payee wallet address")
    limit: float = Field(description="Maximum spend limit in USD")
    per_unit: float = Field(description="Price per unit in USD")
    expires: int = Field(default=86400, description="Expiry in seconds")


class _TabIdInput(BaseModel):
    tab_id: str = Field(description="Tab ID to close")


class _OpenStreamInput(BaseModel):
    to: str = Field(description="Payee wallet address")
    rate: float = Field(description="Rate per second in USD")
    max_duration: int = Field(default=3600, description="Maximum duration in seconds")


class _FileDisputeInput(BaseModel):
    invoice_id: str
    reason: str
    details: str
    evidence_uri: str = Field(description="URL to supporting evidence")


# ─── Tool implementations ─────────────────────────────────────────────────────

class RemitPayDirectTool(BaseTool):
    name: str = "remit_pay_direct"
    description: str = "Send a direct USDC payment to another agent or address."
    args_schema: type[BaseModel] = _PayDirectInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, amount: float, memo: str = "") -> str:
        result = asyncio.run(self.wallet.pay_direct(to, amount, memo))
        return f"Payment sent. tx_hash={result.tx_hash}"

    async def _arun(self, to: str, amount: float, memo: str = "") -> str:
        result = await self.wallet.pay_direct(to, amount, memo)
        return f"Payment sent. tx_hash={result.tx_hash}"


class RemitCreateEscrowTool(BaseTool):
    name: str = "remit_create_escrow"
    description: str = (
        "Fund an escrow for a task. Funds are locked until you call remit_release_escrow."
    )
    args_schema: type[BaseModel] = _CreateEscrowInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, amount: float, task: str, timeout: int = 86400) -> str:
        from remitmd.models.invoice import Invoice
        invoice = Invoice(to=to, amount=amount, memo=task, timeout=timeout)
        result = asyncio.run(self.wallet.pay(invoice))
        return f"Escrow created. invoice_id={result.invoice_id}"

    async def _arun(self, to: str, amount: float, task: str, timeout: int = 86400) -> str:
        from remitmd.models.invoice import Invoice
        invoice = Invoice(to=to, amount=amount, memo=task, timeout=timeout)
        result = await self.wallet.pay(invoice)
        return f"Escrow created. invoice_id={result.invoice_id}"


class RemitReleaseEscrowTool(BaseTool):
    name: str = "remit_release_escrow"
    description: str = "Release escrowed funds to the payee after task completion."
    args_schema: type[BaseModel] = _InvoiceIdInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, invoice_id: str) -> str:
        asyncio.run(self.wallet.release_escrow(invoice_id))
        return f"Escrow {invoice_id} released."

    async def _arun(self, invoice_id: str) -> str:
        await self.wallet.release_escrow(invoice_id)
        return f"Escrow {invoice_id} released."


class RemitOpenTabTool(BaseTool):
    name: str = "remit_open_tab"
    description: str = "Open a metered payment tab for a service (pay-per-use)."
    args_schema: type[BaseModel] = _OpenTabInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, limit: float, per_unit: float, expires: int = 86400) -> str:
        tab = asyncio.run(self.wallet.open_tab(to, limit, per_unit, expires))
        return f"Tab opened. tab_id={tab.id}, limit={tab.limit}"

    async def _arun(self, to: str, limit: float, per_unit: float, expires: int = 86400) -> str:
        tab = await self.wallet.open_tab(to, limit, per_unit, expires)
        return f"Tab opened. tab_id={tab.id}, limit={tab.limit}"


class RemitCloseTabTool(BaseTool):
    name: str = "remit_close_tab"
    description: str = "Close a metered payment tab and settle the balance."
    args_schema: type[BaseModel] = _TabIdInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, tab_id: str) -> str:
        asyncio.run(self.wallet.close_tab(tab_id))
        return f"Tab {tab_id} closed."

    async def _arun(self, tab_id: str) -> str:
        await self.wallet.close_tab(tab_id)
        return f"Tab {tab_id} closed."


class RemitOpenStreamTool(BaseTool):
    name: str = "remit_open_stream"
    description: str = "Start a streaming payment (continuous per-second USDC flow)."
    args_schema: type[BaseModel] = _OpenStreamInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, to: str, rate: float, max_duration: int = 3600) -> str:
        stream = asyncio.run(self.wallet.open_stream(to, rate, max_duration))
        return f"Stream opened. stream_id={stream.id}, rate={stream.rate_per_second}/s"

    async def _arun(self, to: str, rate: float, max_duration: int = 3600) -> str:
        stream = await self.wallet.open_stream(to, rate, max_duration)
        return f"Stream opened. stream_id={stream.id}, rate={stream.rate_per_second}/s"


class RemitCheckBalanceTool(BaseTool):
    name: str = "remit_check_balance"
    description: str = "Check your current USDC balance."
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self) -> str:
        bal = asyncio.run(self.wallet.balance())
        return f"Balance: ${bal:.2f} USDC"

    async def _arun(self) -> str:
        bal = await self.wallet.balance()
        return f"Balance: ${bal:.2f} USDC"


class RemitGetReputationTool(BaseTool):
    name: str = "remit_get_reputation"
    description: str = "Get the reputation score for a wallet address."
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(self, wallet: str) -> str:
        rep = asyncio.run(self.wallet.get_reputation(wallet))
        return (
            f"Reputation for {wallet[:10]}...: score={rep.score:.2f}, "
            f"dispute_rate={rep.dispute_rate:.1%}"
        )

    async def _arun(self, wallet: str) -> str:
        rep = await self.wallet.get_reputation(wallet)
        return (
            f"Reputation for {wallet[:10]}...: score={rep.score:.2f}, "
            f"dispute_rate={rep.dispute_rate:.1%}"
        )


class RemitFileDisputeTool(BaseTool):
    name: str = "remit_file_dispute"
    description: str = "File a dispute for an escrow payment."
    args_schema: type[BaseModel] = _FileDisputeInput
    wallet: Any

    class Config:
        arbitrary_types_allowed = True

    def _run(
        self, invoice_id: str, reason: str, details: str, evidence_uri: str
    ) -> str:
        dispute = asyncio.run(
            self.wallet.file_dispute(invoice_id, reason, details, evidence_uri)
        )
        return f"Dispute filed. dispute_id={dispute.id}"

    async def _arun(
        self, invoice_id: str, reason: str, details: str, evidence_uri: str
    ) -> str:
        dispute = await self.wallet.file_dispute(invoice_id, reason, details, evidence_uri)
        return f"Dispute filed. dispute_id={dispute.id}"
