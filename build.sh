#!/bin/bash
#
# Build PIM package
# Usage: ./build.sh [MODULE|clean [MODULE]]
#   MODULE: ord, vsd, vcm, adab, adab_ecat, cism, stm32update, pim_gate
#           If omitted, builds all modules (incremental).
#   clean:  Clean build directories
#           clean        - clean all modules
#           clean MODULE - clean specific module
#
# Examples:
#   ./build.sh              # Build all modules (incremental)
#   ./build.sh ord          # Build only ord module (incremental)
#   ./build.sh clean        # Clean all modules
#   ./build.sh clean ord    # Clean only ord module
#

BASEDIR=${PWD}
echo "Script location: ${BASEDIR}"

# Handle clean command
if [ "$1" == "clean" ]; then
    CLEAN_TARGET="$2"
    if [ -n "$CLEAN_TARGET" ]; then
        echo "Cleaning ${CLEAN_TARGET}..."
        case "$CLEAN_TARGET" in
            pim_gate)
                rm -rf ${BASEDIR}/pim_gate/cpp_source/build
                rm -rf ${BASEDIR}/pim_gate/release
                ;;
            ord|vsd|vcm|adab|adab_ecat|cism|stm32update)
                rm -rf ${BASEDIR}/${CLEAN_TARGET}/build
                ;;
            *)
                echo "Unknown module: ${CLEAN_TARGET}"
                echo "Available modules: ord, vsd, vcm, adab, adab_ecat, cism, stm32update, pim_gate"
                exit 1
                ;;
        esac
    else
        echo "Cleaning all modules..."
        rm -rf ${BASEDIR}/ord/build
        rm -rf ${BASEDIR}/vcm/build
        rm -rf ${BASEDIR}/vsd/build
        rm -rf ${BASEDIR}/adab/build
        rm -rf ${BASEDIR}/adab_ecat/build
        rm -rf ${BASEDIR}/cism/build
        rm -rf ${BASEDIR}/stm32update/build
        rm -rf ${BASEDIR}/pim_gate/cpp_source/build
        rm -rf ${BASEDIR}/pim_gate/release
    fi
    echo "Clean completed."
    exit 0
fi

# Target module (empty = all)
TARGET_MODULE="$1"

# Function to check if module should be built
should_build() {
    local module="$1"
    [ -z "$TARGET_MODULE" ] || [ "$TARGET_MODULE" == "$module" ]
}

# Cross-compile setup for NXP i.MX8 (same as gstApp)
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "x86_64" ]; then
    # Use Yocto SDK environment
    [ "$SDK_LOC" ] || SDK_LOC=/shared/fsl-imx-xwayland/5.10-hardknott
    [ "$SDK_NAME" ] || SDK_NAME=cortexa53-crypto-poky-linux

    SDK_ENV=${SDK_LOC}/environment-setup-${SDK_NAME}
    if [ -e ${SDK_ENV} ]; then
        echo "Cross-compiling for i.MX8 using Yocto SDK"
        echo "SDK: ${SDK_ENV}"
        . ${SDK_ENV}

        # Configure pkg-config to use SDK sysroot (like gstApp's make-for-imx8)
        SYSROOT=${SDK_LOC}/sysroots/${SDK_NAME}
        export PKG_CONFIG_SYSROOT_DIR=${SYSROOT}
        export PKG_CONFIG_PATH=${SYSROOT}/usr/lib/pkgconfig
        echo "PKG_CONFIG_SYSROOT_DIR: $PKG_CONFIG_SYSROOT_DIR"

        # Use system cmake with SDK toolchain to avoid GLIBC version issues
        # SDK's cmake requires GLIBC 2.32+ but host may have older version
        if [ -n "$OE_CMAKE_TOOLCHAIN_FILE" ]; then
            CMAKE_TOOLCHAIN_ARG="-DCMAKE_TOOLCHAIN_FILE=$OE_CMAKE_TOOLCHAIN_FILE"
            echo "Using toolchain: $OE_CMAKE_TOOLCHAIN_FILE"

            # Force use of system cmake instead of SDK cmake
            CMAKE=/usr/bin/cmake
            echo "Using cmake: $CMAKE"
        fi
    else
        echo "ERROR: SDK not found at ${SDK_ENV}"
        echo "Please set SDK_LOC and SDK_NAME environment variables"
        exit 1
    fi
else
    echo "Native build for ${HOST_ARCH}"
    CMAKE_TOOLCHAIN_ARG=""
    CMAKE=cmake
fi

# Build ord
if should_build "ord"; then
    echo "Building ord..."
    if [ ! -d ${BASEDIR}/ord/build ]; then
        mkdir ${BASEDIR}/ord/build
    fi
    cd ${BASEDIR}/ord/build
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "ord compile error"
        exit 1
    fi
fi

# Build vsd
if should_build "vsd"; then
    echo "Building vsd..."
    if [ ! -d ${BASEDIR}/vsd/build ]; then
        mkdir ${BASEDIR}/vsd/build
    fi
    cd ${BASEDIR}/vsd/build
    cp ${BASEDIR}/vsd/libpi* /usr/local/lib/ -a
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "vsd compile error"
        exit 1
    fi
fi

# Build vcm
if should_build "vcm"; then
    echo "Building vcm..."
    if [ ! -d ${BASEDIR}/vcm/build ]; then
        mkdir ${BASEDIR}/vcm/build
    fi
    cd ${BASEDIR}/vcm/build
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "vcm compile error"
        exit 1
    fi
fi

# Build adab
if should_build "adab"; then
    echo "Building adab..."
    if [ ! -d ${BASEDIR}/adab/build ]; then
        mkdir ${BASEDIR}/adab/build
    fi
    cd ${BASEDIR}/adab/build
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "adab compile error"
        exit 1
    fi
fi

# Build adab_ecat
if should_build "adab_ecat"; then
    echo "Building adab_ecat..."
    if [ ! -d ${BASEDIR}/adab_ecat/build ]; then
        mkdir ${BASEDIR}/adab_ecat/build
    fi
    cd ${BASEDIR}/adab_ecat/build
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "adab_ecat compile error"
        exit 1
    fi
fi

# Build cism
if should_build "cism"; then
    echo "Building cism..."
    if [ ! -d ${BASEDIR}/cism/build ]; then
        mkdir ${BASEDIR}/cism/build
    fi
    cd ${BASEDIR}/cism/build
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "cism compile error"
        exit 1
    fi
fi

# Build stm32update
if should_build "stm32update"; then
    echo "Building stm32update..."
    if [ ! -d ${BASEDIR}/stm32update/build ]; then
        mkdir ${BASEDIR}/stm32update/build
    fi
    cd ${BASEDIR}/stm32update/build
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "stm32update compile error"
        exit 1
    fi
fi


cd ${BASEDIR}

# Only do full release packaging when building all modules
if [ -z "$TARGET_MODULE" ]; then
    rm -rf ${BASEDIR}/release
    cp ${BASEDIR}/ord/build/ord ${BASEDIR}/dist/pim/usr/local/bin/
    cp ${BASEDIR}/vsd/build/vsd ${BASEDIR}/dist/pim/usr/local/bin/
    cp ${BASEDIR}/vcm/build/vcm ${BASEDIR}/dist/pim/usr/local/bin/
    cp -R ${BASEDIR}/dist ${BASEDIR}/release
    cp ${BASEDIR}/adab/build/adab ${BASEDIR}/release/pim/opt/cis/bin/adab_adc
    cp ${BASEDIR}/adab_ecat/build/adab_ecat ${BASEDIR}/release/pim/opt/cis/bin/adab_ecat
    cp ${BASEDIR}/cism/build/cism ${BASEDIR}/release/pim/opt/cis/bin/
    cp ${BASEDIR}/stm32update/build/stm32update ${BASEDIR}/release/pim/opt/cis/bin/
    cp -R ${BASEDIR}/test ${BASEDIR}/release/pim/opt/pim/bin/

    # build pim_gate
    SOURCEDIR=${BASEDIR}/pim_gate
    WORKDIR=${BASEDIR}/release/pim
    cd ${SOURCEDIR}
    ${SOURCEDIR}/build.sh

    cp -R ${SOURCEDIR}/release/pim-gate/opt/pim_gate/  ${WORKDIR}/opt/
else
    # Single module build - just copy the built binary
    echo "Single module build: ${TARGET_MODULE}"

    # Ensure release directory exists
    if [ ! -d ${BASEDIR}/release ]; then
        cp -R ${BASEDIR}/dist ${BASEDIR}/release
    fi

    case "$TARGET_MODULE" in
        ord)
            cp ${BASEDIR}/ord/build/ord ${BASEDIR}/dist/pim/usr/local/bin/
            cp ${BASEDIR}/ord/build/ord ${BASEDIR}/release/pim/usr/local/bin/
            ;;
        vsd)
            cp ${BASEDIR}/vsd/build/vsd ${BASEDIR}/dist/pim/usr/local/bin/
            cp ${BASEDIR}/vsd/build/vsd ${BASEDIR}/release/pim/usr/local/bin/
            ;;
        vcm)
            cp ${BASEDIR}/vcm/build/vcm ${BASEDIR}/dist/pim/usr/local/bin/
            cp ${BASEDIR}/vcm/build/vcm ${BASEDIR}/release/pim/usr/local/bin/
            ;;
        adab)
            cp ${BASEDIR}/adab/build/adab ${BASEDIR}/release/pim/opt/cis/bin/adab_adc
            ;;
        adab_ecat)
            cp ${BASEDIR}/adab_ecat/build/adab_ecat ${BASEDIR}/release/pim/opt/cis/bin/adab_ecat
            ;;
        cism)
            cp ${BASEDIR}/cism/build/cism ${BASEDIR}/release/pim/opt/cis/bin/
            ;;
        stm32update)
            cp ${BASEDIR}/stm32update/build/stm32update ${BASEDIR}/release/pim/opt/cis/bin/
            ;;
        pim_gate)
            SOURCEDIR=${BASEDIR}/pim_gate
            WORKDIR=${BASEDIR}/release/pim
            cd ${SOURCEDIR}
            ${SOURCEDIR}/build.sh
            cp -R ${SOURCEDIR}/release/pim-gate/opt/pim_gate/  ${WORKDIR}/opt/
            ;;
        *)
            echo "Unknown module: ${TARGET_MODULE}"
            echo "Available modules: ord, vsd, vcm, adab, adab_ecat, cism, stm32update, pim_gate"
            exit 1
            ;;
    esac

    echo "Module ${TARGET_MODULE} built and copied to release/"
    exit 0
fi

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
