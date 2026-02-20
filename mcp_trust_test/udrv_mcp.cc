#include "udrv_mcp.h"
#include <stdio.h>
#include <unistd.h>
#include <iostream>
#include <string>
#include <cstring>
#include <fstream>
#include <experimental/filesystem>


Udrv_MCP::Udrv_MCP():myI2c_(NULL,0) {}
Udrv_MCP::Udrv_MCP(const char* filename, uint16_t addr):myI2c_(filename,addr) {}

#define SRATE_12BIT_USE 1

#define MCP_CONF_INITIATE_NEW	(1<<7)
#define MCP_CONF_CHANNEL_1	(0 << 5)
#define MCP_CONF_CHANNEL_2	(1 << 5)
#define MCP_CONF_MODE_CONT	(0<<4)
#define MCP_CONF_MODE_ONE	(1<<4)
#define MCP_CONF_SRATE_12BIT	(0<<2)
#define MCP_CONF_SRATE_14BIT	(1<<2)
#define MCP_CONF_SRATE_16BIT	(2<<2)
#define MCP_CONF_PGA_X1		(0<<0)
#define MCP_CONF_PGA_X2		(1<<0)
#define MCP_CONF_PGA_X4		(2<<0)
#define MCP_CONF_PGA_X8		(3<<0)

#if (SRATE_12BIT_USE == 1)
#define MCP_CONF_DEFAULT (MCP_CONF_MODE_CONT | MCP_CONF_SRATE_12BIT | MCP_CONF_PGA_X1)
#else
#define MCP_CONF_DEFAULT (MCP_CONF_MODE_CONT | MCP_CONF_SRATE_16BIT | MCP_CONF_PGA_X1)
#endif

#define PW_SAMPLE_RATE       (50)
#define PW_SAMPLE_DURATION   (1000000/PW_SAMPLE_RATE)    //20 msec
#define TRUST_TEST_PATH "/trust_test/log"


int Udrv_MCP::mcp_read_ch(uint8_t ch, uint16_t *data) {
	uint8_t buf[3];
	uint8_t conf;
	uint8_t rd_ch;
	int rc;
	int retry_cnt = 1;
	int not_ready_cnt = 0;

retry:
    rc = myI2c_.i2c_start();
	if (rc) {
		printf("failed to start i2c device\r\n");
		return rc;
	}

	myI2c_.i2c_read(buf, 3);
	rd_ch = ((buf[2] >> 5) & 0x1);

	if(ch != rd_ch) {
        if(ch == 0) conf = MCP_CONF_DEFAULT | MCP_CONF_CHANNEL_1 | MCP_CONF_INITIATE_NEW;
        else        conf = MCP_CONF_DEFAULT | MCP_CONF_CHANNEL_2 | MCP_CONF_INITIATE_NEW;
        myI2c_.i2c_write(&conf,1);        
		myI2c_.i2c_stop();
		retry_cnt--;
		if(retry_cnt >=0) goto retry;
		printf("not match channel : %d, %d\n", ch, rd_ch);
		return -1;
	}

	if((buf[2] >> 7) & 01) {
		myI2c_.i2c_stop();
		not_ready_cnt++;
        if(not_ready_cnt <= 5) {
            usleep(1000);
			//std::this_thread::sleep_for(std::chrono::milliseconds(1));
            goto retry;
        }else return -1;
	}

    if(ch == 0) conf = MCP_CONF_DEFAULT | MCP_CONF_CHANNEL_2 | MCP_CONF_INITIATE_NEW;
    else        conf = MCP_CONF_DEFAULT | MCP_CONF_CHANNEL_1 | MCP_CONF_INITIATE_NEW;
    myI2c_.i2c_write(&conf,1);	

	myI2c_.i2c_stop();

	*data = buf[1] | (buf[0] << 8);
	return 0;
}

int Udrv_MCP::mcp_read_all_ch(uint16_t *data) {
	int res = 0;
	res = mcp_read_ch(0,&data[0]);
	if(res != 0) return res;

	res = mcp_read_ch(1,&data[1]);
	return res;
}

float Udrv_MCP::mcp_conv_volt(uint16_t data) {
#if (SRATE_12BIT_USE == 1)
    return (float)(2.048/(double)(1 << 11)*((double)data)*28./2.0269);
#else
	return (float)(2.048/(double)(1 << 15)*((double)data)*28./2.0269);
#endif
}

float Udrv_MCP::mcp_conv_curr(uint16_t data) {
#if (SRATE_12BIT_USE == 1)
    return (float)(2.048/(double)(1 << 11)*((double)data)*1.5/1.99665);
#else
    return (float)(2.048/(double)(1 << 15)*((double)data)*1.5/1.99665);
#endif
}

bool Udrv_MCP::read_power_values(double& voltage, double& current) {
	uint16_t data[2] = {0,};
	if(mcp_read_all_ch(data) != 0) 
		return false;
	voltage = (double)mcp_conv_volt(data[1]);
	current = (double)mcp_conv_curr(data[0]);
	return true;
}

void Udrv_MCP::mcp_print(uint16_t *data) {
	printf("Power voltage : %.4f\nPower current : %.4f\n", mcp_conv_volt(data[1]), mcp_conv_curr(data[0]));
	fflush(stdout);
}