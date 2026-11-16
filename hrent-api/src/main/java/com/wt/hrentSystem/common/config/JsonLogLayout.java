package com.wt.hrentSystem.common.config;

import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.classic.spi.IThrowableProxy;
import ch.qos.logback.classic.spi.ThrowableProxyUtil;
import ch.qos.logback.core.LayoutBase;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 单行 JSON 日志布局，避免引入额外日志编码器依赖。
 *
 * 输出字段：timestamp / level / logger / thread / message / traceId / mdc / exception。
 * 每条日志必须以换行结尾，供 Filebeat / Loki 按行采集。
 */
public class JsonLogLayout extends LayoutBase<ILoggingEvent> {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    @Override
    public String doLayout(ILoggingEvent event) {
        Map<String, Object> json = new LinkedHashMap<>();
        json.put("timestamp", Instant.ofEpochMilli(event.getTimeStamp()).toString());
        json.put("level", event.getLevel().toString());
        json.put("logger", event.getLoggerName());
        json.put("thread", event.getThreadName());
        json.put("message", event.getFormattedMessage());

        Map<String, String> mdc = event.getMDCPropertyMap();
        if (mdc != null && !mdc.isEmpty()) {
            String traceId = mdc.get("traceId");
            if (traceId != null) {
                json.put("traceId", traceId);
            }
            json.put("mdc", mdc);
        }

        IThrowableProxy throwable = event.getThrowableProxy();
        if (throwable != null) {
            json.put("exception", ThrowableProxyUtil.asString(throwable));
        }

        try {
            return MAPPER.writeValueAsString(json) + System.lineSeparator();
        } catch (Exception e) {
            // 日志序列化失败不能反过来影响业务；输出可被采集的最小 JSON。
            return "{\"level\":\"ERROR\",\"logger\":\"JsonLogLayout\","
                    + "\"message\":\"log serialization failed\"}" + System.lineSeparator();
        }
    }
}
