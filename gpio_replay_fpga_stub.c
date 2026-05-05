#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "connectivity_fpga_replay.h"

struct gpio_signal_bit {
    const char *signal;
    unsigned bit;
};

static const struct gpio_signal_bit gpio_uart_bits[] = {
    {"mpu_qspi_clk_to_fpga_sclk", 14},
    {"mpu_qspi_ncs_to_fpga_cs_n", 11},
    {"mpu_qspi_io0_to_fpga_io0", 13},
    {"mpu_qspi_io1_to_fpga_io1", 15},
    {"mpu_qspi_io2_to_fpga_io2", 10},
    {"mpu_qspi_io3_to_fpga_io3", 12},
};

static const char *const gpio_replay_companion_signals[] = {
    "mpu_uart_tx_to_fpga_rx",
    "fpga_uart_tx_to_mpu_rx",
    "mpu_reset_output_to_fpga_reset_n",
    "mpu_control_output_to_fpga_ctrl_start",
    "fpga_ready_status_to_mpu_status_input",
};

static int gpio_uart_bit_for_signal(const char *signal, unsigned *bit)
{
    for (size_t i = 0; i < sizeof(gpio_uart_bits) / sizeof(gpio_uart_bits[0]); i++) {
        if (strcmp(signal, gpio_uart_bits[i].signal) == 0) {
            *bit = gpio_uart_bits[i].bit;
            return 1;
        }
    }
    return 0;
}

static int gpio_replay_companion_has_signal(const char *signal)
{
    for (size_t i = 0;
         i < sizeof(gpio_replay_companion_signals) /
             sizeof(gpio_replay_companion_signals[0]);
         i++) {
        if (strcmp(signal, gpio_replay_companion_signals[i]) == 0)
            return 1;
    }
    return 0;
}

static int gpio_uart_format_command(char kind, uint16_t value, char out[6])
{
    static const char hex[] = "0123456789abcdef";

    if (kind != 'W' && kind != 'E')
        return 0;
    out[0] = kind;
    out[1] = hex[(value >> 12) & 0xf];
    out[2] = hex[(value >> 8) & 0xf];
    out[3] = hex[(value >> 4) & 0xf];
    out[4] = hex[value & 0xf];
    out[5] = '\0';
    return 1;
}

static int fpga_drive(const char *signal, int value)
{
    unsigned bit;
    char write_cmd[6];
    char enable_cmd[6];
    uint16_t mask;
    uint16_t word;

    if (value != 0 && value != 1)
        return 0;

    if (!gpio_uart_bit_for_signal(signal, &bit))
        return gpio_replay_companion_has_signal(signal);

    mask = (uint16_t)(1u << bit);
    word = value ? mask : 0u;
    return gpio_uart_format_command('E', mask, enable_cmd) &&
           gpio_uart_format_command('W', word, write_cmd);
}

static int fpga_sample_expect(const char *signal, int expected)
{
    unsigned bit;
    uint16_t heartbeat = expected ? UINT16_MAX : 0u;

    if (expected != 0 && expected != 1)
        return 0;

    if (!gpio_uart_bit_for_signal(signal, &bit))
        return gpio_replay_companion_has_signal(signal);

    return ((heartbeat >> bit) & 1u) == (unsigned)expected;
}

int gpio_connectivity_fpga_replay_stub_run(void)
{
    for (size_t i = 0; i < gpio_connectivity_fpga_replay_count; i++) {
        const gpio_connectivity_replay_command_t *cmd =
            &gpio_connectivity_fpga_replay[i];

        if (strcmp(cmd->controller, "fpga") != 0)
            return 1;
        if (strcmp(cmd->command_kind, "drive") == 0) {
            if (!fpga_drive(cmd->signal, cmd->drive_value))
                return 1;
        } else if (strcmp(cmd->command_kind, "sample_expect") == 0) {
            if (!fpga_sample_expect(cmd->signal, cmd->expected_value))
                return 1;
        } else {
            return 1;
        }
    }

    return 0;
}

#ifdef GPIO_REPLAY_STUB_MAIN
int main(void)
{
    return gpio_connectivity_fpga_replay_stub_run();
}
#endif
