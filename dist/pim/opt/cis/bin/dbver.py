import getconfval
import serial
import re

def get_daughter_board_version():
    dev_uart = getconfval.get_json_val("dev_uart")
    ser = None
    version=""
    try :
        ser = serial.Serial(
            port=dev_uart, 
            baudrate=115200, 
            parity=serial.PARITY_NONE, 
            stopbits=serial.STOPBITS_ONE, 
            bytesize=serial.EIGHTBITS, 
            timeout=1
        )

        ser.write(bytes('<GETVER>', encoding='ascii'))
        r = ser.read_until(expected=']'.encode('ascii'))
        if r:
            p = re.compile('[A-Z0-9.]+')
            result = p.findall(r.decode('utf-8', errors='ignore'))
            if len(result) >= 2 and result[0] == 'GETVER':
                version = result[1]

    except Exception:
        pass

    finally:
        if ser:
            ser.close()
        with open("/tmp/dbver", "w") as f:
            f.write(version)
            f.write('\n')
    return version

if __name__ == '__main__' :
    ver = get_daughter_board_version()
    print(ver)