#!/bin/bash

BASEDIR=${PWD}
echo "Script location: ${BASEDIR}"

if [ ! -d ${BASEDIR}/ord/build ]; then
    mkdir ${BASEDIR}/ord/build
fi
cd ${BASEDIR}/ord/build
cmake ..
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
