package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/** One-time operator link for funding or withdrawing a wallet. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class LinkResponse {

    @JsonProperty("url")
    public String url;

    @JsonProperty("token")
    public String token;

    @JsonProperty("expires_at")
    public String expiresAt;

    @JsonProperty("wallet_address")
    public String walletAddress;
}
