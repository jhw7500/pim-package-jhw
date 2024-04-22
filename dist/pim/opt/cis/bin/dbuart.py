import getconfval
import sys
import serial
import re

def daughter_just_send(data):
    dev_uart = getconfval.get_json_val("dev_uart")
    ser = serial.Serial(port=dev_uart, baudrate=115200, parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE, bytesize=serial.EIGHTBITS, timeout=1)
    ser.write(bytes(data, encoding='ascii'))
    r = ser.read_until(expected=']'.encode('ascii'))
    ser.close()

    return r.decode('utf-8')

if __name__ == '__main__' :
    rcvdata = daughter_just_send(sys.argv[1])
    print(rcvdata)