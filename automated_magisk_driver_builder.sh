#!/bin/bash
#
# Fully Automated Magisk Module Builder Script for RTL8188EUS (RMX3241/MT6833)
# --- VERSION 10: TARGETING ANDROID 11 KERNEL (Realme UI v2 Base) ---
#
# --- Configuration Variables ---
DEVICE_CODE="RMX3241"
KERNEL_REPO="https://github.com/realme-mediatek-dev/android_kernel_realme_mt6833.git"
# CRITICAL UPDATE (V10): Targeting the Android 11 kernel branch for Realme UI v2 compatibility.
KERNEL_BRANCH="android-11" 
RTL8188EUS_REPO="https://github.com/aircrack-ng/rtl8188eus.git"
# Toolchain (V9): Using the robust LineageOS Clang 17 link that reliably downloads.
TOOLCHAIN_URL="https://github.com/LineageOS/android_prebuilts_clang/releases/download/clang-r528479/clang-r528479.tar.gz"
TOOLCHAIN_PATH="$HOME/aosp_toolchain/clang"

BUILD_DIR="$HOME/nethunter_magisk_build"
MAGISK_MODULE_NAME="rtl8188eus_magisk_module"
MAGISK_ZIP_NAME="RTL8188EUS_Driver_${DEVICE_CODE}_Android11_AutoBuild.zip"

# --- 1. Environment Setup, Dependencies, and Cleanup ---
echo "--- 1. ENVIRONMENT SETUP, DEPENDENCIES, AND CLEANUP ---"

# Cleanup build directories
cd "$HOME"
# Ensure we remove the build directory and existing toolchains
rm -rf "$BUILD_DIR" "$HOME/aosp_toolchain" "$MAGISK_ZIP_NAME"
mkdir -p "$BUILD_DIR" "$HOME/aosp_toolchain"
cd "$BUILD_DIR"

# Install all required dependencies
echo "Installing or updating all necessary dependencies..."
sudo apt update
sudo apt install -y git build-essential bison flex libssl-dev libelf-dev \
                    zlib1g-dev libncurses5-dev bc ccache python3 curl zip

# Set up ccache
export USE_CCACHE=1
ccache -M 50G

# --- 2. Toolchain Setup and Verification ---
echo "--- 2. SETTING UP AOSP LLVM/CLANG TOOLCHAIN AND VERIFICATION ---"

if [ ! -d "$TOOLCHAIN_PATH" ]; then
    echo "Downloading Clang/LLVM Toolchain... (V10 - Robust download logic with retry)"
    
    DOWNLOAD_SUCCESS=0
    for i in {1..3}; do
        echo "Attempt $i to download toolchain..."
        # Using curl -L for following redirects
        curl -L "$TOOLCHAIN_URL" -o "$HOME/aosp_toolchain/clang.tar.gz"
        if [ $? -eq 0 ]; then
            # CRITICAL CHECK: Check for file size (should be > 150MB) to confirm it's not an HTML error page.
            FILE_SIZE=$(stat -c%s "$HOME/aosp_toolchain/clang.tar.gz")
            if [ "$FILE_SIZE" -gt 150000000 ]; then # File must be larger than 150MB
                DOWNLOAD_SUCCESS=1
                break
            else
                echo "Warning: Downloaded file is too small ($FILE_SIZE bytes). It is likely an HTML error page or failed download. Retrying in 5 seconds..."
                rm -f "$HOME/aosp_toolchain/clang.tar.gz"
                sleep 5
            fi
        else
            echo "Warning: curl failed with exit code $?. Retrying in 5 seconds..."
            sleep 5
        fi
    done

    if [ $DOWNLOAD_SUCCESS -ne 1 ]; then
        echo "!!! CRITICAL ERROR: Toolchain download failed after 3 attempts."
        echo "The download URL ($TOOLCHAIN_URL) failed to provide a valid archive. !!!"
        exit 1
    fi
    
    echo "Unpacking Toolchain..."
    mkdir -p "$TOOLCHAIN_PATH"
    # Use --strip-components 1 to correctly unpack nested archives
    tar -xzf "$HOME/aosp_toolchain/clang.tar.gz" -C "$TOOLCHAIN_PATH" --strip-components 1
    if [ $? -ne 0 ]; then
        echo "!!! CRITICAL ERROR: Downloaded file is not a valid tar archive or extraction failed. !!!"
        echo "The 'gzip: stdin: not in gzip format' error usually happens here."
        exit 1
    fi
    rm "$HOME/aosp_toolchain/clang.tar.gz"
fi

# Set cross-compilation environment variables
export PATH="$TOOLCHAIN_PATH/bin:$PATH"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_ARM64="aarch64-linux-gnu-"
export ARCH="arm64"
export SUBARCH="arm64"
export CLANG_TRIPLE="aarch64-linux-gnu-"
export LLVM=1

# Verification: Check if clang is available
if [ ! -f "$TOOLCHAIN_PATH/bin/clang" ]; then
    echo "!!! CRITICAL: Clang compiler ($TOOLCHAIN_PATH/bin/clang) not found. Toolchain setup failed. !!!"
    exit 1
fi
export KBUILD_COMPILER_STRING="$(${TOOLCHAIN_PATH}/bin/clang --version | head -n 1)"
echo "Compiler: $KBUILD_COMPILER_STRING"

# --- 3. Source Acquisition and Verification ---
echo "--- 3. CLONING KERNEL (Android 11) AND DRIVER SOURCE CODE ---"
git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" kernel
if [ $? -ne 0 ]; then
    echo "!!! CRITICAL: Kernel clone failed. Check branch or repository URL. !!!"
    exit 1
fi

git clone --depth 1 "$RTL8188EUS_REPO" rtl8188eus
echo "Source code cloned successfully."

# --- 4. Prepare Kernel Headers, Patch Kconfig, and Load Defconfig ---
echo "--- 4. PREPARING KERNEL HEADERS FOR DRIVER COMPILATION ---"
cd "$BUILD_DIR/kernel"

# FIX: Patch the Kconfig error by removing the reference to the missing sched_assist/Kconfig file.
echo "Patching Kconfig: Removing reference to missing kernel/sched_assist/Kconfig."
sed -i '/kernel\/sched_assist\/Kconfig/d' init/Kconfig

# Load the device's default configuration
DEFCONFIG_FOUND=0
DEFCONFIG_FILE=""

# Attempt 1: Specific device config
if [ -f "arch/$ARCH/configs/vendor/${DEVICE_CODE}_defconfig" ]; then
    DEFCONFIG_FILE="vendor/${DEVICE_CODE}_defconfig"
    make $DEFCONFIG_FILE
    DEFCONFIG_FOUND=1
fi

# Attempt 2: Common MT6833 vendor config
if [ $DEFCONFIG_FOUND -eq 0 ] && [ -f "arch/$ARCH/configs/vendor/mt6833_defconfig" ]; then
    DEFCONFIG_FILE="vendor/mt6833_defconfig"
    make $DEFCONFIG_FILE
    DEFCONFIG_FOUND=1
fi

# Attempt 3: General config fallback
if [ $DEFCONFIG_FOUND -eq 0 ] && [ -f "arch/$ARCH/configs/mt6833_defconfig" ]; then
    DEFCONFIG_FILE="mt6833_defconfig"
    make $DEFCONFIG_FILE
    DEFCONFIG_FOUND=1
fi

# Final Check for Configuration
if [ $DEFCONFIG_FOUND -eq 0 ] || [ ! -f ".config" ]; then
    echo "!!! CRITICAL ERROR: No valid kernel configuration file found or loaded. !!!"
    echo "Please ensure a defconfig file exists in your kernel repository."
    exit 1
fi

echo "Successfully loaded kernel configuration: $DEFCONFIG_FILE"


# Build necessary headers/configs for external modules
mkdir -p out
make O=out prepare -j$(nproc)
if [ $? -ne 0 ]; then
    echo "!!! CRITICAL ERROR: 'make prepare' failed. Kernel source or configuration error. !!!"
    exit 1
fi
make O=out modules_prepare -j$(nproc)
if [ $? -ne 0 ]; then
    echo "!!! CRITICAL ERROR: 'make modules_prepare' failed. !!!"
    exit 1
fi

echo "--- Kernel headers preparation completed. ---"

# --- 5. Compile RTL8188EUS Module and Verification ---
echo "--- 5. COMPILING THE RTL8188EUS DRIVER ---"

cd "$BUILD_DIR/rtl8188eus"

# Export the location of the kernel build output and headers
KERNEL_SRC="$BUILD_DIR/kernel"
KERNEL_OUT="$BUILD_DIR/kernel/out"

# Build the module
make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE KSRC=$KERNEL_SRC KVER=$(make O=$KERNEL_OUT kernelrelease) -j$(nproc)

# Final Module Verification
if [ ! -f "8188eu.ko" ]; then
    echo "!!! CRITICAL COMPILATION FAILED: 8188eu.ko was not created. Check driver code or kernel headers. !!!"
    exit 1
fi

echo "RTL8188EUS module (8188eu.ko) compiled successfully."

# --- 6. Package Magisk Module Structure ---
echo "--- 6. CREATING MAGISK MODULE FOLDER AND STRUCTURE ---"
cd "$BUILD_DIR"
mkdir -p "$MAGISK_MODULE_NAME/system/lib/modules"

# Copy the compiled kernel module
cp "$BUILD_DIR/rtl8188eus/8188eu.ko" "$MAGISK_MODULE_NAME/system/lib/modules/8188eu.ko"

# Create module.prop
cat << EOF > "$MAGISK_MODULE_NAME/module.prop"
id=rtl8188eus_driver
name=RTL8188EUS Driver for $DEVICE_CODE (Android 11)
version=v1.0
versionCode=10
author=Generated by Gemini
description=Magisk module to install and load the pre-compiled 8188eu.ko driver for USB Wi-Fi adapters (Monitor Mode & Injection support). Compiled specifically for $DEVICE_CODE using Android 11 kernel headers.
EOF

# Create customize.sh (Installer script)
cat << EOF > "$MAGISK_MODULE_NAME/customize.sh"
SKIPUNZIP=true
ui_print " "
ui_print "****************************************"
ui_print "* RTL8188EUS Magisk Module Installer *"
ui_print "****************************************"
ui_print " "
MODULE_FILE="\$MODPATH/system/lib/modules/8188eu.ko"
if [ ! -f "\$MODULE_FILE" ]; then
  ui_print "!!! ERROR: 8188eu.ko file not found in the ZIP. !!!"
  abort "Installation aborted."
fi
ui_print "Preparing script to load driver on boot..."
KERNEL_MODULE_PATH="/system/lib/modules/8188eu.ko"
cat << EOFF > "\$MODPATH/service.sh"
#!/system/bin/sh
# Wait a few seconds for system stability
sleep 15 
ui_print "-> Loading 8188eu.ko driver..."
modprobe 8188eu
if [ \$? -ne 0 ]; then
  insmod $KERNEL_MODULE_PATH
  if [ \$? -eq 0 ]; then
    ui_print "-> Driver load successful via insmod."
  else
    ui_print "!!! Driver load failed. Possibly incompatible kernel version. !!!"
  fi
fi
# Blacklist the old, built-in non-monitor-mode driver if it exists
echo "blacklist r8188eu" > /etc/modprobe.d/rtl8188eus_blacklist.conf
EOFF
ui_print " "
ui_print "Installation complete! Please reboot your device."
EOF

# --- 7. Create Final Flashable ZIP ---
echo "--- 7. CREATING FINAL FLASHABLE ZIP FILE ---"
# Need to ensure 'zip' is installed for this step, which is handled in step 1.
zip -r9 "$MAGISK_ZIP_NAME" "$MAGISK_MODULE_NAME" -x ".git/*"

echo "--- 8. PROCESS COMPLETE ---"
echo "Your Magisk Module ZIP has been created: $BUILD_DIR/$MAGISK_ZIP_NAME"
echo "Use Magisk Manager to flash this ZIP file."
