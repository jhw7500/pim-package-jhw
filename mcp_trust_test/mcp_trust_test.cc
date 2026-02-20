#include "udrv_mcp.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <stdint.h>

#include <unistd.h>
#include <fcntl.h>

#include <iostream>
#include <cstdio>
#include <memory>
#include <array>
#include <string>
#include <fstream>
#include <sstream>
#include <thread>
#include <chrono>
#include <sys/stat.h>

#define ETC_SEN_PATH "/tmp/etc_sen"

std::string run_command(const std::string& cmd)
{
    std::array<char, 256> buffer{};
    std::string result;

    std::unique_ptr<FILE, decltype(&pclose)>
        pipe(popen(cmd.c_str(), "r"), pclose);

    if (!pipe)
        return "";

    while (fgets(buffer.data(), buffer.size(), pipe.get()) != nullptr)
    {
        result += buffer.data();
    }

    if (!result.empty() && result.back() == '\n')
        result.pop_back();

    return result;
}

bool extract_value(const std::string& content,
                   const std::string& key,
                   double& out_value)
{
    size_t pos = content.find("\"" + key + "\"");
    if (pos == std::string::npos)
        return false;

    pos = content.find(":", pos);
    if (pos == std::string::npos)
        return false;

    pos = content.find("\"", pos);
    if (pos == std::string::npos)
        return false;

    size_t end = content.find("\"", pos + 1);
    if (end == std::string::npos)
        return false;

    std::string value_str = content.substr(pos + 1, end - pos - 1);

    try {
        out_value = std::stod(value_str);
    } catch (...) {
        return false;
    }

    return true;
}

bool file_exists(void)
{
    struct stat buffer;
    return (stat(ETC_SEN_PATH, &buffer) == 0);
}

bool read_power_values(double& voltage, double& current)
{
    std::ifstream ifs(ETC_SEN_PATH);
    if (!ifs)
        return false;

    std::stringstream buffer;
    buffer << ifs.rdbuf();
    std::string content = buffer.str();

    if (!extract_value(content, "power_voltage", voltage))
        return false;

    if (!extract_value(content, "power_current", current))
        return false;

    return true;
}

int main(void) {
    bool is_direct = false;
	std::string cmd = "debconf-show pim-mp 2>/dev/null | cut -d':' -f2 | tr -d ' '";
    std::string model_name = run_command(cmd);
	if (model_name.size() >= 2)
	{
		char second_last = model_name[model_name.size() - 2];
		if (second_last == 'x')
			is_direct = true;
	}
    double v = 0.0, c = 0.0;
    bool res = false;
    if (is_direct == false && file_exists()) {
        int retry = 3;
        do {
            res = read_power_values(v, c);
            if (res == true) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }while(retry-- > 0);
    }

    if(res == false) {
        int retry = 3;
		Udrv_MCP *mcpdev = new Udrv_MCP("/dev/i2c-1", 0x68);
        do {
            res = mcpdev->read_power_values(v, c);
            if (res == true) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }while(retry-- > 0);
    }

    if(res == true)
        printf("Power voltage : %.4f\nPower current : %.4f\n", v, c);
    else
        printf("failed mcp_read_all_ch\r\n");
    return 0;
}