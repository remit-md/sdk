package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** A security deposit locked on-chain. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Deposit {

    @JsonProperty("id")
    public String id;

    @JsonProperty("depositor")
    public String depositor;

    @JsonProperty("beneficiary")
    public String beneficiary;

    @JsonProperty("amount")
    public BigDecimal amount;

    @JsonProperty("status")
    public String status; // "locked" | "returned" | "forfeited"

    @JsonProperty("expires_at")
    public Instant expiresAt;

    @JsonProperty("created_at")
    public Instant createdAt;
}
