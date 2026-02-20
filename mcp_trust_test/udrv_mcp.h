#ifndef __UDRV_RTC_H__
#define __UDRV_RTC_H__

#include "my_i2c.h"
#include <stdint.h>

class Udrv_MCP {
public:
    Udrv_MCP();
    Udrv_MCP(const char* filename, uint16_t addr);

    int mcp_read_all_ch(uint16_t *data);
    bool read_power_values(double& voltage, double& current);
    void mcp_print(uint16_t *data);
private:
    My_I2C myI2c_;

    int mcp_read_ch(uint8_t ch, uint16_t *data);
    float mcp_conv_volt(uint16_t data);
    float mcp_conv_curr(uint16_t data);
};

#endif