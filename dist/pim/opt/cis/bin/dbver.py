import getconfval
import serial
import re

def get_daughter_board_version():
    dev_uart = getconfval.get_json_val("dev_uart")
    ser = serial.Serial(port=dev_uart, baudrate=115200, parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE, bytesize=serial.EIGHTBITS, timeout=1)
    ser.write(bytes('<GETVER>', encoding='ascii'))
    r = ser.read_until(expected=']'.encode('ascii'))
    p = re.compile('[A-Z0-9.]+')
    result = p.findall(r.decode('utf-8'))

    if len(result) == 3 or len(result) == 2:
        if result[0] == 'GETVER' :
            f = open("/tmp/dbver", "w")
            f.write(result[1])
            f.write('\n')
            f.close
            #print(result)
        else :
            print("Serial response is not GETVER :", r)
    else :
        print("Serial received :", r)

    ser.close()

    return result[1]

if __name__ == '__main__' :
    ver = get_daughter_board_version()
    print(ver)