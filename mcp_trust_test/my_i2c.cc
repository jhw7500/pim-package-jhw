#include "my_i2c.h"

#include <stdint.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <errno.h>

#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <iostream>

My_I2C::My_I2C() {
    filename_ = NULL;
    addr_ = 0;
    open_flag_ = false;
}

My_I2C::My_I2C(const char* filename, uint16_t addr) {
    filename_ = filename;
    addr_ = addr;
    open_flag_ = false;
}

My_I2C::~My_I2C() {
    if(open_flag_ == true) {
        open_flag_ = false;
	    close(fd_);
    }
}

int My_I2C::i2c_start(void) {
	if(filename_ == NULL) return ENODEV;
	int fd;
    int rc;
    
	fd = open(filename_, O_RDWR);
	if (fd < 0) {
		rc = fd;
		goto fail_open;
	}
    open_flag_ = true;

	rc = ioctl(fd, I2C_SLAVE, addr_);
	if (rc < 0) {
		goto fail_set_i2c_slave;
	}

	fd_ = fd;
	return 0;

fail_set_i2c_slave:
    open_flag_ = false;
	close(fd);
fail_open:
	return rc;

}

void My_I2C::i2c_stop(void) {
    if(open_flag_ == true) {
        open_flag_ = false;
	    close(fd_);
    }
}

int My_I2C::i2c_read(uint8_t *buf, size_t buf_len) {
    if(open_flag_ == false) return ENODEV;
	return read(fd_, buf, buf_len);
}

int My_I2C::i2c_write(uint8_t *buf, size_t buf_len) {
    if(open_flag_ == false) return ENODEV;
	return write(fd_, buf, buf_len);
}
int My_I2C::i2c_readn_reg(uint8_t reg, uint8_t *buf, size_t buf_len) {
	int rc;

	rc = i2c_write(&reg, 1);
	if (rc <= 0) {
		printf("%s: failed to write i2c register address\r\n", __func__);
		return rc;
	}

	rc = i2c_read(buf, buf_len);
	if (rc <= 0) {
		printf("%s: failed to read i2c register data\r\n", __func__);
		return rc;
	}

	return rc;
}

int My_I2C::i2c_writen_reg(uint8_t reg, uint8_t *buf, size_t buf_len) {
	uint8_t *full_buf;
	int full_buf_len;
	int rc;
	int i;

	full_buf_len = buf_len + 1;
	full_buf = (uint8_t *)malloc(sizeof(uint8_t) * full_buf_len);

	full_buf[0] = reg;
	for (i = 0; i < (int)buf_len; i++) {
		full_buf[i + 1] = buf[i];
	}

	rc = i2c_write(full_buf, full_buf_len);
	if (rc <= 0) {
		printf("%s: failed to write i2c register address and data\r\n", __func__);
		goto fail_send;
	}

	free(full_buf);
	return 0;

fail_send:
	free(full_buf);
	return rc;
}

uint8_t My_I2C::i2c_read_reg(uint8_t reg) {
	uint8_t value = 0;
	i2c_readn_reg(reg, &value, 1);
	return value;
}

int My_I2C::i2c_write_reg(uint8_t reg, uint8_t value) {
	return i2c_writen_reg(reg, &value, 1);
}

