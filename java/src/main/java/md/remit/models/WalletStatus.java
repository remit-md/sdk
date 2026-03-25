package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/** Full wallet status from /api/v1/status/{address}. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class WalletStatus {

    @JsonProperty("wallet")
    public String wallet;

    @JsonProperty("balance")
    public String balance;

    @JsonProperty("monthly_volume")
    public String monthlyVolume;

    @JsonProperty("tier")
    public String tier;

    @JsonProperty("fee_rate_bps")
    public int feeRateBps;

    @JsonProperty("active_escrows")
    public int activeEscrows;

    @JsonProperty("active_tabs")
    public int activeTabs;

    @JsonProperty("active_streams")
    public int activeStreams;

    @JsonProperty("permit_nonce")
    public long permitNonce;
}
