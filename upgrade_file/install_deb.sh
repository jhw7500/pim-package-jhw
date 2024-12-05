#!/bin/bash

cd `dirname "$0"`
BASEDIR=${PWD}

########################################
## Install deb packages               ##
########################################
prog_per=2
echo '{"PROGRESS":'"$prog_per"',"MSG":"Install dependency deb packages"}'
cd ${BASEDIR}/dpkg

package="python3-pip"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('zlib1g_1%3a1.2.11.dfsg-2ubuntu1.5_arm64.deb' \
    'zlib1g-dev_1%3a1.2.11.dfsg-2ubuntu1.5_arm64.deb' \
    'python3-pkg-resources_45.2.0-1ubuntu0.1_all.deb' \
    'python3-distutils_3.8.10-0ubuntu1~20.04_all.deb' \
    'libexpat1_2.2.9-1ubuntu0.6_arm64.deb' \
    'libpython3.8-minimal_3.8.10-0ubuntu1~20.04.9_arm64.deb' \
    'python3-setuptools_45.2.0-1ubuntu0.1_all.deb' \
    'python3-wheel_0.34.2-1ubuntu0.1_all.deb' \
    'libexpat1-dev_2.2.9-1ubuntu0.6_arm64.deb' \
    'python3.8-minimal_3.8.10-0ubuntu1~20.04.9_arm64.deb' \
    'python-pip-whl_20.0.2-5ubuntu1.10_all.deb' \
    'libpython3.8-stdlib_3.8.10-0ubuntu1~20.04.9_arm64.deb' \
    'python3.8_3.8.10-0ubuntu1~20.04.9_arm64.deb' \
    'libpython3.8_3.8.10-0ubuntu1~20.04.9_arm64.deb' \
    'python3-pip_20.0.2-5ubuntu1.10_all.deb' \
    'libpython3.8-dev_3.8.10-0ubuntu1~20.04.9_arm64.deb' \
    'python3.8-dev_3.8.10-0ubuntu1~20.04.9_arm64.deb' \
    'libpython3-dev_3.8.2-0ubuntu2_arm64.deb' \
    'python3-dev_3.8.2-0ubuntu2_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="python3-ipython"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('python3-backcall_0.1.0-2_all.deb' \
    'python3-parso_0.5.2-1ubuntu1_all.deb' \
    'python3-ipython-genutils_0.2.0-1ubuntu1_all.deb' \
    'python3-decorator_4.4.2-0ubuntu1_all.deb' \
    'python3-wcwidth_0.1.8+dfsg1-3_all.deb' \
    'python3-pickleshare_0.7.5-2_all.deb' \
    'python3-traitlets_4.3.3-3_all.deb' \
    'python3-ptyprocess_0.6.0-1ubuntu1_all.deb' \
    'python3-prompt-toolkit_2.0.10-2_all.deb' \
    'python3-jedi_0.15.2-1_all.deb' \
    'python3-pexpect_4.6.0-1build1_all.deb' \
    'python3-ipython_7.13.0-1_all.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

#package="ssh"
#if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
#  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
#  deb_list=('openssh-client_1%3a8.2p1-4ubuntu0.11_arm64.deb' \
#    'openssh-sftp-server_1%3a8.2p1-4ubuntu0.11_arm64.deb' \
#    'openssh-server_1%3a8.2p1-4ubuntu0.11_arm64.deb' \
#    'ssh_1%3a8.2p1-4ubuntu0.11_all.deb' )
#  for var in "${deb_list[@]}"
#  do
#    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
#    dpkg -i "$var" > /dev/null 2> /dev/null
#  done
#else
#  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
#fi

package="tcpdump"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='tcpdump_4.9.3-4ubuntu0.3_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="wireshark"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('libssh-gcrypt-4_0.9.3-2ubuntu2.5_arm64.deb' \
    'libdouble-conversion3_3.1.5-4ubuntu1_arm64.deb' \
    'libxcb-xinput0_1.14-2_arm64.deb' \
    'libc-ares2_1.15.0-1ubuntu0.5_arm64.deb' \
    'libwsutil11_3.2.3-1_arm64.deb' \
    'libpcre2-16-0_10.34-7ubuntu0.1_arm64.deb' \
    'libspandsp2_0.0.6+dfsg-2_arm64.deb' \
    'libsnappy1v5_1.1.8-1build1_arm64.deb' \
    'libsmi2ldbl_0.4.8+dfsg2-16_arm64.deb' \
    'libwiretap10_3.2.3-1_arm64.deb' \
    'libxcb-xinerama0_1.14-2_arm64.deb' \
    'qttranslations5-l10n_5.12.8-0ubuntu1_all.deb' \
    'libqt5core5a_5.12.8+dfsg-0ubuntu2.1_arm64.deb' \
    'libwireshark-data_3.2.3-1_all.deb' \
    'liblua5.2-0_5.2.4-1.1build3_arm64.deb' \
    'libqt5dbus5_5.12.8+dfsg-0ubuntu2.1_arm64.deb' \
    'libwireshark13_3.2.3-1_arm64.deb' \
    'libqt5network5_5.12.8+dfsg-0ubuntu2.1_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
  
  var='wireshark-common_3.2.3-1_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive dpkg -i "$var" > /dev/null 2> /dev/null
  
  deb_list=('libqt5gui5_5.12.8+dfsg-0ubuntu2.1_arm64.deb' \
    'libqt5widgets5_5.12.8+dfsg-0ubuntu2.1_arm64.deb' \
    'qt5-gtk-platformtheme_5.12.8+dfsg-0ubuntu2.1_arm64.deb' \
    'libqt5multimedia5_5.12.8-0ubuntu1_arm64.deb' \
    'libqt5printsupport5_5.12.8+dfsg-0ubuntu2.1_arm64.deb' \
    'wireshark-qt_3.2.3-1_arm64.deb' \
    'libqt5opengl5_5.12.8+dfsg-0ubuntu2.1_arm64.deb' \
    'wireshark_3.2.3-1_arm64.deb' \
    'libqt5svg5_5.12.8-0ubuntu1_arm64.deb' \
    'libqt5multimediawidgets5_5.12.8-0ubuntu1_arm64.deb' \
    'libqt5multimediagsttools5_5.12.8-0ubuntu1_arm64.deb' \
    'libqt5multimedia5-plugins_5.12.8-0ubuntu1_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="tshark"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='tshark_3.2.3-1_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="gawk"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='gawk_1%3a5.0.1+dfsg-1ubuntu0.1_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="zip"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='zip_3.0-11build1_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="at"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('libfl2_2.6.4-6.2_arm64.deb' \
    'at_3.1.23-1ubuntu1_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="cifs-utils"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='cifs-utils_2%3a6.9-1ubuntu0.2_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="stress"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='stress_1.0.4-6_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="curl"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('libcurl4_7.68.0-1ubuntu2.22_arm64.deb' \
    'curl_7.68.0-1ubuntu2.22_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="libbluetooth-dev"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('libbluetooth3_5.53-0ubuntu3.7_arm64.deb' \
    'libbluetooth-dev_5.53-0ubuntu3.7_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="jq"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('libonig5_6.9.4-1_arm64.deb' \
    'libjq1_1.6-1ubuntu0.20.04.1_arm64.deb' \
    'jq_1.6-1ubuntu0.20.04.1_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="cpulimit"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='cpulimit_2.6-2_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="hiredis"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  var='libhiredis0.14_0.14.0-6_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
  var='libhiredis-dev_0.14.0-6_arm64.deb'
  echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
  dpkg -i "$var" > /dev/null 2> /dev/null
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

package="redis-server"
if [ -z "$(dpkg -s $package 2> /dev/null)" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"install '"$package"'"}'
  deb_list=('libjemalloc2_5.2.1-1ubuntu1_arm64.deb' \
    'lua-cjson_2.1.0+dfsg-2.1_arm64.deb' \
    'lua-bitop_1.0.2-5_arm64.deb' \
    'liblua5.1-0_5.1.5-8.1build4_arm64.deb' \
    'redis-tools_5%3a5.0.7-2ubuntu0.1_arm64.deb' \
    'redis-server_5%3a5.0.7-2ubuntu0.1_arm64.deb' )
  for var in "${deb_list[@]}"
  do
    echo '{"PROGRESS":'"$prog_per"',"MSG":"dpkg -i '"$var"'"}'
    dpkg -i "$var" > /dev/null 2> /dev/null
  done
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"installed '"$package"'"}'
fi

# Check if the directory exists
need_restart=0
if [ ! -f "/etc/tmpfiles.d/redis.conf" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"'"$package"', create /etc/tmpfiles.d/redis.conf "}'
  echo 'd  /var/volatile/log/redis  0755  redis redis  -
d  /var/run/redis           0755  redis redis  -' > /etc/tmpfiles.d/redis.conf
  systemctl restart systemd-tmpfiles-clean.service
  systemd-tmpfiles --create
  need_restart=1
fi

str=$(cat /etc/redis/redis.conf | grep ^notify-keyspace-events | tr -d '\r\n')
if [ "${str}" != "notify-keyspace-events \"KA\"" ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"'"$package"', edit notify-keyspace-events "}'
  sed "s/$str/notify-keyspace-events \"KA\"/" -i /etc/redis/redis.conf
  need_restart=1
fi

if [ $need_restart == 1 ]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"'"$package"', Restarting Redis-server service..."}'
  systemctl daemon-reload
  systemctl restart redis-server
fi

########################################
## Install pip packages               ##
########################################
prog_per=3
echo '{"PROGRESS":'"$prog_per"',"MSG":"Install dependency pip packages"}'
cd ${BASEDIR}/pip
pip_list=$(pip list 2> /dev/null)
package_list=('schedule' \
          'paramiko' \
          'docker' \
          'pyserial' \
          'ipaddress' \
          'lockfile' \
          'jsonpath-ng' \
          'redis'
          'paho-mqtt'
          'numpy'
          'dataclasses')
for package in "${package_list[@]}"
do
  installed_pip=$(echo "$pip_list" | grep -E "${package}\s")
  if [ -z "${installed_pip}" ]; then
    echo '{"PROGRESS":'"$prog_per"',"MSG":"pip install '"$package"'"}'
    pip install --no-index --find-links=./ "$package" > /dev/null 2> /dev/null
  else
    echo '{"PROGRESS":'"$prog_per"',"MSG":"pip installed '"$package"'"}'
  fi
done

package="aioredis"
package_ver="1.3.1"
installed_pip=$(echo "$pip_list" | grep -E "${package}\s")
installed_package_ver=$(echo "$installed_pip" | awk '{print $2}')

if [[ -n "${installed_pip}"  && "${installed_package_ver}" == "${package_ver}" ]]; then
  echo '{"PROGRESS":'"$prog_per"',"MSG":"pip installed '"$package"'=='"$package_ver"'"}'
else
  echo '{"PROGRESS":'"$prog_per"',"MSG":"pip install '"$package"'=='"$package_ver"'"}'
  pip install --no-index --find-links=./ "$package"'=='"$package_ver" > /dev/null 2> /dev/null
fi

package="psutil"
installed_pip=$(echo "$pip_list" | grep -E "${package}\s")
if [ -z "${installed_pip}" ]; then
  var="psutil-5.9.8"
  echo '{"PROGRESS":'"$prog_per"',"MSG":"xvzf '"$package"'.tar.gz"}'
  tar xvzf "${var}.tar.gz" > /dev/null 2> /dev/null
  echo '{"PROGRESS":'"$prog_per"',"MSG":"pip install '"$package"'"}'
  cd ${BASEDIR}/pip/${var}
  python3 ./setup.py install > /dev/null 2> /dev/null
else
    echo '{"PROGRESS":'"$prog_per"',"MSG":"pip installed '"$package"'"}'
fi

package="sysv_ipc"
installed_pip=$(echo "$pip_list" | grep -E "${package}\s")
if [ -z "${installed_pip}" ]; then
  var="sysv_ipc-1.1.0"
  echo '{"PROGRESS":'"$prog_per"',"MSG":"xvzf '"$package"'.tar.gz"}'
  tar xvzf "${var}.tar.gz" > /dev/null 2> /dev/null
  echo '{"PROGRESS":'"$prog_per"',"MSG":"pip install '"$package"'"}'
  cd ${BASEDIR}/pip/${var}
  python3 ./setup.py install > /dev/null 2> /dev/null
else
    echo '{"PROGRESS":'"$prog_per"',"MSG":"pip installed '"$package"'"}'
fi

cd ${BASEDIR}
