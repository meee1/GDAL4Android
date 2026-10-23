# GDAL4Android
Building GDAL as a self-contained *.AAR for Android development.

The aar contains `libgdal.so` (with PROJ and SQLite linked in), the Java binding
library `libgdalalljni.so`, `libc++_shared.so` and `gdal.jar`, for the `x86`,
`x86_64`, `armeabi-v7a` and `arm64-v8a` ABIs. All native libraries are linked with
16 KB page alignment, as required for Android 15+ devices with 16 KB pages and by
Google Play.

# Requires
- Android SDK + NDK r27 or newer
- JDK 17
- cmake (>= 3.24), ninja, swig (>= 4), ant, sqlite3, curl, unzip

On Ubuntu: `sudo apt-get install ninja-build swig ant sqlite3`

# Build
GDAL, PROJ and SQLite sources are downloaded by the script (versions are set at
the top of `submodules/install.sh` and can be overridden with `GDAL_VERSION`,
`PROJ_VERSION`, `SQLITE_VERSION`).

    cd gdal
    ../submodules/install.sh <android-ndk-dir> 21
    cd ..
    ./gradlew assembleRelease

The aar is written to `gdal/build/outputs/aar/gdal-release.aar`.

`ABIS="arm64-v8a"` can be set to build a subset of ABIs.

The GitHub Actions workflow (`.github/workflows/blank.yml`) runs the same steps,
checks the 16 KB alignment of every library in the aar, and uploads the aar as a
build artifact.

Load the libraries at runtime with:

    System.loadLibrary("gdal");
    System.loadLibrary("gdalalljni");
