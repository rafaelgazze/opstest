package com.example.r42;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class SuchController {

    @Value("${suchname}") private String suchName;
    @Autowired private AvailabilityZoneProvider azProvider;

    @RequestMapping("/hello")
    public String suchHello() {
        return "hello " + suchName + " from " + azProvider.getAvailabilityZone();
    }
}
