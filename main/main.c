/*
 * SPDX-FileCopyrightText: 2021-2022 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: CC0-1.0
 */

#include "ST7789.h"
#include "RGB.h"
#include "sysmon.h"

void app_main(void)
{
    RGB_Init();         // WS2812 on GPIO38 (driven by the sysmon, by CPU load)
    LCD_Init();         // ST7789 bring-up (172x320, column offset handled here)
    BK_Light(75);
    LVGL_Init();        // LVGL display driver

    Sysmon_Start();     // USB link + UI + stats/disconnect handling

    while (1) {
        // The task running lv_timer_handler should have lower priority than
        // the one running lv_tick_inc.
        vTaskDelay(pdMS_TO_TICKS(10));
        lv_timer_handler();
    }
}
