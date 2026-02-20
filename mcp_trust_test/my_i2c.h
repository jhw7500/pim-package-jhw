#ifndef __MY_I2C_H__
#define __MY_I2C_H__

#include <stddef.h>
#include <stdint.h>

class My_I2C {
public:
    My_I2C();
    My_I2C(const char* filename, uint16_t addr);
    ~My_I2C();

    int i2c_start(void);
    int i2c_read(uint8_t *buf, size_t buf_len);
    int i2c_write(uint8_t *buf, size_t buf_len);
    int i2c_readn_reg(uint8_t reg, uint8_t *buf, size_t buf_len);
    int i2c_writen_reg(uint8_t reg, uint8_t *buf, size_t buf_len);
    uint8_t i2c_read_reg(uint8_t reg);
    int i2c_write_reg(uint8_t reg, uint8_t value);
    void i2c_stop(void);

private:
	bool open_flag_;
    const char* filename_; /**< Path of the I2C bus, eg: /dev/i2c-0 */
	uint16_t addr_; /**< Address of the I2C slave, eg: 0x48 */
	int fd_; /**< File descriptor for the I2C bus */
};

#endif