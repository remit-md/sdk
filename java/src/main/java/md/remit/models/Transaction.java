package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** A completed on-chain USDC transfer. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Transaction {

    @JsonProperty("id")
    public String id;

    @JsonProperty("tx_hash")
    public String txHash;

    @JsonProperty("from")
    public String from;

    @JsonProperty("to")
    public String to;

    @JsonProperty("amount")
    public BigDecimal amount;

    @JsonProperty("fee")
    public BigDecimal fee;

    @JsonProperty("memo")
    public String memo;

    @JsonProperty("chain_id")
    public long chainId;

    @JsonProperty("created_at")
    public Instant createdAt;
}
