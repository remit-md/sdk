package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** Result of charging a tab (off-chain, provider-signed). */
@JsonIgnoreProperties(ignoreUnknown = true)
public class TabCharge {

    @JsonProperty("id")
    public String id;

    @JsonProperty("tab_id")
    public String tabId;

    @JsonProperty("amount")
    public BigDecimal amount;

    @JsonProperty("cumulative")
    public BigDecimal cumulative;

    @JsonProperty("call_count")
    public int callCount;

    @JsonProperty("created_at")
    public Instant createdAt;
}
