package com.example.r42;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.context.junit4.SpringRunner;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@RunWith(SpringRunner.class)
@SpringBootTest
@AutoConfigureMockMvc
public class SuchControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private AvailabilityZoneProvider azProvider;

    @Test
    public void helloReturnsNameWithAz() throws Exception {
        when(azProvider.getAvailabilityZone()).thenReturn("us-east-1a");
        mockMvc.perform(get("/hello"))
                .andExpect(status().isOk())
                .andExpect(content().string("hello Daniel from us-east-1a"));
    }

    @Test
    public void helloReturnsLocalWhenMetadataUnavailable() throws Exception {
        when(azProvider.getAvailabilityZone()).thenReturn("local");
        mockMvc.perform(get("/hello"))
                .andExpect(status().isOk())
                .andExpect(content().string("hello Daniel from local"));
    }
}
