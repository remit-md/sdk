package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.math.BigDecimal;
import java.time.Instant;

/** USDC balance of the wallet. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Balance {

    @JsonProperty("usdc")
    public BigDecimal usdc;

    @JsonProperty("address")
    public String address;

    @JsonProperty("chain_id")
    public long chainId;

    @JsonProperty("updated_at")
    public Instant updatedAt;
}
