package com.example.r42;

import org.springframework.stereotype.Component;
import javax.annotation.PostConstruct;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

@Component
public class AvailabilityZoneProvider {

    private String availabilityZone;

    @PostConstruct
    public void init() {
        try {
            HttpClient client = HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(1))
                    .build();

            // IMDSv2: get token first
            HttpRequest tokenRequest = HttpRequest.newBuilder()
                    .uri(URI.create("http://169.254.169.254/latest/api/token"))
                    .header("X-aws-ec2-metadata-token-ttl-seconds", "21600")
                    .PUT(HttpRequest.BodyPublishers.noBody())
                    .timeout(Duration.ofSeconds(1))
                    .build();
            String token = client.send(tokenRequest, HttpResponse.BodyHandlers.ofString()).body();

            // Get AZ with token
            HttpRequest azRequest = HttpRequest.newBuilder()
                    .uri(URI.create("http://169.254.169.254/latest/meta-data/placement/availability-zone"))
                    .header("X-aws-ec2-metadata-token", token)
                    .timeout(Duration.ofSeconds(1))
                    .build();
            this.availabilityZone = client.send(azRequest, HttpResponse.BodyHandlers.ofString()).body();
        } catch (Exception e) {
            this.availabilityZone = "local";
        }
    }

    public String getAvailabilityZone() {
        return availabilityZone;
    }
}
