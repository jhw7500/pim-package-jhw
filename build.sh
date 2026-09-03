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

run_binary_verification() {
    bash "${BASEDIR}/tools/run_binary_verification.sh"
}

# 타깃 rootfs(Ubuntu 20.04, glibc 2.31)보다 새로운 GLIBC 를 요구하는 바이너리를 막는다.
# Yocto SDK 는 glibc 2.33 으로 빌드하므로 x86_64 호스트 빌드가 여기서 걸린다.
# 검사 범위를 인자로 받는다. pim_gate 는 CMake 모듈들과 빌드 시점이 달라(패키징
# 단계에서 자체 build.sh 로 만들어진다) 한 번에 검사할 수 없다. 각 산출물이 생긴
# 직후·패키징 전에 각각 부른다.
#   $1: "modules"(기본, CMake 모듈 8종) | "pim_gate"
verify_glibc() {
    local scope=${1:-modules}
    local paths=()
    local m f

    if [ "$scope" = "pim_gate" ]; then
        # 단일 바이너리가 아니라 디렉터리 산출물이라 실행 파일을 훑는다.
        while IFS= read -r f; do
            [ -n "$f" ] && paths+=("$f")
        done < <(find "${BASEDIR}/pim_gate/release" -type f -perm -u+x 2>/dev/null)
    else
        # docker/build.sh 의 MODULE_BIN 과 **같은 집합**을 본다. 한쪽만 늘어나면
        # 게이트에 구멍이 난다. 이 저장소에는 ord/vsd/vcm 만 있지만 GitLab 전체
        # 체크아웃에서는 나머지도 같은 SDK 로 컴파일돼 패키지에 실린다.
        for m in ord vsd vcm adab adab_ecat cism stm32update mcp_trust_test; do
            [ -z "$TARGET_MODULE" ] || [ "$TARGET_MODULE" = "$m" ] || continue
            paths+=("${BASEDIR}/${m}/build/${m}")
        done
    fi

    bash "${BASEDIR}/tools/check_glibc.sh" "${paths[@]}"
}

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
            ord|vsd|vcm|adab|adab_ecat|cism|stm32update|mcp_trust_test)
                rm -rf ${BASEDIR}/${CLEAN_TARGET}/build
                ;;
            *)
                echo "Unknown module: ${CLEAN_TARGET}"
                echo "Available modules: ord, vsd, vcm, adab, adab_ecat, cism, stm32update, mcp_trust_test, pim_gate"
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
        rm -rf ${BASEDIR}/mcp_trust_test/build
        rm -rf ${BASEDIR}/pim_gate/cpp_source/build
        rm -rf ${BASEDIR}/pim_gate/release
    fi
    echo "Clean completed."
    exit 0
fi

# Target module (empty = all)
TARGET_MODULE="$1"

# Function to check if module should be built.
# 소스 디렉터리가 없는 모듈은 건너뛴다. 이 저장소에는 ord/vsd/vcm 만 있고 adab,
# adab_ecat, cism, stm32update, mcp_trust_test, pim_gate 는 GitLab 쪽에만 있다.
# 건너뛰지 않으면 mkdir/cd 가 실패한 채로 진행돼 직전 모듈의 build 디렉터리에서
# make 가 돌고(=엉뚱한 모듈 재빌드) 컴파일 에러 없이 통과한다.
should_build() {
    local module="$1"
    [ -z "$TARGET_MODULE" ] || [ "$TARGET_MODULE" == "$module" ] || return 1
    if [ ! -d "${BASEDIR}/${module}" ]; then
        if [ -n "$TARGET_MODULE" ]; then
            echo "ERROR: module '${module}' requested but ${BASEDIR}/${module} does not exist" >&2
            exit 1
        fi
        echo "Skipping ${module} (no source directory)"
        return 1
    fi
    return 0
}

# 빌드되지 않은 모듈의 산출물 복사는 건너뛴다.
copy_built() {
    if [ -f "$1" ]; then
        cp "$1" "$2"
    else
        echo "Skipping copy: $1 (not built)"
    fi
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
        echo "WARNING: this SDK links against glibc 2.33 but the target rootfs"
        echo "         (Ubuntu 20.04) provides glibc 2.31. ord/vsd/vcm built here fail"
        echo "         at the loader with \"GLIBC_2.33 not found\" on the device."
        echo "         Use ./docker/build.sh <module> for those modules."
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

# Build mcp_trust_test
if should_build "mcp_trust_test"; then
    echo "Building stm32umcp_trust_testpdate..."
    if [ ! -d ${BASEDIR}/mcp_trust_test/build ]; then
        mkdir ${BASEDIR}/mcp_trust_test/build
    fi
    cd ${BASEDIR}/mcp_trust_test/build
    ${CMAKE} ${CMAKE_TOOLCHAIN_ARG} ..
    make
    if [ $? != 0 ]; then
        echo "mcp_trust_test compile error"
        exit 1
    fi
fi

cd ${BASEDIR}

# GLIBC 게이트는 복사·패키징 **전에** 돌린다. 뒤에 두면 위반 빌드도 dist/release 복사와
# .deb / upgrade zip / tar 생성을 끝낸 다음에야 멈춰서, 게이트가 막으려던 바이너리가
# 배포 가능한 형태로 남는다 — 수동 배포가 그대로 집어갈 수 있다.
verify_glibc || exit $?

# Only do full release packaging when building all modules
if [ -z "$TARGET_MODULE" ]; then
    rm -rf ${BASEDIR}/release
    cp ${BASEDIR}/ord/build/ord ${BASEDIR}/dist/pim/usr/local/bin/
    cp ${BASEDIR}/vsd/build/vsd ${BASEDIR}/dist/pim/usr/local/bin/
    cp ${BASEDIR}/vcm/build/vcm ${BASEDIR}/dist/pim/usr/local/bin/
    cp -R ${BASEDIR}/dist ${BASEDIR}/release

    # Copy documentation to release package
    mkdir -p ${BASEDIR}/release/pim/opt/pim/docs
    cp ${BASEDIR}/docs/max9296/V4L2_CTRL_GUIDE.md ${BASEDIR}/release/pim/opt/pim/docs/
    cp ${BASEDIR}/docs/pim-guardian-runbook.md ${BASEDIR}/release/pim/opt/pim/docs/
    cp ${BASEDIR}/docs/camera-startup-timing.md ${BASEDIR}/release/pim/opt/pim/docs/

    copy_built ${BASEDIR}/adab/build/adab ${BASEDIR}/release/pim/opt/cis/bin/adab_adc
    copy_built ${BASEDIR}/adab_ecat/build/adab_ecat ${BASEDIR}/release/pim/opt/cis/bin/adab_ecat
    copy_built ${BASEDIR}/cism/build/cism ${BASEDIR}/release/pim/opt/cis/bin/
    copy_built ${BASEDIR}/stm32update/build/stm32update ${BASEDIR}/release/pim/opt/cis/bin/
    copy_built ${BASEDIR}/mcp_trust_test/build/mcp_trust_test ${BASEDIR}/release/pim/opt/pim/bin/
    cp -R ${BASEDIR}/test ${BASEDIR}/release/pim/opt/pim/bin/

    # build pim_gate
    SOURCEDIR=${BASEDIR}/pim_gate
    WORKDIR=${BASEDIR}/release/pim
    if [ -d "${SOURCEDIR}" ]; then
        cd ${SOURCEDIR}
        ${SOURCEDIR}/build.sh
        cd ${BASEDIR}
        verify_glibc pim_gate || exit $?

        cp -R ${SOURCEDIR}/release/pim-gate/opt/pim_gate/  ${WORKDIR}/opt/
    else
        echo "Skipping pim_gate (no source directory)"
    fi
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
            cd ${BASEDIR}
            verify_glibc pim_gate || exit $?
            cp -R ${SOURCEDIR}/release/pim-gate/opt/pim_gate/  ${WORKDIR}/opt/
            ;;
        *)
            echo "Unknown module: ${TARGET_MODULE}"
            echo "Available modules: ord, vsd, vcm, adab, adab_ecat, cism, stm32update, pim_gate"
            exit 1
            ;;
    esac

    echo "Module ${TARGET_MODULE} built and copied to release/"
    run_binary_verification || exit $?
    exit 0
fi

cd ${BASEDIR}/release 
version=$(cat ../dist/pim/DEBIAN/control| grep Version |grep -v ^$#| cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n' | tr -d ' ')
package=$(cat ../dist/pim/DEBIAN/control| grep Package |grep -v ^$#| cut -d':' -f2 | cut -d',' -f1 | tr -d '"' | tr -d '\r\n' | tr -d ' ')
echo version:$version

# Strip dev tool artifacts before packaging.
# .gitignore does not apply to dpkg, so .omc/.bkit/__pycache__ under dist/
# get copied into release/ and shipped inside the .deb.
find ${BASEDIR}/release/pim \( -name '.omc' -o -name '.bkit' -o -name '__pycache__' -o -name '.serena' -o -name '.vscode' \) -prune -exec rm -rf {} + 2>/dev/null

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

run_binary_verification || exit $?
