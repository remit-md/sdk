"""Tests for A2A / AP2 agent card discovery and A2AClient."""

from __future__ import annotations

from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from remitmd.a2a import (
    A2ACapabilities,
    A2AClient,
    A2AExtension,
    A2ASkill,
    A2ATask,
    AgentCard,
    IntentMandate,
    _parse_task,
)

# ─── Fixtures ─────────────────────────────────────────────────────────────────

CARD_DATA: dict[str, Any] = {
    "protocolVersion": "0.6",
    "name": "remit.md",
    "description": "USDC payment protocol for AI agents.",
    "url": "https://remit.md/a2a",
    "version": "0.1.0",
    "documentationUrl": "https://remit.md/docs",
    "capabilities": {
        "streaming": False,
        "pushNotifications": False,
        "stateTransitionHistory": True,
        "extensions": [
            {
                "uri": "https://ap2-protocol.org/ext/payment-processor",
                "description": "AP2 payment processor",
                "required": False,
            }
        ],
    },
    "authentication": [],
    "skills": [
        {
            "id": "direct-payment",
            "name": "Direct Payment",
            "description": "Send USDC directly.",
            "tags": ["payment", "usdc"],
        },
        {
            "id": "x402-paywall",
            "name": "x402 Paywall",
            "description": "HTTP 402 payment rail.",
            "tags": ["x402", "paywall"],
        },
    ],
    "x402": {
        "settleEndpoint": "https://remit.md/api/v0/x402/settle",
        "assets": {"eip155:8453": "0xUSDC"},
        "fees": {"standardBps": 100, "preferredBps": 50, "cliffUsd": 10000},
    },
}


# ─── AgentCard._from_dict ──────────────────────────────────────────────────────


def test_agent_card_from_dict_top_level():
    card = AgentCard._from_dict(CARD_DATA)
    assert card.name == "remit.md"
    assert card.url == "https://remit.md/a2a"
    assert card.version == "0.1.0"
    assert card.protocol_version == "0.6"
    assert card.documentation_url == "https://remit.md/docs"


def test_agent_card_from_dict_capabilities():
    card = AgentCard._from_dict(CARD_DATA)
    assert card.capabilities.streaming is False
    assert card.capabilities.state_transition_history is True
    assert len(card.capabilities.extensions) == 1
    ext = card.capabilities.extensions[0]
    assert ext.uri == "https://ap2-protocol.org/ext/payment-processor"
    assert ext.required is False


def test_agent_card_from_dict_skills():
    card = AgentCard._from_dict(CARD_DATA)
    assert len(card.skills) == 2
    ids = [s.id for s in card.skills]
    assert "direct-payment" in ids
    assert "x402-paywall" in ids


def test_agent_card_from_dict_x402():
    card = AgentCard._from_dict(CARD_DATA)
    assert card.x402["fees"]["standardBps"] == 100
    assert card.x402["fees"]["cliffUsd"] == 10000
    assert card.x402["assets"]["eip155:8453"] == "0xUSDC"


def test_agent_card_from_dict_empty_capabilities():
    card = AgentCard._from_dict({"name": "x", "url": "https://x.com/a2a", "description": "", "version": ""})
    assert card.capabilities.streaming is False
    assert card.capabilities.extensions == []
    assert card.skills == []


# ─── AgentCard.discover ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_agent_card_discover_fetches_well_known():
    mock_response = MagicMock()
    mock_response.json.return_value = CARD_DATA
    mock_response.raise_for_status = MagicMock()

    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(return_value=mock_response)

    with patch("httpx.AsyncClient", return_value=mock_client):
        card = await AgentCard.discover("https://remit.md")

    mock_client.get.assert_called_once_with(
        "https://remit.md/.well-known/agent-card.json", timeout=10.0
    )
    assert card.name == "remit.md"
    assert card.url == "https://remit.md/a2a"


@pytest.mark.asyncio
async def test_agent_card_discover_strips_trailing_slash():
    mock_response = MagicMock()
    mock_response.json.return_value = CARD_DATA
    mock_response.raise_for_status = MagicMock()

    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(return_value=mock_response)

    with patch("httpx.AsyncClient", return_value=mock_client):
        await AgentCard.discover("https://remit.md/")

    called_url = mock_client.get.call_args[0][0]
    assert not called_url.startswith("https://remit.md//")
    assert called_url == "https://remit.md/.well-known/agent-card.json"


# ─── _parse_task ──────────────────────────────────────────────────────────────


def test_parse_task_completed():
    data = {
        "result": {
            "id": "task_abc123",
            "status": {"state": "completed"},
            "artifacts": [
                {"parts": [{"kind": "data", "data": {"txHash": "0xdeadbeef"}}]}
            ],
        }
    }
    task = _parse_task(data)
    assert task.id == "task_abc123"
    assert task.state == "completed"
    assert task.tx_hash == "0xdeadbeef"
    assert task.succeeded is True


def test_parse_task_failed():
    data = {
        "result": {
            "id": "task_xyz",
            "status": {"state": "failed", "message": {"text": "insufficient balance"}},
            "artifacts": [],
        }
    }
    task = _parse_task(data)
    assert task.state == "failed"
    assert task.error == "insufficient balance"
    assert task.succeeded is False


def test_parse_task_json_rpc_error_raises():
    data = {"error": {"code": -32001, "message": "Invalid mandate"}}
    with pytest.raises(ValueError, match="A2A error: Invalid mandate"):
        _parse_task(data)


def test_parse_task_no_artifacts():
    data = {"result": {"id": "task_1", "status": {"state": "canceled"}, "artifacts": []}}
    task = _parse_task(data)
    assert task.tx_hash is None
    assert task.state == "canceled"


# ─── A2ATask helpers ──────────────────────────────────────────────────────────


def test_a2a_task_tx_hash_nested():
    task = A2ATask(
        id="t1",
        state="completed",
        artifacts=[
            {"parts": [{"kind": "data", "data": {"txHash": "0x1234"}}]},
        ],
    )
    assert task.tx_hash == "0x1234"


def test_a2a_task_tx_hash_missing():
    task = A2ATask(id="t1", state="completed", artifacts=[])
    assert task.tx_hash is None


# ─── A2AClient URL parsing ────────────────────────────────────────────────────


def test_a2a_client_url_parsing():
    """A2AClient should split endpoint into base_url + path."""
    mock_signer = MagicMock()
    mock_signer.get_address.return_value = "0xABCD"

    with patch("remitmd._http.AuthenticatedClient") as mock_auth_cls:
        client = A2AClient(
            endpoint="https://remit.md/a2a",
            signer=mock_signer,
            chain_id=8453,
        )
        mock_auth_cls.assert_called_once()
        call_kwargs = mock_auth_cls.call_args[1]
        assert call_kwargs["base_url"] == "https://remit.md"
        assert client._path == "/a2a"


def test_a2a_client_from_wallet():
    mock_wallet = MagicMock()
    mock_wallet._signer = MagicMock()
    mock_wallet._http._chain_id = 8453
    mock_wallet._http._verifying_contract = "0xROUTER"

    card = AgentCard._from_dict(CARD_DATA)

    with patch("remitmd._http.AuthenticatedClient"):
        client = A2AClient.from_wallet(card, mock_wallet)
        assert client._path == "/a2a"
