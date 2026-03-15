package md.remit.models;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

/** A registered webhook endpoint. */
@JsonIgnoreProperties(ignoreUnknown = true)
public class Webhook {

    @JsonProperty("id")
    public String id;

    @JsonProperty("wallet")
    public String wallet;

    @JsonProperty("url")
    public String url;

    @JsonProperty("events")
    public List<String> events;

    @JsonProperty("chains")
    public List<String> chains;

    @JsonProperty("active")
    public boolean active;

    @JsonProperty("created_at")
    public String createdAt;

    @JsonProperty("updated_at")
    public String updatedAt;
}
