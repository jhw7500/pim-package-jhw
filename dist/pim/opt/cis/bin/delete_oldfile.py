import os
import time
import sys
import shutil
import datetime

def delete_old_files(directory, max_size, max_age_hours):
    total_size = 0
    origin_size = 0
    file_list = []

    # 디렉토리를 순회하면서 파일 정보 수집
    for root, dirs, files in os.walk(directory):
        for file in files:
            file_path = os.path.join(root, file)
            file_stat = os.stat(file_path)
            file_size = file_stat.st_size
            file_age_hours = (time.time() - file_stat.st_mtime) / 3600  # 파일 생성 후 경과 시간 (시간 단위)
            file_info = {'path': file_path, 'size': file_size, 'age_hours': file_age_hours}
            file_list.append(file_info)
            total_size += file_size

    # 파일 생성 시간 기준으로 소팅
    file_list.sort(key=lambda x: x['age_hours'],reverse=True)

    # 파일 삭제
    origin_size = total_size
    while total_size > max_size :
        oldest_file = file_list.pop(0)
        oldest_file_path = oldest_file['path']
        oldest_file_size = oldest_file['size']
        oldest_file_age_hours = oldest_file['age_hours'] / 3600

        if oldest_file_age_hours <= max_age_hours:
            # 파일 생성 시간 기준 상한에 미달하면 종료
            break

        try:
            # 파일 삭제
            os.remove(oldest_file_path)
            #print(f"Deleted file {oldest_file_path} ({oldest_file_size} bytes)")
            total_size -= oldest_file_size
        except OSError as e:
            print(f"ERROR:deleting file {oldest_file_path}: {e}")

    # 결과 출력
    if origin_size != total_size :
        print(f"DATA:delete {origin_size - total_size} bytes")

def delete_empty_dirs(root_dir):
    for root, dirs, files in os.walk(root_dir, topdown=False):
        for dir in dirs:
            dir_path = os.path.join(root, dir)
            if not os.listdir(dir_path):  # check if directory is empty
                os.rmdir(dir_path)

###########################################
### arg[1] : directory     삭제할 파일들이 위치한 디렉토리
### arg[2] : max_size      삭제할 파일들의 총 용량 상한
### arg[3] : max_age_hours 삭제할 파일들의 생성 시간 기준 상한 (시간 단위)

directory = ""
max_size = 10 * 1024 * 1024  # 10MB
max_age_hours = 0

if len(sys.argv) == 2 :
    directory = sys.argv[1]
if len(sys.argv) == 3 :
    directory = sys.argv[1]
    try:
        max_size = int(sys.argv[2])
    except ValueError:
        print("ERROR:Cannot convert to int")
        sys.exit()
elif len(sys.argv) == 4 :
    directory = sys.argv[1]
    try:
        max_size = int(sys.argv[2])
        max_age_hours = int(sys.argv[3])
    except ValueError:
        print("ERROR:Cannot convert to int")
        sys.exit()

if directory == '/' :
    print("ERROR:Don`t allow root directory")
    sys.exit()
elif not (os.path.exists(directory) and os.path.isdir(directory)):
    print('ERROR:Directory does not exist')

delete_old_files(directory, max_size, max_age_hours)
delete_empty_dirs(directory)
