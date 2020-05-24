#!/bin/sh

#
# Requires on path:
#   - xcodebuild
#   - cmake
#   - ninja
#
# `CONFIGURATION=Debug /bin/sh $0` to build Debug configuration
#

PROJECT_ROOT=$(cd `dirname $0` && pwd)
DERIVED_DATA_PATH="${PROJECT_ROOT}/DerivedData/CZiti"
C_SDK_ROOT="${PROJECT_ROOT}/deps/ziti-sdk-c"
: ${CONFIGURATION:="Release"}

function do_build {
   scheme=$1
   arch=$2
   sdk=$3
   toolchain=$4

   c_sdk_build_dir=${C_SDK_ROOT}/build-${sdk}-${arch}

   # nuke C SDK build dir and re-create it
   rm -rf ${c_sdk_build_dir}
   if [ $? -ne 0 ] ;  then
      echo "Unable to delete directory ${c_sdk_build_dir}"
      exit 1
   fi

   mkdir -p ${c_sdk_build_dir}
   if [ $? -ne 0 ] ;  then
      echo "Unable to create directory ${c_sdk_build_dir}"
      exit 1
   fi

   cd ${c_sdk_build_dir}
   if [ -z "${toolchain}" ] ; then
      cmake -GNinja .. && ninja
   else
      cmake -GNinja -DCMAKE_TOOLCHAIN_FILE=../toolchains/${toolchain} .. && ninja
   fi

   if [ $? -ne 0 ] ;  then
      echo "FAILED building C SDK ${c_sdk_build_dir}"
      exit 1
   fi

   cd ${PROJECT_ROOT}
   xcodebuild build -configuration ${CONFIGURATION} -scheme ${scheme} -derivedDataPath ${DERIVED_DATA_PATH} -arch ${arch} -sdk ${sdk}
   if [ $? -ne 0 ] ;  then
      echo "FAILED building ${scheme} ${CONFIGURATION} ${sdk} ${arch}"
      exit 1
   fi
}


rm -rf ${DERIVED_DATA_PATH}
if [ $? -ne 0 ] ; then
   echo "Unable to remove ${DERIVED_DATA_PATH}"
   exit 1
fi

do_build CZiti-macOS x86_64 macosx
do_build CZiti-iOS arm64 iphoneos iOS-arm64.cmake
do_build CZiti-iOS x86_64 iphonesimulator iOS-x86_64.cmake

/bin/sh ${PROJECT_ROOT}/make_dist.sh
if [ $? -ne 0 ] ; then
   echo "Unable to create distribution"
   exit 1
fi
