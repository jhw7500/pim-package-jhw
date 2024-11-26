#!/bin/bash

BASEDIR=${PWD}
echo "Script location: ${BASEDIR}"

if [ ! -d ${BASEDIR}/ord/build ]; then
    mkdir ${BASEDIR}/ord/build
fi
cd ${BASEDIR}/ord/build
cmake ..
#cd ${BASEDIR}/ord/
make
if [ $? != 0 ]; then
    echo "ord compile error"
    exit 1
fi

if [ ! -d ${BASEDIR}/vsd/build ]; then
    mkdir ${BASEDIR}/vsd/build
fi
cd ${BASEDIR}/vsd/build
cp ${BASEDIR}/vsd/libpi* /usr/local/lib/ -a
cmake ..
make
if [ $? != 0 ]; then
    echo "vsd compile error"
    exit 1
fi

if [ ! -d ${BASEDIR}/vcm/build ]; then
	    mkdir ${BASEDIR}/vcm/build
fi
cd ${BASEDIR}/vcm/build
cmake ..
#cd ${BASEDIR}/vcm
make
if [ $? != 0 ]; then
	    echo "vcm compile error"
	        exit 1
fi

if [ ! -d ${BASEDIR}/adab/build ]; then
    mkdir ${BASEDIR}/adab/build
fi
cd ${BASEDIR}/adab/build
cmake ..
make
if [ $? != 0 ]; then
    echo "adab compile error"
    exit 1
fi

if [ ! -d ${BASEDIR}/adab_ecat/build ]; then
    mkdir ${BASEDIR}/adab_ecat/build
fi
cd ${BASEDIR}/adab_ecat/build
cmake ..
make
if [ $? != 0 ]; then
    echo "adab_ecat compile error"
    exit 1
fi

if [ ! -d ${BASEDIR}/cism/build ]; then
    mkdir ${BASEDIR}/cism/build
fi
cd ${BASEDIR}/cism/build
cmake ..
make
if [ $? != 0 ]; then
    echo "cism compile error"
    exit 1
fi

if [ ! -d ${BASEDIR}/stm32update/build ]; then
    mkdir ${BASEDIR}/stm32update/build
fi
cd ${BASEDIR}/stm32update/build
cmake ..
make
if [ $? != 0 ]; then
    echo "stm32update compile error"
    exit 1
fi


cd ${BASEDIR}
rm -rf ${BASEDIR}/release
cp ${BASEDIR}/ord/build/ord ${BASEDIR}/dist/pim/usr/local/bin/
cp ${BASEDIR}/vsd/build/vsd ${BASEDIR}/dist/pim/usr/local/bin/
cp ${BASEDIR}/vcm/build/vcm ${BASEDIR}/dist/pim/usr/local/bin/
cp -R ${BASEDIR}/dist ${BASEDIR}/release
cp ${BASEDIR}/adab/build/adab ${BASEDIR}/release/pim/opt/cis/bin/adab_adc
cp ${BASEDIR}/adab_ecat/build/adab_ecat ${BASEDIR}/release/pim/opt/cis/bin/adab_ecat
cp ${BASEDIR}/cism/build/cism ${BASEDIR}/release/pim/opt/cis/bin/
cp ${BASEDIR}/stm32update/build/stm32update ${BASEDIR}/release/pim/opt/cis/bin/
cd ${BASEDIR}/release
version=$(cat ../dist/pim/DEBIAN/control| grep Version |grep -v ^$#| cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n' | tr -d ' ')
package=$(cat ../dist/pim/DEBIAN/control| grep Package |grep -v ^$#| cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n' | tr -d ' ')
echo version:$version
dpkg -b pim
#dpkg-deb --build pim
cp pim.deb $package-$version.deb

#### create_upgrade_file ######################
if [ -d ${BASEDIR}/release/upgrade_file ]; then
    rm -rf ${BASEDIR}/release/upgrade_file
fi
cp -R ${BASEDIR}/upgrade_file ${BASEDIR}/release
cp ${BASEDIR}/release/$package-$version.deb ${BASEDIR}/release/upgrade_file/

${BASEDIR}/dist/pim//opt/pim/bin/change_line.sh 'PIM_DEB_FILE="'"$package-$version.deb"'"' "PIM_DEB_FILE=" ${BASEDIR}/release/upgrade_file/setup.sh > /dev/null
${BASEDIR}/dist/pim/opt/cis/bin/release_tool.sh create ${BASEDIR}/release/upgrade_file

if [ ! -f ${BASEDIR}/release/upgrade_file.zip ]; then
    echo "upgrade_file.zip not exist."
    exit 1
fi
ugrade_zip_file=$(echo ${package} | tr [a-z] [A-Z] | tr '-' '_')"_release_"$(echo ${version} | tr '.' '_')".zip"
mv ${BASEDIR}/release/upgrade_file.zip ${BASEDIR}/release/${ugrade_zip_file}

echo "create ${ugrade_zip_file}"

#### create old upgrade file #################
cd ${BASEDIR}/release/upgrade_file/
mv setup.sh pim_update.sh
ugrade_old_zip_file="pim_update_"$(echo ${version})".tar"
tar cvf "../${ugrade_old_zip_file}" ./

echo "create ${ugrade_old_zip_file}"
