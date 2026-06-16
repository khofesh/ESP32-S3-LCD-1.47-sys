#include "sysmon.h"

#include "lvgl.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "driver/usb_serial_jtag.h"

#include "RGB.h"      // Set_RGB()
#include "ST7789.h"   // EXAMPLE_LCD_H_RES / EXAMPLE_LCD_V_RES

static const char *TAG = "SYSMON";

#define LINK_TIMEOUT_MS 3000     // no valid line for this long -> "waiting for host"
#define POLL_PERIOD_MS  50
#define SYSMON_LINE_MAX        96

// --- parsed stats (written and read only from the LVGL timer context) ---
static int     s_cpu, s_mem, s_tmp, s_rx, s_tx;
static int64_t s_last_rx_ms;
static bool    s_link_up = true; // forced false by Sysmon_Start() so the first
                                 // transition actually paints the waiting state

// --- LVGL widgets ---
static lv_obj_t *cpu_arc, *mem_arc;     // gauges
static lv_obj_t *cpu_val, *mem_val;     // centered % labels
static lv_obj_t *tmp_lbl, *net_lbl;     // temperature + throughput
static lv_obj_t *status_lbl;            // "waiting for host" overlay

// --- incoming line assembly ---
static char s_line[SYSMON_LINE_MAX];
static int  s_idx;

static inline int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static inline int clamp_pct(int v) { return v < 0 ? 0 : (v > 100 ? 100 : v); }

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

static lv_obj_t *make_arc(lv_obj_t *parent, lv_coord_t x, lv_coord_t y,
                          lv_coord_t sz, lv_color_t color, const char *title,
                          lv_obj_t **val_out)
{
    lv_obj_t *arc = lv_arc_create(parent);
    lv_obj_set_size(arc, sz, sz);
    lv_obj_set_pos(arc, x, y);
    lv_arc_set_rotation(arc, 135);
    lv_arc_set_bg_angles(arc, 0, 270);
    lv_arc_set_range(arc, 0, 100);
    lv_arc_set_value(arc, 0);
    lv_obj_remove_style(arc, NULL, LV_PART_KNOB);       // no draggable knob
    lv_obj_clear_flag(arc, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(arc, 12, LV_PART_MAIN);
    lv_obj_set_style_arc_width(arc, 12, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(arc, lv_color_hex(0x303030), LV_PART_MAIN);
    lv_obj_set_style_arc_color(arc, color, LV_PART_INDICATOR);

    lv_obj_t *val = lv_label_create(arc);
    lv_obj_set_style_text_font(val, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(val, lv_color_white(), 0);
    lv_label_set_text(val, "--");
    lv_obj_align(val, LV_ALIGN_CENTER, 0, 4);
    *val_out = val;

    lv_obj_t *ttl = lv_label_create(arc);
    lv_label_set_text(ttl, title);
    lv_obj_set_style_text_color(ttl, lv_color_hex(0x888888), 0);
    lv_obj_align(ttl, LV_ALIGN_CENTER, 0, -20);

    return arc;
}

static void build_ui(void)
{
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    const lv_coord_t sz = 120;
    const lv_coord_t x  = (EXAMPLE_LCD_H_RES - sz) / 2;   // 172 -> 26

    cpu_arc = make_arc(scr, x, 6,   sz, lv_palette_main(LV_PALETTE_GREEN), "CPU", &cpu_val);
    mem_arc = make_arc(scr, x, 132, sz, lv_palette_main(LV_PALETTE_BLUE),  "MEM", &mem_val);

    tmp_lbl = lv_label_create(scr);
    lv_obj_set_style_text_font(tmp_lbl, &lv_font_montserrat_16, 0);
    lv_obj_set_style_text_color(tmp_lbl, lv_color_white(), 0);
    lv_label_set_text(tmp_lbl, "--\xC2\xB0""C");
    lv_obj_align(tmp_lbl, LV_ALIGN_TOP_MID, 0, 262);

    net_lbl = lv_label_create(scr);
    lv_obj_set_style_text_color(net_lbl, lv_color_hex(0xAAAAAA), 0);
    lv_label_set_text(net_lbl, "RX -- / TX -- KB/s");
    lv_obj_align(net_lbl, LV_ALIGN_TOP_MID, 0, 292);

    status_lbl = lv_label_create(scr);
    lv_obj_set_style_bg_opa(status_lbl, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(status_lbl, lv_color_hex(0x202020), 0);
    lv_obj_set_style_text_color(status_lbl, lv_color_hex(0xFFB300), 0);
    lv_obj_set_style_pad_all(status_lbl, 8, 0);
    lv_obj_set_style_radius(status_lbl, 6, 0);
    lv_label_set_text(status_lbl, "waiting for host");
    lv_obj_align(status_lbl, LV_ALIGN_CENTER, 0, 0);
}

static void apply_stats(void)
{
    lv_arc_set_value(cpu_arc, s_cpu);
    lv_arc_set_value(mem_arc, s_mem);
    lv_label_set_text_fmt(cpu_val, "%d%%", s_cpu);
    lv_label_set_text_fmt(mem_val, "%d%%", s_mem);
    lv_label_set_text_fmt(tmp_lbl, "%d\xC2\xB0""C", s_tmp);
    lv_label_set_text_fmt(net_lbl, "RX %d / TX %d KB/s", s_rx, s_tx);

    // RGB LED: green (idle) -> red (loaded) by CPU load.
    int r = (s_cpu * 255) / 100;
    Set_RGB((uint8_t)r, (uint8_t)(255 - r), 0);
}

// Toggle between live and "waiting for host" presentation. No-op if unchanged.
static void set_link_state(bool up)
{
    if (up == s_link_up) return;
    s_link_up = up;

    if (up) {
        lv_obj_add_flag(status_lbl, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_opa(cpu_arc, LV_OPA_COVER, 0);
        lv_obj_set_style_opa(mem_arc, LV_OPA_COVER, 0);
    } else {
        lv_obj_clear_flag(status_lbl, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_style_opa(cpu_arc, LV_OPA_40, 0);   // grey out the gauges
        lv_obj_set_style_opa(mem_arc, LV_OPA_40, 0);
        Set_RGB(0, 0, 8);                              // dim blue while waiting
    }
}

// ---------------------------------------------------------------------------
// Serial link
// ---------------------------------------------------------------------------

static void parse_line(const char *s)
{
    int cpu, mem, tmp, rx, tx;
    if (sscanf(s, "CPU:%d,MEM:%d,TMP:%d,RX:%d,TX:%d",
               &cpu, &mem, &tmp, &rx, &tx) == 5) {
        s_cpu = clamp_pct(cpu);
        s_mem = clamp_pct(mem);
        s_tmp = tmp;
        s_rx  = rx;
        s_tx  = tx;
        s_last_rx_ms = now_ms();
        set_link_state(true);
        apply_stats();
    }
}

static void poll_cb(lv_timer_t *t)
{
    (void)t;
    uint8_t buf[64];
    int n;
    while ((n = usb_serial_jtag_read_bytes(buf, sizeof(buf), 0)) > 0) {
        for (int i = 0; i < n; i++) {
            char c = (char)buf[i];
            if (c == '\n') {
                s_line[s_idx] = 0;
                s_idx = 0;
                parse_line(s_line);
            } else if (c != '\r' && s_idx < SYSMON_LINE_MAX - 1) {
                s_line[s_idx++] = c;
            }
        }
    }

    if (now_ms() - s_last_rx_ms > LINK_TIMEOUT_MS) {
        set_link_state(false);
    }
}

void Sysmon_Start(void)
{
    usb_serial_jtag_driver_config_t cfg = USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&cfg));

    build_ui();

    // Start in the waiting state until the first valid line arrives.
    s_last_rx_ms = now_ms() - LINK_TIMEOUT_MS - 1;
    set_link_state(false);

    lv_timer_create(poll_cb, POLL_PERIOD_MS, NULL);
    ESP_LOGI(TAG, "USB system monitor started (USB-Serial/JTAG link)");
}
