package md.remit.models;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** On-chain reputation score for an agent address. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Reputation {

    @JsonProperty("wallet")
    @JsonAlias("address")
    public String address;

    @JsonProperty("score")
    public int score; // 0-1000

    @JsonProperty("total_paid")
    public BigDecimal totalPaid;

    @JsonProperty("total_received")
    public BigDecimal totalReceived;

    @JsonProperty("transaction_count")
    public int transactionCount;

    @JsonProperty("member_since")
    public Instant memberSince;
}
