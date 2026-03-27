"""remitmd - Python SDK for the remit.md universal AI payment protocol."""

from remitmd.a2a import A2AClient, A2ATask, AgentCard, IntentMandate
from remitmd.client import ContractAddresses, RemitClient
from remitmd.http_signer import HttpSigner
from remitmd.models.bounty import Bounty, BountySubmission
from remitmd.models.common import (
    BountyStatus,
    ChainId,
    DepositStatus,
    EscrowStatus,
    Event,
    InvoiceStatus,
    Reputation,
    StreamStatus,
    TabStatus,
    Transaction,
    WalletStatus,
    Webhook,
)
from remitmd.models.deposit import Deposit
from remitmd.models.escrow import Escrow
from remitmd.models.invoice import Invoice, Milestone, Split
from remitmd.models.stream import Stream
from remitmd.models.tab import Tab, TabCharge
from remitmd.provider import X402Paywall
from remitmd.signer import PrivateKeySigner, Signer
from remitmd.wallet import PermitSignature, Wallet

try:
    from remitmd.ows_signer import OwsSigner
except ImportError:
    OwsSigner = None  # type: ignore[assignment,misc]
from remitmd.x402 import AllowanceExceededError, X402Client

__all__ = [
    # A2A / AP2
    "AgentCard",
    "A2AClient",
    "A2ATask",
    "IntentMandate",
    # Core
    "ContractAddresses",
    "RemitClient",
    "Wallet",
    "PermitSignature",
    "Signer",
    "PrivateKeySigner",
    "HttpSigner",
    "OwsSigner",
    "X402Client",
    "AllowanceExceededError",
    "X402Paywall",
    # enums
    "ChainId",
    "InvoiceStatus",
    "EscrowStatus",
    "TabStatus",
    "StreamStatus",
    "BountyStatus",
    "DepositStatus",
    # models
    "Transaction",
    "WalletStatus",
    "Reputation",
    "Event",
    "Webhook",
    "Invoice",
    "Milestone",
    "Split",
    "Escrow",
    "Tab",
    "TabCharge",
    "Stream",
    "Bounty",
    "BountySubmission",
    "Deposit",
]
