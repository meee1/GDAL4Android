#!/bin/bash
# Builds GDAL (with PROJ and SQLite statically linked in) and the GDAL Java
# bindings for Android, then copies the results into the gdal module so that
# `./gradlew assembleRelease` can package them into gdal-release.aar.
#
# Usage (from the gdal/ directory): ./../submodules/install.sh <ndk-dir> <min-sdk>
#
# All shared libraries are linked with 16 KB ELF segment alignment, as required
# for Android 15+ devices with 16 KB pages and by Google Play. Use NDK r27+.
#
# Host tools needed: cmake (>= 3.24), ninja, swig (>= 4), ant, a JDK, sqlite3, curl.
# They are taken from PATH unless overridden with CMAKE/NINJA/SWIG/ANT/SQLITE3.
set -euo pipefail

NDK_ROOT=$1
MIN_SDK_VERSION=$2

GDAL_VERSION=${GDAL_VERSION:-3.13.3}
PROJ_VERSION=${PROJ_VERSION:-9.9.0}
SQLITE_VERSION=${SQLITE_VERSION:-3540100}
SQLITE_YEAR=${SQLITE_YEAR:-2026}
ABIS=${ABIS:-"x86 x86_64 armeabi-v7a arm64-v8a"}

CMAKE=${CMAKE:-cmake}
NINJA=$(command -v "${NINJA:-ninja}")
SWIG=$(command -v "${SWIG:-swig}")
ANT=$(command -v "${ANT:-ant}")
SQLITE3=$(command -v "${SQLITE3:-sqlite3}")
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

APP_ROOT=$(pwd)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILDDIR=$SCRIPT_DIR/build
SRCDIR=$BUILDDIR/src
mkdir -p "$SRCDIR"

TOOLCHAIN_FILE=$NDK_ROOT/build/cmake/android.toolchain.cmake
if [ ! -f "$TOOLCHAIN_FILE" ]; then
    echo "NDK not found at $NDK_ROOT" >&2
    exit 1
fi

# 16 KB page size support. NDK r28+ does this by default, r27 needs
# ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES; the explicit linker option covers both.
PAGE_FLAGS="-Wl,-z,max-page-size=16384"

fetch() { # url dest
    [ -f "$2" ] || curl -fsSL -o "$2" "$1"
}

# ---------------------------------------------------------------- sources
cd "$SRCDIR"
fetch "https://github.com/OSGeo/gdal/releases/download/v$GDAL_VERSION/gdal-$GDAL_VERSION.tar.gz" gdal-$GDAL_VERSION.tar.gz
fetch "https://download.osgeo.org/proj/proj-$PROJ_VERSION.tar.gz" proj-$PROJ_VERSION.tar.gz
fetch "https://www.sqlite.org/$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_VERSION.zip" sqlite-$SQLITE_VERSION.zip
[ -d "gdal-$GDAL_VERSION" ] || tar xzf gdal-$GDAL_VERSION.tar.gz
[ -d "proj-$PROJ_VERSION" ] || tar xzf proj-$PROJ_VERSION.tar.gz
[ -d "sqlite-amalgamation-$SQLITE_VERSION" ] || unzip -q sqlite-$SQLITE_VERSION.zip

GDALDIR=$SRCDIR/gdal-$GDAL_VERSION
PROJDIR=$SRCDIR/proj-$PROJ_VERSION
SQLITEDIR=$SRCDIR/sqlite-amalgamation-$SQLITE_VERSION

# GDALtest.java uses java.awt APIs that the Android (SWIGANDROID) bindings omit.
rm -f "$GDALDIR/swig/java/apps/GDALtest.java"

# Minimal CMake project for the SQLite amalgamation (PROJ needs it).
cat > "$SQLITEDIR/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(sqlite3 C)
add_library(sqlite3 STATIC sqlite3.c)
target_compile_definitions(sqlite3 PRIVATE SQLITE_THREADSAFE=1 SQLITE_ENABLE_RTREE=1 SQLITE_OMIT_LOAD_EXTENSION=1)
install(TARGETS sqlite3 ARCHIVE DESTINATION lib)
install(FILES sqlite3.h sqlite3ext.h DESTINATION include)
EOF

# ---------------------------------------------------------------- per ABI
for ABI in $ABIS
do
    echo "######### $ABI ##########"
    PREFIX=$BUILDDIR/$ABI
    OBJDIR=$BUILDDIR/obj-$ABI
    COMMON=(
        -G Ninja
        -DCMAKE_MAKE_PROGRAM="$NINJA"
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE"
        -DANDROID_ABI=$ABI
        -DANDROID_PLATFORM=android-$MIN_SDK_VERSION
        -DANDROID_STL=c++_shared
        -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_PREFIX_PATH="$PREFIX"
        -DCMAKE_FIND_ROOT_PATH="$PREFIX"
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DCMAKE_SHARED_LINKER_FLAGS="$PAGE_FLAGS"
    )

    # SQLite
    "$CMAKE" -S "$SQLITEDIR" -B "$OBJDIR/sqlite" "${COMMON[@]}"
    "$CMAKE" --build "$OBJDIR/sqlite" --target install -j "$JOBS"

    # PROJ (static, linked into libgdal.so)
    "$CMAKE" -S "$PROJDIR" -B "$OBJDIR/proj" "${COMMON[@]}" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF \
        -DENABLE_TIFF=OFF -DENABLE_CURL=OFF -DBUILD_PROJSYNC=OFF \
        -DSQLite3_INCLUDE_DIR="$PREFIX/include" -DSQLite3_LIBRARY="$PREFIX/lib/libsqlite3.a" \
        -DEXE_SQLITE3="$SQLITE3"
    "$CMAKE" --build "$OBJDIR/proj" --target install -j "$JOBS"

    # 32-bit Android below API 24 has no 64-bit file offset API (lseek64 etc.),
    # so GDAL must be told to build without >4GB file support there.
    EXTRA=()
    if [ "$MIN_SDK_VERSION" -lt 24 ] && { [ $ABI = x86 ] || [ $ABI = armeabi-v7a ]; }; then
        EXTRA+=(-DBUILD_WITHOUT_64BIT_OFFSET=ON)
    fi

    # GDAL + Java bindings. Only the bundled (internal) libraries are used.
    "$CMAKE" -S "$GDALDIR" -B "$OBJDIR/gdal" "${COMMON[@]}" "${EXTRA[@]}" \
        -DBUILD_SHARED_LIBS=ON -DBUILD_APPS=OFF -DBUILD_TESTING=OFF \
        -DGDAL_USE_EXTERNAL_LIBS=OFF -DGDAL_USE_INTERNAL_LIBS=ON \
        -DPROJ_DIR="$PREFIX/lib/cmake/proj" \
        -DSQLite3_INCLUDE_DIR="$PREFIX/include" -DSQLite3_LIBRARY="$PREFIX/lib/libsqlite3.a" \
        -DBUILD_JAVA_BINDINGS=ON -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_CSHARP_BINDINGS=OFF \
        -DGDAL_JAVA_GENERATE_JAVADOC=OFF \
        -DSWIG_EXECUTABLE="$SWIG" -DANT="$ANT" \
        -DCMAKE_DISABLE_FIND_PACKAGE_Python=ON \n        -DSWIG_DEFINES=-DSWIGANDROID
    "$CMAKE" --build "$OBJDIR/gdal" -j "$JOBS"

    # Strip straight into jniLibs: the NDK toolchain builds with -g, which makes
    # libgdal.so ~250 MB unstripped.
    JNILIBS=$APP_ROOT/src/main/jniLibs/$ABI
    STRIP=$(ls "$NDK_ROOT"/toolchains/llvm/prebuilt/*/bin/llvm-strip*)
    rm -rf "$JNILIBS"
    mkdir -p "$JNILIBS"
    "$STRIP" --strip-unneeded -o "$JNILIBS/libgdal.so" "$OBJDIR/gdal/libgdal.so"
    "$STRIP" --strip-unneeded -o "$JNILIBS/libgdalalljni.so" "$OBJDIR/gdal/swig/java/libgdalalljni.so"
    "$STRIP" --strip-unneeded -o "$JNILIBS/libc++_shared.so" "$(ls -d "$NDK_ROOT"/toolchains/llvm/prebuilt/*/sysroot/usr/lib)/$(
        case $ABI in
            x86) echo i686-linux-android ;;
            x86_64) echo x86_64-linux-android ;;
            armeabi-v7a) echo arm-linux-androideabi ;;
            arm64-v8a) echo aarch64-linux-android ;;
        esac)/libc++_shared.so"
done

# The jar is architecture independent; take it from the last ABI built.
mkdir -p "$APP_ROOT/libs"
cp "$OBJDIR/gdal/swig/java/gdal.jar" "$APP_ROOT/libs/"
