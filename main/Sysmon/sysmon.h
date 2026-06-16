#pragma once

// USB System Monitor (see CLAUDE.md).
//
// Reuses the Waveshare ESP-IDF + LVGL display scaffold. Call Sysmon_Start()
// once, AFTER LCD_Init() / LVGL_Init() / RGB_Init() have run, from app_main().
// It installs the native USB-Serial/JTAG link, builds the LVGL UI, and creates
// an LVGL timer that reads the host stats, updates the widgets, drives the RGB
// LED, and handles host-disconnect ("waiting for host") recovery.
//
// Everything it touches lives in the LVGL timer context, i.e. the same context
// as lv_timer_handler() in app_main(), so no LVGL locking is required.

void Sysmon_Start(void);
