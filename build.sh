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
cmake ..
make
if [ $? != 0 ]; then
    echo "vsd compile error"
    exit 1
fi

cd ${BASEDIR}
rm -rf ${BASEDIR}/release
cp -R ${BASEDIR}/dist ${BASEDIR}/release
cp ${BASEDIR}/ord/build/ord ${BASEDIR}/release/pim/opt/pim/bin/
cp ${BASEDIR}/vsd/build/vsd ${BASEDIR}/release/pim/opt/pim/bin/
cd ${BASEDIR}/release
dpkg -b pim
